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

# Secrets are removed and ordinary text is left alone. Test values are put
# together at run time so that no token-shaped strings are committed.
python3 - "$T/secrets.jsonl" "$T/secrets.want" <<'EOF'
import json, sys
a20 = "aB3" * 8
hex40 = "0123456789abcdef" * 3
remove = [
    "gh" + "p_" + a20, "github" + "_pat_" + a20 * 2, "s" + "k-ant-" + a20,
    "AK" + "IA" + "ABCDEFGH23456789", "xo" + "xb-" + a20, "dp." + "st." + a20,
    "ey" + "J" + a20 + "." + a20 + "." + a20,
]
cases = [(f"use {s} here", s, "use ") for s in remove]
cases += [
    ("password=" + a20 + " done", a20, "password="),
    ('{"api_key":"' + a20 + '"}', a20, "api_key"),
    ("TOKEN: " + a20, a20, "TOKEN"),
    ("Authorization: Bearer " + a20 + "x", a20, "Bearer"),
    ("https://user:" + a20 + "@example.com/x", a20, "example.com/x"),
    ("ACCESS_KEY_ID=" + hex40, hex40, "ACCESS_KEY_ID"),
    ("-----BEGIN RSA PRIVATE KEY-----\n" + a20 + "\n-----END RSA PRIVATE KEY-----\nafter", a20, "after"),
]
keep = [
    "the token limit was exceeded", "secret management is hard",
    "password: $DB_PASSWORD", "token = ${API_TOKEN}", "https://example.com:8080/x@y",
    "sk-short", "a task-AKIA1", "token_count: 123456789", "see the bearer of bad news here",
]
with open(sys.argv[1], "w") as f:
    for i, text in enumerate([c[0] for c in cases] + keep):
        f.write(json.dumps({"uuid": str(i), "timestamp": "t", "message": {"role": "user", "content": text}}) + "\n")
json.dump({"cases": cases, "keep": keep}, open(sys.argv[2], "w"))
EOF
"$CTX" extract "$T/secrets.jsonl" > "$T/secrets.txt"
python3 - "$T/secrets.txt" "$T/secrets.want" <<'EOF'
import json, sys
out = open(sys.argv[1]).read()
want = json.load(open(sys.argv[2]))
turns = out.split("\n--- ")
assert len(turns) == len(want["cases"]) + len(want["keep"]), "every turn present"
for (text, secret, kept), turn in zip(want["cases"], turns):
    assert secret not in turn, "secret left in: case " + text[:12]
    assert "[REDACTED]" in turn and kept in turn, "context lost: case " + text[:12]
for text, turn in zip(want["keep"], turns[len(want["cases"]):]):
    assert text in turn and "[REDACTED]" not in turn, "changed ordinary text: " + text
EOF

# A truncated final line, as when a transcript is still being written, is ignored.
printf '{"uuid":"c-1","timestamp":"t","message":{"role":"user","content":"whole"}}\n{"uuid":"c-2","mess' > "$T/partial.jsonl"
"$CTX" extract "$T/partial.jsonl" > "$T/partial.txt"
[ "$(grep -c '^--- ' "$T/partial.txt")" = 1 ] || fail "partial line"

# A missing file is an error.
if "$CTX" extract "$T/none.jsonl" 2>/dev/null; then fail "missing file"; fi

echo "all tests passed"
