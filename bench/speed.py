#!/usr/bin/env python3
"""Times what ctx does inside an agent session, on the archive this machine has: the
hooks Claude Code waits for, and the commands an agent runs. Each is run several times
and the median is reported, with the archive's size and the machine's load, since both
change the answer.

  bench/speed.py [--runs 7] [--record bench/results/speed.json]

Only reads: nothing here scans, archives or writes to the database. The recorded file
holds timings and rounded sizes, never anything from the archive itself.
"""
import argparse
import datetime as dt
import json
import os
import shutil
import statistics
import subprocess
import time

CTX = os.environ.get("CTX") or os.path.realpath(shutil.which("ctx") or "ctx")


def sql(q):
    return subprocess.run([CTX, "sql", q], capture_output=True, text=True, check=True).stdout.strip()


def timed(args, stdin, runs):
    out = []
    for _ in range(runs):
        t = time.perf_counter()
        subprocess.run([CTX, *args], input=stdin, capture_output=True, text=True)
        out.append((time.perf_counter() - t) * 1000)
    return statistics.median(out), max(out)


def rounded(n):
    """Two significant figures, so a size is a condition and not a fingerprint."""
    digits = len(str(int(n)))
    step = 10 ** max(digits - 2, 0)
    return int(round(n / step) * step)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--record")
    a = ap.parse_args()
    session = sql("SELECT session FROM ctx_capture_day ORDER BY day DESC LIMIT 1")
    turn = sql("SELECT max(id) FROM ctx_chunk")
    hook = lambda **kw: json.dumps(dict(session_id=session, **kw))
    cases = [
        ("Session start: rules and archive note", ["rules", "offer"], hook(source="startup")),
        ("Session start: open tickets", ["ticket", "offer"], hook(source="startup")),
        ("After a compaction: the brief", ["rules", "offer"], hook(source="compact")),
        ("Subagent start: archive note", ["rules", "offer"], hook(hook_event_name="SubagentStart")),
        ("Prompt submitted: recall check", ["recall"], json.dumps({"prompt": "do you remember the timeout fix"})),
        ("Status line", ["status"], ""),
        ("Search, two words", ["search", "timeout", "error"], ""),
        ("Read a turn with its neighbours", ["turn", turn, "2", "5"], ""),
        ("List decisions", ["decisions", "--limit", "5"], ""),
        ("List published pages", ["artifacts", "--limit", "5"], ""),
    ]
    load = os.getloadavg()[0]
    rows = []
    for label, args, stdin in cases:
        med, worst = timed(args, stdin, a.runs)
        rows.append((label, med, worst))
        print(f"{label:42} median {med:7.0f} ms   slowest {worst:7.0f} ms")
    size = os.path.getsize(os.environ.get("CTX_DB") or os.path.expanduser("~/.ctx/ctx.sqlite"))
    turns = rounded(int(turn))
    print(f"archive {size / 1e9:.1f} GB, about {turns:,} turns; load average {load:.0f} on {os.cpu_count()} cores")
    if a.record:
        today = dt.date.today()
        result = dict(
            name=os.path.basename(a.record)[:-5], title="Hooks and commands on a real archive", section="Speed", order=10,
            date=today.isoformat(), good_until=(today + dt.timedelta(days=90)).isoformat(),
            commit=os.environ.get("CTX_COMMIT", ""),  # the check-in the measured binary was built from
            command=f"bench/speed.py --runs {a.runs}",
            conditions={"archive": f"{size / 1e9:.1f} GB, about {turns:,} turns",
                        "machine": f"{os.cpu_count()} cores, load average {load:.0f} while measuring",
                        "runs": f"{a.runs} each; the median is reported"},
            summary="How long an agent session waits for ctx. Hooks run on every session start, compaction and "
                    "subagent start, so they are held to a 3-second limit and should take a small fraction of it.",
            metrics=[dict(label=label, value=f"{med:.0f} ms", note=f"slowest {worst:.0f} ms") for label, med, worst in rows],
            bar="every hook's slowest run under 1,000 ms", verdict="pass" if all(w < 1000 for l, m, w in rows[:6]) else "fail")
        if os.path.exists(a.record):  # what it is compared with and what it means are written by hand, and kept
            old = json.load(open(a.record))
            result.update({k: old[k] for k in ("baseline", "meaning") if k in old})
        with open(a.record, "w") as f:
            json.dump(result, f, indent=1)
            f.write("\n")


if __name__ == "__main__":
    main()
