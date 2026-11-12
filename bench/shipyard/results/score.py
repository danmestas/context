#!/usr/bin/env python3
"""Scores the arm files in this folder the way bench/shipyard.py scores ctx and grep:
for each arm and wording, on all questions and on the held-out third, how many questions
have every gold session among the first five sessions returned, and how many have at least one.

  python3 score.py [--questions ../questions.json] [arm.json ...]
"""
import argparse, glob, hashlib, json, os

TOP = 5


def held_out(qid):
    return int(hashlib.sha256(qid.encode()).hexdigest(), 16) % 3 == 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--questions", default=os.path.join(here, "..", "questions.json"))
    ap.add_argument("arms", nargs="*")
    a = ap.parse_args()
    qs = {q["id"]: set(q["gold_sessions"]) for q in json.load(open(a.questions))}
    hold = {i for i in qs if held_out(i)}
    files = a.arms or sorted(glob.glob(os.path.join(here, "*.json")))
    print(f"{len(qs)} questions ({len(hold)} held out)")
    for f in files:
        d = json.load(open(f))
        for w in ("question", "paraphrase"):
            got = {r["id"]: r["sessions"][:TOP] for r in d["results"] if r["wording"] == w}
            rows = []
            for i, gold in qs.items():
                found = len(gold & set(got.get(i, [])))
                rows.append((i, found == len(gold), found > 0))
            for name, sel in (("all", rows), ("held out", [r for r in rows if r[0] in hold])):
                strict, anyhit = sum(r[1] for r in sel), sum(r[2] for r in sel)
                print(f"  {d['arm']:18} {w:10} {name:8} every session {strict:2}/{len(sel)}  at least one {anyhit:2}/{len(sel)}")


if __name__ == "__main__":
    main()
