#!/usr/bin/env python3
"""Generates docs/benchmarks.md from the result files in bench/results.

  tools/bench_page.py [--results bench/results] [--out docs/benchmarks.md] [--today 2026-11-11]
  tools/bench_page.py --check

The page is a pure function of the result files and --today (default: the system
date), so --check can fail when the page on disk is out of step. `make check` passes
the real date, which means a result that goes past its date changes the expected page
and the page must be regenerated. --check also warns, without failing, for each result
past its date. With no result files and no page on disk, --check passes.
"""
import argparse
import datetime as dt
import difflib
import glob
import json
import os
import re
import sys

SECTIONS = ["Search", "Agent behaviour", "Rules", "Records", "Speed", "Safety"]
VERDICTS = {"pass": "passed", "fail": "failed"}
STR_KEYS = ["name", "title", "section", "date", "good_until", "commit", "command", "summary"]
KEYS = set(STR_KEYS) | {"conditions", "metrics", "order", "bar", "verdict", "baseline", "meaning"}
REQUIRED = KEYS - {"order", "bar", "verdict", "baseline", "meaning"}
INTRO = """This page lists what ctx has been measured to do. Every figure comes from a result \
file in `bench/results/`, and each result shows the date it was measured, the check-in it was \
measured on and the command that reruns it. Figures measured on the author's own private \
session archive give counts only, because the sessions themselves are not published. Results \
that failed the bar set before the run are kept on purpose."""
HOW = [
    "## How to read this page",
    "",
    "- **Compared with** names the baseline. It is always ctx against what an agent would do without it, or ctx "
    "with a change against ctx without it. No other tool has been measured here, so nothing on this page says "
    "ctx is better or worse than another product.",
    "- **Bar** is the threshold that was written down before the run. \"Passed\" and \"failed\" refer to that "
    "threshold and nothing else. A result with no bar only describes; it was not a test.",
    "- **What it means** says what the result changed: what was kept, what was removed, and what is still unknown.",
    "- A score such as recall is out of 1, and a score \"of 90\" is out of that many questions. Sample sizes are "
    "small, so a difference of one or two questions is not evidence of anything.",
    "- Most figures come from one person's session archive. They show how ctx behaves on that archive, not on yours.",
    "",
]
OUTCOME = {"pass": "Passed its bar", "fail": "Failed its bar"}
PAST = "This result is past its date and is due a rerun."


class Bad(Exception):
    pass


def is_date(s):
    try:
        return isinstance(s, str) and re.fullmatch(r"\d{4}-\d\d-\d\d", s) and dt.date.fromisoformat(s)
    except ValueError:
        return False


def load(path):
    base = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
    except (OSError, ValueError) as e:
        raise Bad(f"{path}: cannot read: {e}")
    bad = lambda m: Bad(f"{path}: {m}")
    if not isinstance(r, dict):
        raise bad("not a JSON object")
    for k in sorted(set(r) - KEYS):
        raise bad(f"unknown key {k!r}")
    for k in sorted(REQUIRED - set(r)):
        raise bad(f"missing key {k!r}")
    for k in STR_KEYS + ["bar", "baseline", "meaning"]:
        if k in r and not isinstance(r[k], str):
            raise bad(f"{k} must be a string")
    if r["name"] != base[:-5]:
        raise bad(f"name {r['name']!r} does not match the file name")
    if not r["title"] or not r["summary"]:
        raise bad("title and summary must not be empty")
    if r["section"] not in SECTIONS:
        raise bad(f"unknown section {r['section']!r}")
    for k in ("date", "good_until"):
        if not is_date(r[k]):
            raise bad(f"{k} is not a YYYY-MM-DD date: {r[k]!r}")
    if "order" in r and (type(r["order"]) is not int):
        raise bad("order must be an integer")
    if "verdict" in r and r["verdict"] not in ("pass", "fail", "none"):
        raise bad(f"verdict must be pass, fail or none: {r['verdict']!r}")
    c = r["conditions"]
    if not isinstance(c, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in c.items()):
        raise bad("conditions must be an object of strings")
    m = r["metrics"]
    if not isinstance(m, list) or not m:
        raise bad("metrics must be a non-empty list")
    for x in m:
        if not (isinstance(x, dict) and set(x) <= {"label", "value", "note"} and {"label", "value"} <= set(x)
                and all(isinstance(v, str) for v in x.values())):
            raise bad("each metric must be an object of strings with label, value and optional note")
    return r


def cell(s):
    return s.replace("|", "\\|").replace("\n", " ")


def render(r, today):
    o = [f"### {r['title']}", "", r["summary"], ""]
    if r.get("baseline"):
        o.append(f"- **Compared with:** {r['baseline']}")
    if r.get("bar"):
        o.append(f"- **Bar:** {r['bar']}. **{VERDICTS.get(r.get('verdict'), 'Not judged').capitalize()}.**")
    elif r.get("baseline") or r.get("meaning"):
        o.append("- **Bar:** none; this result describes and was not a test.")
    if r.get("meaning"):
        o.append(f"- **What it means:** {r['meaning']}")
    if o[-1]:
        o.append("")
    o += ["| Measure | Result |", "| --- | --- |"]
    for m in r["metrics"]:
        v = cell(m["value"]) + (f" ({cell(m['note'])})" if m.get("note") else "")
        o.append(f"| {cell(m['label'])} | {v} |")
    p = [f"measured {r['date']}"]
    if r["commit"]:
        p.append(f"check-in {r['commit'][:12]}")
    p.append(f"good until {r['good_until']}")
    o += ["", "Measured " + "; ".join(p)[9:] + "."]
    if r["good_until"] < today:
        o += ["", PAST]
    if r["conditions"]:
        o += [""] + [f"- {k}: {v}" for k, v in r["conditions"].items()]
    if r["command"]:
        o += ["", "```sh", r["command"], "```"]
    o += ["", f"[Result file](../bench/results/{r['name']}.json)", ""]
    return o


def files(results):
    return sorted(glob.glob(os.path.join(results, "*.json")))


def build(results, today):
    rs = [load(p) for p in files(results)]
    o = ["# Benchmarks", "", INTRO, ""]
    if not rs:
        o += ["No results are recorded yet.", ""]
    else:
        o += HOW + ["## At a glance", "", "| Result | Outcome | What it means |", "| --- | --- | --- |"]
        for s in SECTIONS:
            for r in sorted((r for r in rs if r["section"] == s), key=lambda r: (r.get("order", 100), r["title"], r["name"])):
                o.append(f"| {cell(r['title'])} | {OUTCOME.get(r.get('verdict'), 'No bar')} | {cell(r.get('meaning', ''))} |")
        o.append("")
    for s in SECTIONS:
        sec = sorted((r for r in rs if r["section"] == s), key=lambda r: (r.get("order", 100), r["title"], r["name"]))
        if sec:
            o += [f"## {s}", ""]
            for r in sec:
                o += render(r, today)
    return "\n".join(o).rstrip("\n") + "\n", [r for r in rs if r["good_until"] < today]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", default="bench/results")
    ap.add_argument("--out", default="docs/benchmarks.md")
    ap.add_argument("--today")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    if a.today and not is_date(a.today):
        ap.error("--today must be YYYY-MM-DD")
    try:
        page, stale = build(a.results, a.today or dt.date.today().isoformat())
    except Bad as e:
        print(e, file=sys.stderr)
        return 1
    if not a.check:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(page)
        return 0
    for r in stale:
        print(f"warning: {r['name']} is past its date ({r['good_until']}) and is due a rerun")
    have = os.path.exists(a.out)
    if not have and not files(a.results):
        return 0
    cur = open(a.out, encoding="utf-8").read() if have else None
    if cur == page:
        return 0
    why = "is missing" if cur is None else "is out of step with the result files"
    print(f"{a.out} {why}; run: python3 tools/bench_page.py", file=sys.stderr)
    diff = list(difflib.unified_diff((cur or "").splitlines(), page.splitlines(), a.out, "generated", lineterm=""))
    print("\n".join(diff[:40]), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
