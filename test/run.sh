#!/bin/sh
# Checks the built binary. Uses only made-up data and a temporary directory.
set -eu

CTX=${CTX:-./ctx}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }

"$CTX" version | grep -q '^sqlite 3\.' || fail "version"

# init creates the database, and running it again changes nothing.
export CTX_DB="$T/ctx.sqlite"
"$CTX" init >/dev/null
"$CTX" init >/dev/null
[ -s "$CTX_DB" ] || fail "init created no database"

# init must not need a HOME when CTX_DB is set, and must make ~/.ctx when not.
(unset CTX_DB; HOME="$T/home"; export HOME; mkdir -p "$HOME"; "$CTX" init >/dev/null
 [ -s "$HOME/.ctx/ctx.sqlite" ]) || fail "init in HOME"

# Extraction keeps conversation and tool text and drops everything else.
"$CTX" extract test/fixture.jsonl > "$T/out.txt"
cmp "$T/out.txt" test/expected.txt || { diff "$T/out.txt" test/expected.txt >&2 || true; fail "extract"; }

# Long tool output keeps both ends and is cut on a character boundary.
python3 - "$T/big.jsonl" <<'EOF'
import json, sys
middle = "é" * 40000
text = "HEAD" + middle + "TAIL"
line = {"uuid": "b-1", "timestamp": "t", "message": {"role": "user",
        "content": [{"type": "tool_result", "content": text}]}}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(json.dumps(line, ensure_ascii=False) + "\n")
EOF
"$CTX" extract "$T/big.jsonl" > "$T/big.txt"
python3 - "$T/big.txt" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
text = data.decode("utf-8")  # raises if a character was split
assert "HEAD" in text and "TAIL" in text, "both ends kept"
assert "bytes cut ...]" in text, "cut is marked"
assert len(data) < 34000, "output was cut"
EOF

# A truncated final line, as when a transcript is still being written, is ignored.
printf '{"uuid":"c-1","timestamp":"t","message":{"role":"user","content":"whole"}}\n{"uuid":"c-2","mess' > "$T/partial.jsonl"
"$CTX" extract "$T/partial.jsonl" > "$T/partial.txt"
[ "$(grep -c '^--- ' "$T/partial.txt")" = 1 ] || fail "partial line"

# A missing file is an error.
if "$CTX" extract "$T/none.jsonl" 2>/dev/null; then fail "missing file"; fi

echo "all tests passed"
