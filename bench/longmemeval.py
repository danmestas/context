#!/usr/bin/env python3
"""Runs ctx's real pipeline on LongMemEval-S, retrieval only: each question's sessions are
written as transcripts, archived into a fresh ctx database with `ctx scan`, and searched
with `ctx search` using the question as typed. No model is called.

  bench/longmemeval.py --data longmemeval_s_cleaned.json [--jobs 4] [--limit N] [--record FILE]

The data is not in this repository. Fetch the pinned file and check it:
  curl -fL https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json -o longmemeval_s_cleaned.json
  shasum -a 256 longmemeval_s_cleaned.json   # d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442

Scoring follows the retrieval protocol others report on this file: the 30 unanswerable
questions are left out; sessions with a repeated id are kept once; the first five distinct
sessions among the ranked turns are what count. Strict recall needs every evidence session
among them, fractional recall averages the share found, any-hit needs one.
"""
import argparse
import collections
import concurrent.futures as cf
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import uuid

CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")
SHA = "d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442"
TOP = 5


def stamp(text, i):
    """'2023/05/20 (Sat) 02:21' plus i seconds, as a transcript timestamp."""
    m = re.match(r"(\d+)/(\d+)/(\d+) \(\w+\) (\d+):(\d+)", text)
    t = dt.datetime(*map(int, m.groups())) + dt.timedelta(seconds=i)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def one(q):
    work = tempfile.mkdtemp(prefix="lme-")
    try:
        env = dict(os.environ, CTX_DB=f"{work}/ctx.sqlite", HOME=work)
        subprocess.run([CTX, "init"], env=env, capture_output=True, check=True)
        root = f"{work}/projects/-bench-lme"
        os.makedirs(root)
        names, seen = {}, set()
        for sid, date, turns in zip(q["haystack_session_ids"], q["haystack_dates"], q["haystack_sessions"]):
            if sid in seen:
                continue
            seen.add(sid)
            name = str(uuid.uuid5(uuid.NAMESPACE_URL, sid))
            names[name] = sid
            with open(f"{root}/{name}.jsonl", "w") as f:
                for i, t in enumerate(turns):
                    f.write(json.dumps({"uuid": f"{name}-{i}", "timestamp": stamp(date, i), "cwd": "/bench/lme",
                                        "message": {"role": t["role"], "content": t["content"]}}) + "\n")
        subprocess.run([CTX, "scan", f"{work}/projects"], env=env, capture_output=True, check=True)
        words = re.findall(r"[A-Za-z0-9_'-]+", q["question"])
        out = subprocess.run([CTX, "search", "--all", "--limit", "60", *words], env=env, capture_output=True, text=True).stdout
        ids = re.findall(r"^#(\d+) ", out, re.M)
        got = []
        if ids:
            rows = subprocess.run([CTX, "sql", "SELECT c.id, cd.session FROM ctx_chunk c JOIN ctx_doc d ON d.id = c.doc_id"
                                   " JOIN ctx_capture_day cd ON cd.technote = d.name WHERE c.id IN (" + ",".join(ids) + ")"],
                                  env=env, capture_output=True, text=True).stdout
            where = dict(line.split("\t") for line in rows.splitlines() if "\t" in line)
            for i in ids:  # ranked turns to ranked sessions, each once
                s = names.get(where.get(i, ""))
                if s and s not in got:
                    got.append(s)
        gold = set(q["answer_session_ids"])
        found = len(gold & set(got[:TOP]))
        return dict(id=q["question_id"], type=q["question_type"], strict=found == len(gold), any=found > 0, frac=found / len(gold),
                    sessions=len(seen))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--record")
    a = ap.parse_args()
    raw = open(a.data, "rb").read()
    if hashlib.sha256(raw).hexdigest() != SHA:
        raise SystemExit("this is not the pinned LongMemEval-S file; see the top of this script")
    qs = [q for q in json.loads(raw) if not q["question_id"].endswith("_abs")]
    if a.limit:
        qs = qs[: a.limit]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        rows = list(ex.map(one, qs))
    n = len(rows)
    strict, anyhit, frac = sum(r["strict"] for r in rows), sum(r["any"] for r in rows), sum(r["frac"] for r in rows) / n
    print(f"questions {n}; strict recall-all@{TOP} {strict}/{n} ({strict / n:.1%}); fractional {frac:.1%}; any-hit {anyhit}/{n} ({anyhit / n:.1%})")
    by = collections.defaultdict(list)
    for r in rows:
        by[r["type"]].append(r["strict"])
    for t in sorted(by):
        print(f"  {t:28} {sum(by[t]):3}/{len(by[t])}")
    if a.record and not a.limit:
        today = dt.date.today()
        result = dict(
            name=os.path.basename(a.record)[:-5], title="LongMemEval-S, retrieval only", section="Search", order=20,
            date=today.isoformat(), good_until=(today + dt.timedelta(days=180)).isoformat(), commit=os.environ.get("CTX_COMMIT", ""),
            command="bench/longmemeval.py --data longmemeval_s_cleaned.json",
            conditions={"data": "LongMemEval-S cleaned, 500 questions of which 470 are answerable, about 50 chat sessions each; "
                                "public, checksum pinned in the script",
                        "pipeline": "each question's sessions archived into a fresh ctx database, then ctx search with the question as typed",
                        "scoring": "the first five distinct sessions among the ranked turns; no model involved"},
            summary="A public benchmark of long-term memory in chat assistants. Run retrieval-only, it asks whether a search "
                    "returns the sessions that hold the evidence for each question. It is chat, not coding work, but it is "
                    "data anyone can rerun and others publish scores on.",
            metrics=[dict(label=f"Strict recall at {TOP} (every evidence session found)", value=f"{strict / n:.1%}", note=f"{strict} of {n}"),
                     dict(label=f"Fractional recall at {TOP}", value=f"{frac:.1%}"),
                     dict(label=f"Any hit at {TOP}", value=f"{anyhit / n:.1%}", note=f"{anyhit} of {n}")]
                    + [dict(label=f"Strict, {t}", value=f"{sum(v)} of {len(v)}") for t, v in sorted(by.items())])
        if os.path.exists(a.record):  # what it is compared with and what it means are written by hand, and kept
            old = json.load(open(a.record))
            result.update({k: old[k] for k in ("baseline", "meaning", "bar", "verdict") if k in old})
        with open(a.record, "w") as f:
            json.dump(result, f, indent=1)
            f.write("\n")


if __name__ == "__main__":
    main()
