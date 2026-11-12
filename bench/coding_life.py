#!/usr/bin/env python3
"""Runs ctx's real pipeline on coding-agent-life-v1, a small public set from the
agentmemory project: 15 invented coding sessions and 15 questions, each with the
sessions that answer it. The sessions are written as transcripts, archived into a fresh
ctx database with `ctx scan`, and each question is searched as typed. No model is called.

  bench/coding_life.py --data DIR [--record FILE]

DIR holds queries.json and sessions.json from
https://github.com/rohitg00/agentmemory/tree/HEAD/eval/data/coding-agent-life-v1
(not in this repository). It is a smoke test: plain grep nearly ties on it.
"""
import argparse
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
SHA = {"queries.json": "4f36fb00ea1e0ce3ccbefea9348fc4da027201a26a1fd7b5349391bcc69a24b4",
       "sessions.json": "d32f0c3c35a35e6c5aa0ac1fd0bd92e1f413c132efe3b1262038595589df3f16"}
TOP = 5


def load(d, name):
    raw = open(os.path.join(d, name), "rb").read()
    if hashlib.sha256(raw).hexdigest() != SHA[name]:
        raise SystemExit(f"{name} is not the pinned file; see the top of this script")
    return json.loads(raw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--record")
    a = ap.parse_args()
    sessions, queries = load(a.data, "sessions.json"), load(a.data, "queries.json")
    work = tempfile.mkdtemp(prefix="cal-")
    try:
        env = dict(os.environ, CTX_DB=f"{work}/ctx.sqlite", HOME=work)
        subprocess.run([CTX, "init"], env=env, capture_output=True, check=True)
        root = f"{work}/projects/-bench-shipctl"
        os.makedirs(root)
        names = {}
        for s in sessions:
            name = str(uuid.uuid5(uuid.NAMESPACE_URL, s["id"]))
            names[name] = s["id"]
            t0 = dt.datetime.strptime(s["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
            with open(f"{root}/{name}.jsonl", "w") as f:
                for i, m in enumerate(re.finditer(r"^\[(user|assistant)\] (.*)$", s["content"], re.M)):
                    f.write(json.dumps({"uuid": f"{name}-{i}", "timestamp": (t0 + dt.timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                        "cwd": "/bench/shipctl", "message": {"role": m.group(1), "content": m.group(2)}}) + "\n")
        subprocess.run([CTX, "scan", f"{work}/projects"], env=env, capture_output=True, check=True)
        rows = []
        for q in queries:
            words = re.findall(r"[A-Za-z0-9_'-]+", q["question"])
            out = subprocess.run([CTX, "search", "--all", "--limit", "50", *words], env=env, capture_output=True, text=True).stdout
            ids = re.findall(r"^#(\d+) ", out, re.M)
            got = []
            if ids:
                where = dict(line.split("\t") for line in subprocess.run(
                    [CTX, "sql", "SELECT c.id, cd.session FROM ctx_chunk c JOIN ctx_doc d ON d.id = c.doc_id"
                     " JOIN ctx_capture_day cd ON cd.technote = d.name WHERE c.id IN (" + ",".join(ids) + ")"],
                    env=env, capture_output=True, text=True).stdout.splitlines() if "\t" in line)
                for i in ids:
                    s = names.get(where.get(i, ""))
                    if s and s not in got:
                        got.append(s)
            gold = set(q["goldSessionIds"])
            found = len(gold & set(got[:TOP]))
            rows.append(dict(id=q["id"], type=q["type"], strict=found == len(gold), any=found > 0, frac=found / len(gold)))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    n = len(rows)
    strict, anyhit, frac = sum(r["strict"] for r in rows), sum(r["any"] for r in rows), sum(r["frac"] for r in rows) / n
    print(f"questions {n}; strict recall-all@{TOP} {strict}/{n}; recall@{TOP} {frac:.3f}; any-hit {anyhit}/{n}")
    for r in rows:
        if not r["strict"]:
            print(f"  missed: {r['id']} ({r['type']})")
    if a.record:
        today = dt.date.today()
        result = dict(
            name=os.path.basename(a.record)[:-5], title="A small public set of coding sessions", section="Search", order=30,
            date=today.isoformat(), good_until=(today + dt.timedelta(days=180)).isoformat(), commit=os.environ.get("CTX_COMMIT", ""),
            command="bench/coding_life.py --data DIR",
            conditions={"data": "coding-agent-life-v1 from the agentmemory project: 15 invented sessions on a Rust command-line tool, "
                                "15 questions with the sessions that answer them; public, checksums pinned in the script",
                        "pipeline": "the sessions archived into a fresh ctx database, then ctx search with each question as typed",
                        "scoring": "the first five distinct sessions among the ranked turns; no model involved"},
            summary="The only public set of coding-session questions found. It is tiny and invented, and plain grep nearly ties "
                    "on it, so it is a check that nothing is broken and not a measure of how good a tool is.",
            metrics=[dict(label=f"Questions with every evidence session in the first {TOP}", value=f"{strict} of {n}"),
                     dict(label=f"Recall at {TOP}", value=f"{frac:.3f}"),
                     dict(label=f"Questions with at least one evidence session in the first {TOP}", value=f"{anyhit} of {n}")]
                    + [dict(label="Missed", value=r["id"], note=r["type"]) for r in rows if not r["strict"]])
        if os.path.exists(a.record):  # what it is compared with and what it means are written by hand, and kept
            old = json.load(open(a.record))
            result.update({k: old[k] for k in ("baseline", "meaning", "bar", "verdict") if k in old})
        with open(a.record, "w") as f:
            json.dump(result, f, indent=1)
            f.write("\n")


if __name__ == "__main__":
    main()
