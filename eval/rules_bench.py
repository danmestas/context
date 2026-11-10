#!/usr/bin/env python3
"""Measures a rule classifier: any command that reads a prompt on stdin and answers on
stdout, as `ctx rules propose` runs it. It is given ctx's own prompt and a labelled set
of turns the person typed, and is scored on how many standing instructions it finds
(recall) and how many of its finds are real (precision).

  eval/rules_bench.py --classify "claude -p --model haiku --tools ''"
  eval/rules_bench.py --classify "claude-codex -p --model sonnet --tools ''" --name deepseek

The labelled set is private and stays in ~/.ctx/eval/rules: a JSON list of objects with
"id", "text" and "truth" (whether it is a standing instruction).
"""
import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import time

CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")
LABELS = os.path.expanduser("~/.ctx/eval/rules/standing-sample-1000.json")


def classify(cmd, prompt, items, deadline):
    """The ids the classifier calls standing, or None when it fails or answers nothing readable."""
    lines = "".join(json.dumps({"turn": str(x["id"]), "text": x["text"]}) + "\n" for x in items)
    try:
        p = subprocess.run(cmd, shell=True, input=prompt + lines, capture_output=True, text=True, timeout=deadline, cwd="/tmp")
    except subprocess.TimeoutExpired:
        return None
    out = p.stdout
    try:  # a CLI may wrap the answer in JSON of its own
        out = json.loads(out).get("result", out)
    except (ValueError, AttributeError):
        pass
    m = re.search(r"\[.*\]", out or "", re.S)
    if p.returncode or not m:
        return None
    try:
        return {str(x.get("turn")) for x in json.loads(m.group(0)) if isinstance(x, dict)}
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--classify", required=True, help="the classifier command, as ctx rules classifier takes it")
    ap.add_argument("--labels", default=LABELS)
    ap.add_argument("--name", default="classifier")
    ap.add_argument("--batch", type=int, default=25)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--deadline", type=int, default=600)
    a = ap.parse_args()
    prompt = subprocess.run([CTX, "rules", "prompt"], capture_output=True, text=True, check=True).stdout
    items = json.load(open(a.labels))
    batches = [items[i:i + a.batch] for i in range(0, len(items), a.batch)]
    t0 = time.time()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        answers = list(ex.map(lambda b: classify(a.classify, prompt, b, a.deadline), batches))
    found, failed = set(), 0
    for b, ans in zip(batches, answers):
        if ans is None:
            failed += len(b)
        else:
            found |= ans & {str(x["id"]) for x in b}
    scored = [x for b, ans in zip(batches, answers) if ans is not None for x in b]
    truth = {str(x["id"]) for x in scored if x["truth"]}
    tp = len(found & truth)
    recall = tp / len(truth) if truth else 0
    precision = tp / len(found) if found else 0
    print(f"{a.name}: {len(scored)} turns scored, {failed} lost to failed answers, {time.time() - t0:.0f}s")
    print(f"  standing in truth {len(truth)}, found {len(found)}, right {tp}")
    print(f"  recall {recall:.0%}  precision {precision:.0%}")
    by = {str(x["id"]): x for x in scored}
    for i in sorted(truth - found)[:8]:
        print(f"  missed: {by[i]['text'][:110]}")
    for i in sorted(found - truth)[:8]:
        print(f"  extra:  {by[i]['text'][:110]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
