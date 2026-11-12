# Benchmark results

Each benchmark writes one file here, `NAME.json`, and the public page
`docs/benchmarks.md` is generated from these files. No figure on the page is typed by hand.

A result file is a JSON object with exactly these keys: `name` (the file name without
`.json`), `title`, `section` (Search, Agent behaviour, Rules, Records, Speed or Safety),
`order` (optional integer, default 100), `date` and `good_until` (YYYY-MM-DD), `commit`
and `command` (strings, may be empty), `conditions` (object of strings, may be empty),
`summary`, `metrics` (non-empty list of `{label, value, note}`, note optional), and
optionally `bar` (the pass bar set before the run) and `verdict` (pass, fail or none).
Unknown keys, missing keys, wrong types and bad dates are errors.

    python3 tools/bench_page.py           # write docs/benchmarks.md
    python3 tools/bench_page.py --check   # fail if the page is out of step

`make bench-page` writes the page; `make check` runs the check with the real date, so a
result past its `good_until` date changes the page until it is regenerated.
