#!/usr/bin/env python3
"""Retrieval on the shipyard corpus (see bench/head-to-head.md): real agent sessions on a
public repository, with questions whose answers exist only in those sessions. For each
question, in both its wordings, a tool returns sessions, and the first five are compared
with the sessions that hold the answer. No model is called.

  bench/shipyard.py --data DIR [--record FILE]

DIR holds sessions/*.jsonl and questions.json. Two arms run here:
  ctx   the transcripts archived into a fresh ctx database with `ctx scan`, then
        `ctx search` with the question as typed
  grep  each session scored by how many of the question's words it contains, then by how
        often; what an agent with only the files and a search tool can do
One question in three is held out by a hash of its id; results are given for all
questions and for the held-out ones.
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")
TOP = 5
STOP = set("""a about after all also an and any are as at be because been before but by can could did do does for from had has
have how i if in into is it its me my no not of on one or our out over so some than that the their them then there these
they this to up us was we were what when where which who why will with would you your""".split())


def held_out(qid):
    return int(hashlib.sha256(qid.encode()).hexdigest(), 16) % 3 == 0


def text_of(path):
    out = []
    for line in open(path, errors="replace"):
        try:
            c = json.loads(line).get("message", {}).get("content")
        except ValueError:
            continue
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, list):
            for b in c:
                if isinstance(b, dict):
                    out.append(b.get("text") or json.dumps(b.get("input") or "") if b.get("type") != "tool_result"
                               else (b.get("content") if isinstance(b.get("content"), str) else json.dumps(b.get("content"))))
    return "\n".join(x for x in out if x).lower()


def grep_arm(sessions):
    texts = {s: text_of(p) for s, p in sessions.items()}

    def search(q):
        terms = [w for w in dict.fromkeys(re.findall(r"[a-z0-9_'-]{3,}", q.lower())) if w not in STOP]
        scored = []
        for s, t in texts.items():
            hits = [t.count(w) for w in terms]
            if any(hits):
                scored.append((sum(h > 0 for h in hits), sum(hits), s))
        return [s for _, _, s in sorted(scored, reverse=True)]
    return search


TURNS = 60  # ranked turns read before the first five distinct sessions are taken


def ctx_arm(sessions, work):
    env = dict(os.environ, CTX_DB=f"{work}/ctx.sqlite", HOME=work)
    subprocess.run([CTX, "init"], env=env, capture_output=True, check=True)
    root = f"{work}/projects/-bench-shipyard"
    os.makedirs(root)
    for s, p in sessions.items():
        shutil.copy(p, f"{root}/{s}.jsonl")
    subprocess.run([CTX, "scan", f"{work}/projects"], env=env, capture_output=True, check=True)

    def search(q):
        words = re.findall(r"[A-Za-z0-9_'-]+", q)
        out = subprocess.run([CTX, "search", "--all", "--limit", str(TURNS), "--", *words], env=env, capture_output=True, text=True).stdout
        ids = re.findall(r"^#(\d+) ", out, re.M)
        if not ids:
            return []
        where = dict(line.split("\t") for line in subprocess.run(
            [CTX, "sql", "SELECT c.id, cd.session FROM ctx_chunk c JOIN ctx_doc d ON d.id = c.doc_id"
             " JOIN ctx_capture_day cd ON cd.technote = d.name WHERE c.id IN (" + ",".join(ids) + ")"],
            env=env, capture_output=True, text=True).stdout.splitlines() if "\t" in line)
        got = []
        for i in ids:
            s = where.get(i)
            if s and s not in got:
                got.append(s)
        return got
    return search


def score(search, qs, wording):
    rows = []
    for q in qs:
        got = search(q[wording])[:TOP]
        gold = set(q["gold_sessions"])
        found = len(gold & set(got))
        rows.append((q["id"], found == len(gold), found > 0))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--record")
    ap.add_argument("--turns", type=int, default=60, help="ranked turns to read from ctx; a corpus of hundreds of sessions needs more")
    a = ap.parse_args()
    global TURNS
    TURNS = a.turns
    sessions = {os.path.basename(p)[:-6]: p for p in sorted(glob.glob(os.path.join(a.data, "sessions", "*.jsonl")))}
    qs = json.load(open(os.path.join(a.data, "questions.json")))
    work = tempfile.mkdtemp(prefix="shipyard-")
    try:
        arms = {"ctx": ctx_arm(sessions, work), "grep": grep_arm(sessions)}
        res = {(arm, w): score(fn, qs, w) for arm, fn in arms.items() for w in ("question", "paraphrase")}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    hold = {q["id"] for q in qs if held_out(q["id"])}
    print(f"{len(sessions)} sessions, {len(qs)} questions ({len(hold)} held out)")
    cells = {}
    for (arm, w), rows in res.items():
        for name, sel in (("all", rows), ("held out", [r for r in rows if r[0] in hold])):
            strict, anyhit = sum(r[1] for r in sel), sum(r[2] for r in sel)
            cells[(arm, w, name)] = (strict, anyhit, len(sel))
            print(f"  {arm:5} {w:10} {name:8} every session {strict:2}/{len(sel)}  at least one {anyhit:2}/{len(sel)}")
    for w in ("question", "paraphrase"):  # paired, on every question
        c, g = dict((r[0], r[1]) for r in res[("ctx", w)]), dict((r[0], r[1]) for r in res[("grep", w)])
        print(f"  all, {w}: ctx alone right on {sum(c[i] and not g[i] for i in c)}, grep alone right on {sum(g[i] and not c[i] for i in c)}")
    for w in ("question", "paraphrase"):  # paired, on the held-out questions
        c, g = dict((r[0], r[1]) for r in res[("ctx", w)]), dict((r[0], r[1]) for r in res[("grep", w)])
        better, worse = sum(c[i] and not g[i] for i in hold), sum(g[i] and not c[i] for i in hold)
        print(f"  held out, {w}: ctx alone right on {better}, grep alone right on {worse}")
    if a.record:
        today = dt.date.today()
        cell = lambda arm, w: "%d of %d" % (cells[(arm, w, "held out")][0], cells[(arm, w, "held out")][2])
        result = dict(
            name=os.path.basename(a.record)[:-5], title="Coding sessions: finding the session that holds the answer", section="Search",
            order=40, date=today.isoformat(), good_until=(today + dt.timedelta(days=180)).isoformat(),
            commit=os.environ.get("CTX_COMMIT", ""), command="bench/shipyard.py --data DIR",
            conditions={"corpus": f"{len(sessions)} real agent sessions on a public repository over a simulated three weeks, "
                                  f"with {len(qs)} questions that the repository and its commit messages do not answer",
                        "held out": f"{len(hold)} questions, chosen by a hash of their ids",
                        "scoring": "every session holding the answer among the first five returned; no model involved"},
            summary="Each question is asked twice: once in the session's own terms, once paraphrased with none of its "
                    "distinctive words. Exact terms favour keyword search; paraphrase is where it is weakest.",
            metrics=[dict(label="ctx, session's own terms", value=cell("ctx", "question")),
                     dict(label="grep, session's own terms", value=cell("grep", "question")),
                     dict(label="ctx, paraphrased", value=cell("ctx", "paraphrase")),
                     dict(label="grep, paraphrased", value=cell("grep", "paraphrase")),
                     dict(label="ctx, all questions, own terms and paraphrased",
                          value="%d and %d of %d" % (cells[("ctx", "question", "all")][0], cells[("ctx", "paraphrase", "all")][0], len(qs))),
                     dict(label="grep, all questions, own terms and paraphrased",
                          value="%d and %d of %d" % (cells[("grep", "question", "all")][0], cells[("grep", "paraphrase", "all")][0], len(qs)))])
        if os.path.exists(a.record):  # what it is compared with and what it means are written by hand, and kept
            old = json.load(open(a.record))
            result.update({k: old[k] for k in ("baseline", "meaning", "bar", "verdict") if k in old})
        with open(a.record, "w") as f:
            json.dump(result, f, indent=1)
            f.write("\n")


if __name__ == "__main__":
    main()
