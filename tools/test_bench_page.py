#!/usr/bin/env python3
"""Tests for bench_page.py; each case works in a temporary directory."""
import contextlib
import io
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_page

TODAY = "2026-11-11"


def result(name, **kw):
    r = {"name": name, "title": name.title(), "section": "Search", "date": "2026-11-01",
         "good_until": "2027-05-01", "commit": "0123456789abcdef", "command": "sh bench/run.sh",
         "conditions": {"archive": "1.3 GB"}, "summary": "It works.",
         "metrics": [{"label": "hits", "value": "9 of 10", "note": "top five"}]}
    r.update(kw)
    return r


def put(d, name, r):
    os.makedirs(f"{d}/res", exist_ok=True)
    with open(f"{d}/res/{name}.json", "w") as f:
        json.dump(r, f)


def run(d, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = bench_page.main(["--results", f"{d}/res", "--out", f"{d}/docs/b.md", "--today", TODAY, *args])
        except SystemExit as e:
            rc = e.code
    return rc, out.getvalue(), err.getvalue()


def page(d):
    return open(f"{d}/docs/b.md").read()


def tmp():
    return tempfile.TemporaryDirectory()


def test_render_order():
    with tmp() as d:
        put(d, "z", result("z", section="Safety", verdict="fail", bar="none missed"))
        put(d, "b", result("b", order=2))
        put(d, "a", result("a", order=1, verdict="pass", bar="9 of 10", commit=""))
        put(d, "c", result("c", section="Search", order=2, title="Alpha"))
        assert run(d)[0] == 0
        p = page(d)
        assert p.startswith("# Benchmarks\n")
        assert p.index("## Search") < p.index("## Safety")
        assert "## Rules" not in p
        assert p.index("### A") < p.index("### Alpha") < p.index("### B")
        assert "| hits | 9 of 10 (top five) |" in p
        assert "check-in 0123456789ab;" in p and "0123456789abc" not in p
        assert "- **Bar:** 9 of 10. **Passed.**" in p and "- **Bar:** none missed. **Failed.**" in p
        assert "```sh\nsh bench/run.sh\n```" in p
        assert "- archive: 1.3 GB" in p and "(../bench/results/a.json)" in p
        assert bench_page.PAST not in p
        assert "check-in" not in p.split("### A\n")[1].split("###")[0]


def test_deterministic():
    with tmp() as d:
        put(d, "a", result("a"))
        run(d)
        first = page(d)
        run(d)
        assert first == page(d)


def test_check():
    with tmp() as d:
        put(d, "a", result("a"))
        assert run(d, "--check")[0] == 1
        run(d)
        assert run(d, "--check")[0] == 0
        put(d, "a", result("a", summary="Changed."))
        rc, _, err = run(d, "--check")
        assert rc == 1 and "out of step" in err and "+Changed." in err
        run(d)
        with open(f"{d}/docs/b.md", "a") as f:
            f.write("hand edit\n")
        assert run(d, "--check")[0] == 1


def test_errors():
    bad = {
        "unknown": (result("a", extra=1), "unknown key"),
        "section": (result("a", section="Other"), "unknown section"),
        "date": (result("a", date="2026-13-01"), "date"),
        "good_until": (result("a", good_until="soon"), "good_until"),
        "type": (result("a", title=5), "title must be a string"),
        "order": (result("a", order="1"), "order"),
        "verdict": (result("a", verdict="maybe"), "verdict"),
        "metrics": (result("a", metrics=[]), "metrics"),
        "metric": (result("a", metrics=[{"label": "x"}]), "metric"),
        "conditions": (result("a", conditions={"k": 1}), "conditions"),
        "mismatch": (result("other"), "does not match"),
    }
    for k, (r, msg) in bad.items():
        with tmp() as d:
            put(d, "a", r)
            for args in ((), ("--check",)):
                rc, _, err = run(d, *args)
                assert rc == 1 and "a.json" in err and msg in err, (k, err)
    with tmp() as d:
        r = result("a")
        del r["summary"]
        put(d, "a", r)
        assert "missing key 'summary'" in run(d)[2]
        os.remove(f"{d}/res/a.json")
        open(f"{d}/res/broken.json", "w").write("{")
        assert "broken.json" in run(d)[2]


def test_past_date():
    with tmp() as d:
        put(d, "old", result("old", good_until="2026-11-10"))
        put(d, "new", result("new", good_until="2026-11-11"))
        run(d)
        assert page(d).count(bench_page.PAST) == 1
        rc, out, _ = run(d, "--check")
        assert rc == 0 and out.count("warning") == 1 and "old" in out


def test_empty():
    with tmp() as d:
        assert run(d, "--check")[0] == 0
        run(d)
        assert "No results are recorded yet." in page(d)
        assert run(d, "--check")[0] == 0
        os.makedirs(f"{d}/res")
        assert run(d, "--check")[0] == 0


for name, fn in sorted(globals().items()):
    if name.startswith("test_"):
        fn()
print("bench page tests passed")
