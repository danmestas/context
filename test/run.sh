#!/bin/sh
# Checks the built binary. Uses only made-up data and a temporary directory.
set -eu

CTX=${CTX:-$PWD/ctx}
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

# Archiving saves technotes and chunks, and a second run stores nothing new.
export CTX_DB="$T/arc.sqlite"
"$CTX" init >/dev/null
A="$T/abcd1234-session.jsonl"
cat > "$A" <<'EOF'
{"uuid":"a-1","timestamp":"2026-03-01T10:00:00Z","cwd":"/work/proj/src","message":{"role":"user","content":"first question about zebras"}}
{"uuid":"a-2","timestamp":"2026-03-01T10:00:05Z","cwd":"/work/proj/src","message":{"role":"assistant","content":[{"type":"text","text":"first answer"}]}}
{"uuid":"a-3","timestamp":"2026-03-02T09:00:00Z","cwd":"/work/proj/src","message":{"role":"user","content":"next day"}}
EOF
[ "$("$CTX" archive "$A")" = "3 turns archived" ] || fail "first archive"
[ "$("$CTX" archive "$A")" = "0 turns archived" ] || fail "second archive stored something"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_capture_day")" = 2 ] || fail "one technote per day"
[ "$("$CTX" sql "SELECT project FROM ctx_capture")" = src ] || fail "project falls back to the directory name"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH 'zebras'")" = 1 ] || fail "search finds a turn"
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_capture_day WHERE day='2026-03-01'" | grep -q 'first answer' || fail "technote body"
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_capture_day WHERE day='2026-03-01'" | grep -q '^## assistant 2026-03-01T10:00:05Z$' || fail "technote heading"

# New turns append to the same day's technote.
echo '{"uuid":"a-4","timestamp":"2026-03-02T09:30:00Z","message":{"role":"assistant","content":"later reply"}}' >> "$A"
[ "$("$CTX" archive "$A")" = "1 turns archived" ] || fail "append"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_capture_day")" = 2 ] || fail "append made a new technote"
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_capture_day WHERE day='2026-03-02'" > "$T/day.txt"
grep -q 'next day' "$T/day.txt" && grep -q 'later reply' "$T/day.txt" || fail "append lost text"

# A line still being written is left for next time.
printf '{"uuid":"a-5","timestamp":"2026-03-02T10:00:00Z","message":{"role":"user","content":"par' >> "$A"
[ "$("$CTX" archive "$A")" = "0 turns archived" ] || fail "partial line was stored"
printf 'tial"}}\n' >> "$A"
[ "$("$CTX" archive "$A")" = "1 turns archived" ] || fail "completed line was not stored"

# A replaced file is read from the start without storing a turn twice.
{ echo '{"uuid":"z-1","timestamp":"2026-03-03T01:00:00Z","message":{"role":"user","content":"replaced file turn"}}'; cat "$A"; } > "$A.new"
mv "$A.new" "$A"
[ "$("$CTX" archive "$A")" = "1 turns archived" ] || fail "replaced file"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk")" = 6 ] || fail "duplicate turns after replacement"

# A secret never reaches the repository or the index.
K="$T/ef567890-session.jsonl"
python3 - "$K" <<'EOF'
import json, sys
value = "aB3" * 8
line = {"uuid": "k-1", "timestamp": "2026-03-04T01:00:00Z",
        "message": {"role": "user", "content": "gh" + "p_" + value + " is the key"}}
open(sys.argv[1], "w").write(json.dumps(line) + "\n")
EOF
"$CTX" archive "$K" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE body LIKE '%aB3aB3aB3%'")" = 0 ] || fail "secret in the index"
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_capture_day WHERE session LIKE 'ef56%'" > "$T/k.txt"
grep -q 'aB3aB3aB3' "$T/k.txt" && fail "secret in the technote"
grep -q 'REDACTED' "$T/k.txt" || fail "redaction marker"

# Search finds a turn, and turn reads it with its neighbours.
export CTX_DB="$T/find.sqlite"
"$CTX" init >/dev/null
S="$T/aaaa1111-s.jsonl"
cat > "$S" <<'EOF'
{"uuid":"s-1","timestamp":"2026-04-01T10:00:00Z","cwd":"/w/alpha","message":{"role":"user","content":"why did the walrus migration stall"}}
{"uuid":"s-2","timestamp":"2026-04-01T10:00:01Z","cwd":"/w/alpha","message":{"role":"assistant","content":"because the lock was held"}}
EOF
O="$T/bbbb2222-s.jsonl"
cat > "$O" <<'EOF'
{"uuid":"o-1","timestamp":"2026-04-02T10:00:00Z","cwd":"/w/beta","message":{"role":"user","content":"a walrus in another project"}}
EOF
"$CTX" archive "$S" >/dev/null; "$CTX" archive "$O" >/dev/null
mkdir -p "$T/alpha"; R=$(cd "$T/alpha" && "$CTX" search --all walrus); [ "$(echo "$R" | grep -c '^#')" = 2 ] || fail "search --all"
echo "$R" | grep -q '\[walrus\]' || fail "search highlights the match"
[ "$(cd "$T/alpha" && "$CTX" search walrus --all --limit 1 | grep -c '^#')" = 1 ] || fail "options after the words"
sq() { "$CTX" sql "$1"; }
ID=$(sq "SELECT c.id FROM ctx_chunk c WHERE c.turn='s-1'")
"$CTX" turn "$ID" 0 1 > "$T/turn.txt"
grep -q 'walrus migration' "$T/turn.txt" && grep -q 'lock was held' "$T/turn.txt" || fail "turn and its neighbour"
[ "$("$CTX" turn "$ID" | grep -c '^--- #')" = 1 ] || fail "turn alone"
sq "INSERT INTO ctx_project(root, project) VALUES ('$T/alpha', 'alpha')" >/dev/null
[ "$(cd "$T/alpha" && "$CTX" search walrus | grep -c '^#')" = 1 ] || fail "search stays in the project"
[ "$(cd "$T" && "$CTX" search walrus 2>/dev/null | grep -c '^#')" = 2 ] || fail "falls back when the project has nothing"
if "$CTX" search the 2>/dev/null; then fail "search with only stopwords"; fi
if "$CTX" turn 999999 2>/dev/null; then fail "missing turn"; fi

# A long turn is cut unless --full is given.
python3 - "$T/cccc3333-s.jsonl" <<'EOF'
import json, sys
line = {"uuid": "l-1", "timestamp": "2026-04-03T10:00:00Z", "cwd": "/w/gamma",
        "message": {"role": "user", "content": "longword " + "x" * 20000}}
open(sys.argv[1], "w").write(json.dumps(line) + "\n")
EOF
"$CTX" archive "$T/cccc3333-s.jsonl" >/dev/null
ID=$(sq "SELECT id FROM ctx_chunk WHERE turn='l-1'")
"$CTX" turn "$ID" | grep -q 'more bytes; use --full' || fail "long turn is cut"
[ "$("$CTX" turn "$ID" --full | wc -c)" -gt 20000 ] || fail "--full shows it all"

# A session can start in one place and work in another, so each turn has its own project.
export CTX_DB="$T/move.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/repo/internal/deep"; mkdir "$T/repo/.git"
M="$T/dddd4444-s.jsonl"
cat > "$M" <<EOF
{"uuid":"m-1","timestamp":"2026-05-01T10:00:00Z","cwd":"$T","message":{"role":"user","content":"pelican started elsewhere"}}
{"uuid":"m-2","timestamp":"2026-05-01T10:00:01Z","cwd":"$T/repo/internal/deep","message":{"role":"assistant","content":"pelican inside the repository"}}
{"uuid":"m-3","timestamp":"2026-05-01T10:00:02Z","cwd":"$T/repo/.claude/worktrees/agent-1","message":{"role":"assistant","content":"pelican in a worktree"}}
EOF
"$CTX" archive "$M" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE project='repo'")" = 2 ] || fail "a turn's project comes from its own directory"
[ "$(cd "$T/repo/internal/deep" && "$CTX" search pelican | grep -c '^#')" = 2 ] || fail "search from a subdirectory finds the repository's turns"

# Hooks return at once, even with many sessions firing, and every transcript lands.
export CTX_DB="$T/hook.sqlite"
"$CTX" init >/dev/null
python3 - "$CTX" "$T" <<'EOF'
import json, os, subprocess, sys, time
ctx, T = sys.argv[1:3]
paths = []
for i in range(20):
    p = f"{T}/{i:08x}-hook.jsonl"
    with open(p, "w") as f:
        for n in range(200):
            f.write(json.dumps({"uuid": f"h{i}-{n}", "timestamp": "2026-06-01T10:00:00Z",
                                "cwd": "/w/hooked", "message": {"role": "user", "content": "turn %d of session %d " % (n, i) + "words " * 50}}) + "\n")
    paths.append(p)
procs = []
for p in paths:
    body = json.dumps({"session_id": "x", "transcript_path": p, "hook_event_name": "Stop"}).encode()
    start = time.time()
    r = subprocess.run([ctx, "hook"], input=body, capture_output=True)
    procs.append(time.time() - start)
    assert r.returncode == 0 and r.stdout == b"", "hook stayed quiet"
assert max(procs) < 1.0, "hook returned quickly: %.3f" % max(procs)
end = time.time() + 60
want = 20 * 200
n = 0
while time.time() < end:
    n = int(subprocess.run([ctx, "sql", "SELECT count(*) FROM ctx_chunk"], capture_output=True, text=True).stdout or 0)
    if n >= want: break
    time.sleep(0.2)
assert n == want, "all turns landed: %d of %d" % (n, want)
EOF

# Junk on stdin never disturbs a session.
echo 'not json' | "$CTX" hook || fail "hook on junk input"
"$CTX" hook </dev/null || fail "hook on empty input"

# A scan catches transcripts no hook reported, and then has nothing to do.
mkdir -p "$T/projects/p1"
echo '{"uuid":"sc-1","timestamp":"2026-06-02T10:00:00Z","cwd":"/w/s","message":{"role":"user","content":"scanned turn"}}' > "$T/projects/p1/12341234-a.jsonl"
touch "$T/projects/p1/ignored.txt"
[ "$("$CTX" scan "$T/projects")" = "1 transcripts read" ] || fail "scan reads a new transcript"
[ "$("$CTX" scan "$T/projects")" = "0 transcripts read" ] || fail "scan has nothing left"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE turn='sc-1'")" = 1 ] || fail "scan stored the turn"

# The deadline reaches the runs a scan starts. ctx re-runs its own argv[0], so
# a stand-in shows what those runs inherit.
python3 - "$CTX" "$T" <<'EOF'
import os, signal, subprocess, sys, time
ctx, T = sys.argv[1:3]
os.makedirs(f"{T}/deadline/p")
with open(f"{T}/deadline/p/d.jsonl", "w") as f:
    f.write("{}\n")
fake = f"{T}/stand-in"
with open(fake, "w") as f:
    f.write(f'#!/bin/sh\necho $$ > {T}/stand-in.pid\nexec sleep 30\n')
os.chmod(fake, 0o755)
p = subprocess.Popen([fake, "scan", f"{T}/deadline"], executable=ctx, stdout=subprocess.DEVNULL,
                     preexec_fn=lambda: signal.alarm(2))
assert p.wait(timeout=20) == -signal.SIGALRM, "scan stopped at its deadline"
pid = int(open(f"{T}/stand-in.pid").read())
end = time.time() + 5
alive = True
while alive and time.time() < end:
    try:
        os.kill(pid, 0)
        time.sleep(0.1)
    except ProcessLookupError:
        alive = False
assert not alive, "child stopped at the same deadline"
EOF

# A missing file is an error.
if "$CTX" extract "$T/none.jsonl" 2>/dev/null; then fail "missing file"; fi

echo "all tests passed"
