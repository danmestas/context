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

# Every prefixed rule is redacted before storage. Values are built so no secret-shaped text sits in this file.
export CTX_DB="$T/rules.sqlite"
"$CTX" init >/dev/null
R="$T/cc001111-rules.jsonl"
python3 - "$R" <<'EOF'
import json, sys
tail = "aB3dE6gH9" * 6
prefixes = ["gh" + "p_", "gh" + "o_", "gh" + "u_", "gh" + "s_", "gh" + "r_", "github" + "_pat_", "s" + "k-", "sk" + "_live_",
            "rk" + "_live_", "wh" + "sec_", "AK" + "IA", "AS" + "IA", "xo" + "xa-", "xo" + "xb-", "xo" + "xp-", "xo" + "xr-",
            "xo" + "xs-", "gl" + "pat-", "np" + "m_", "py" + "pi-", "h" + "f_", "sh" + "pat_", "sh" + "pss_", "AI" + "za",
            "ya" + "29.", "dop" + "_v1_", "lin" + "_api_", "ts" + "key-", "sn" + "trys_", "AGE-SECRET" + "-KEY-1"]
def body(p):
    if p.startswith("AK") or p.startswith("AS") or p.startswith("AGE"):
        return tail.upper()
    if p.startswith("dop"):
        return "abc123" * 10
    return tail
with open(sys.argv[1], "w") as f:
    for i, p in enumerate(prefixes):
        f.write(json.dumps({"uuid": f"r-{i}", "timestamp": "2026-06-03T01:00:00Z", "cwd": "/w/r",
                            "message": {"role": "user", "content": f"value {p}{body(p)} end"}}) + "\n")
EOF
"$CTX" archive "$R" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE body LIKE '%[REDACTED] end'")" = 30 ] || fail "every prefixed rule redacts"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE body LIKE '%aB3dE6gH9%' OR body LIKE '%AB3DE6GH9%' OR body LIKE '%abc123abc123%'")" = 0 ] || fail "a value was stored"

# Secret manager output is redacted even with no recognizable prefix.
D="$T/dd001111-doppler.jsonl"
python3 - "$D" <<'EOF'
import json, sys
text = '{"NAME":{"computed":"plainvalue1234","computedValueType":{"type":"string"},"raw":"plainvalue5678","rawValueType":{"type":"string"}}}'
other = 'an unrelated {"raw":"keep this text","other":1}'
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"uuid": "dj-1", "timestamp": "2026-06-04T01:00:00Z", "cwd": "/w/r", "message": {"role": "user", "content": text + " " + other}}) + "\n")
EOF
"$CTX" archive "$D" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE body LIKE '%plainvalue%'")" = 0 ] || fail "secret manager output is redacted"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE turn='dj-1' AND body LIKE '%keep this text%'")" = 1 ] || fail "ordinary raw fields stay"

# Audit finds what got into storage, and shows only where and what shape.
export CTX_DB="$T/audit.sqlite"
"$CTX" init >/dev/null
python3 - "$T/seed.sql" <<'EOF'
import sys
token = "gh" + "p_" + "Zq7Kp2Lm9Xw4Rt8Vb3Nc6Hj1Df5Gs0Yu"
random = "Qz8Wm3Rt7Yp2Lk5Xn9Bv4Cs6Jh1Gd0Fa2Te"
known = "hunter2-correct-horse"
rows = [("a token " + token, 1), ("blob " + random + " here", 2), ("the value " + known + " again", 3),
        ("password = hunter2", 4), ("ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 5), ("nothing here at all", 6)]
with open(sys.argv[1], "w") as f:
    f.write("INSERT INTO ctx_doc(id, kind, name, project, hash, size, mtime) VALUES (1, 'session', 's', 'p', 'h', 1, 1);\n")
    for b, i in rows:
        f.write(f"INSERT INTO ctx_chunk(id, doc_id, seq, heading, at, project, body) VALUES ({i}, 1, {i}, 'user', '2026-07-01', 'p', '{b}');\n")
open(sys.argv[1] + ".known", "w").write(known + "\nshort\n")
open(sys.argv[1] + ".values", "w").write("\n".join([token, random, known]) + "\n")
EOF
python3 - "$T/seed.sql" "$CTX" <<'EOF'
import subprocess, sys
for line in open(sys.argv[1]):
    subprocess.run([sys.argv[2], "sql", line.strip()], check=True, capture_output=True)
EOF
if "$CTX" audit --limit 20 > "$T/a1.txt"; then fail "audit exits 1 with open findings"; fi
head -1 "$T/a1.txt" | grep -q '6 turns scanned' || fail "audit scans every turn"
grep -q 'github-token' "$T/a1.txt" || fail "audit finds a token"
grep -q 'entropy' "$T/a1.txt" || fail "audit finds a high-entropy value"
grep -c 'turn 5 ' "$T/a1.txt" | grep -q '^0$' || fail "placeholders are not findings"
if "$CTX" audit --known --limit 20 < "$T/seed.sql.known" > "$T/a2.txt"; then fail "known exits 1"; fi
grep -q 'known .*line 1, len=21' "$T/a2.txt" || fail "known value located"
while read -r v; do
  if grep -qF -- "$v" "$T/a1.txt" "$T/a2.txt"; then fail "audit printed a value"; fi
done < "$T/seed.sql.values"
if "$CTX" sql "SELECT shape || fingerprint FROM ctx_audit_finding" | grep -qF -f "$T/seed.sql.values"; then fail "audit stored a value"; fi
# Nothing new is reported twice, and an allowed finding stays quiet.
out=$("$CTX" audit --limit 0 || true); echo "$out" | head -1 | grep -q '^0 turns scanned, 0 new' || fail "audit resumes where it stopped"
for id in $("$CTX" sql "SELECT min(id) FROM ctx_audit_finding WHERE status='open' GROUP BY rule, fingerprint"); do "$CTX" audit --allow "$id" "test" >/dev/null; done
"$CTX" audit --limit 0 > "$T/a3.txt" || fail "audit exits 0 when nothing is open"
out=$("$CTX" audit --all --limit 0) || fail "allowed findings stay allowed on a full rescan"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_audit_run")" -ge 4 ] || fail "runs are counted over time"
"$CTX" sql "UPDATE ctx_audit_finding SET status='open' WHERE rule='entropy'" >/dev/null
"$CTX" audit --tickets --limit 0 > "$T/a4.txt" || true
grep -q 'ticket .* Audit: entropy findings' "$T/a4.txt" || fail "findings become tickets"
"$CTX" audit --tickets --limit 0 > "$T/a5.txt" || true
if grep -q '^ticket ' "$T/a5.txt"; then fail "one ticket per rule at a time"; fi
[ "$("$CTX" ticket ready --all | grep -c 'Audit: entropy')" = 1 ] || fail "the ticket is listed"

# Tickets: created, listed by readiness, claimed once, and finished.
export CTX_DB="$T/tickets.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/proj"; cd "$T/proj"
A=$("$CTX" ticket new "First job" --acceptance "tests pass" --body "details here")
B=$("$CTX" ticket new "Second job" --type Bug --blocked-by "$A")
O=$("$CTX" ticket new "Elsewhere" --project other)
[ "$("$CTX" ticket ready | wc -l | tr -d ' ')" = 1 ] || fail "a blocked ticket is not ready"
"$CTX" ticket ready | grep -q "^$A proj Task First job" || fail "ready lists the ticket"
[ "$("$CTX" ticket ready --all | wc -l | tr -d ' ')" = 2 ] || fail "ready --all"
if "$CTX" ticket claim "$B" 2>/dev/null; then fail "a blocked ticket cannot be claimed"; fi
"$CTX" ticket offer > "$T/offer.json"; python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'First job' in d['hookSpecificOutput']['additionalContext']; assert 'Elsewhere' not in d['hookSpecificOutput']['additionalContext']" "$T/offer.json" || fail "offer lists this project"
[ -z "$(cd "$T" && mkdir -p idle && cd idle && "$CTX" ticket offer)" ] || fail "offer is silent with no work"
python3 - "$CTX" "$A" <<'EOF' || fail "only one claim wins"
import subprocess, sys
ctx, a = sys.argv[1:3]
ps = [subprocess.Popen([ctx, "ticket", "claim", a, "--as", f"agent{i}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(8)]
assert sum(p.wait() == 0 for p in ps) == 1
EOF
"$CTX" ticket show "$A" | grep -q 'Claimed' || fail "ticket is claimed"
"$CTX" ticket show "$A" | grep -q '^assignee: agent' || fail "claim records who"
"$CTX" ticket show "$A" | grep -q '^details here' || fail "show has the body"
[ "$("$CTX" ticket ready | wc -l | tr -d ' ')" = 0 ] || fail "a claimed ticket is not ready"
"$CTX" ticket done "$A" --result abc123 >/dev/null
"$CTX" ticket show "$A" | grep -q '^result: abc123' || fail "done records the result"
"$CTX" ticket ready | grep -q 'Second job' || fail "finishing a blocker readies the next"
"$CTX" ticket drop "$O" --reason "not needed" >/dev/null
[ "$("$CTX" ticket ready --all | wc -l | tr -d ' ')" = 1 ] || fail "dropped tickets leave the list"
if "$CTX" ticket claim nosuch 2>/dev/null; then fail "unknown ticket"; fi
if "$CTX" ticket new "bad type" --type Nope 2>/dev/null; then fail "ticket type is checked"; fi
cd - >/dev/null

# Projects: a shared repository is created, or imported, and the directory is mapped.
export CTX_DB="$T/sources.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/work/sub" "$T/other"
cd "$T/work"
"$CTX" project add my-proj | grep -q 'repo:my_proj' || fail "project add maps the name"
if "$CTX" project add my-proj 2>/dev/null; then fail "a project is added once"; fi
"$CTX" sql "SELECT fsl_export('repo:me', '$T/export.fossil')" >/dev/null
(cd "$T/other" && "$CTX" project add imported --import "$T/export.fossil" >/dev/null) || fail "project import"
[ "$("$CTX" project list | wc -l | tr -d ' ')" = 2 ] || fail "project list"
if "$CTX" project add repo_2 --root "$T/other" 2>/dev/null; then fail "reserved repository names"; fi

# A source needs an origin and a class, and keeps its exact bytes.
printf 'The cache TTL is 30 seconds.\n' > "$T/design.md"
if "$CTX" source add "$T/design.md" --class evergreen 2>/dev/null; then fail "origin is required"; fi
if "$CTX" source add "$T/design.md" --origin "x" 2>/dev/null; then fail "class is required"; fi
if "$CTX" source add "$T/design.md" --origin "x" --class stale 2>/dev/null; then fail "class is checked"; fi
if "$CTX" source add "$T/design.md" --origin "x" --class perishable 2>/dev/null; then fail "perishable needs a review date"; fi
if "$CTX" source add "$T/design.md" --origin "x" --class evergreen --as ../escape.md 2>/dev/null; then fail "paths stay inside sources"; fi
if (cd "$T" && "$CTX" source add "$T/design.md" --origin x --class evergreen 2>/dev/null); then fail "needs a registered project"; fi
(cd sub && "$CTX" source add "$T/design.md" --origin "https://example.test/design" --class evergreen --as notes/design.md --how fetched >/dev/null) || fail "source add"
cmp -s "$T/design.md" sources/notes/design.md || fail "bytes are kept"
python3 - sources/notes/design.md <<'EOF' || fail "origin record"
import hashlib, json, sys
p = sys.argv[1]
m = json.load(open(p + ".origin.json"))
assert m["sha3"] == hashlib.sha3_256(open(p, "rb").read()).hexdigest()
assert m["origin"] == "https://example.test/design" and m["class"] == "evergreen" and m["how"] == "fetched" and m["name"] == "notes/design.md"
assert m["size"] == 29 and m["added_by"] and m["retrieved"]
EOF
"$CTX" source add "$T/design.md" --origin other --class evergreen --as notes/design.md | grep -q 'already recorded' || fail "adding again changes nothing"
grep -q 'example.test' sources/notes/design.md.origin.json || fail "the first origin stands"
printf 'changed\n' > "$T/changed.md"
if "$CTX" source add "$T/changed.md" --origin x --class evergreen --as notes/design.md 2>/dev/null; then fail "a source is not edited in place"; fi
"$CTX" source check | grep -q '^1 sources, 0 problems' || fail "check passes"
"$CTX" source add "$T/design.md" --origin x --class perishable --review-after 2020-01-01 --as old.md >/dev/null
"$CTX" source check > "$T/c1.txt" || fail "due is not a failure"
grep -q 'due for review: sources/old.md' "$T/c1.txt" || fail "due is reported"
printf 'tampered\n' >> sources/notes/design.md
if "$CTX" source check > "$T/c2.txt"; then fail "tampering fails the check"; fi
grep -q 'it changed after its origin' "$T/c2.txt" || fail "tampering is named"
printf 'no record\n' > sources/bare.md
"$CTX" source check | grep -q 'no origin recorded for sources/bare.md' || fail "missing origin is named"
cd - >/dev/null

# Index: sources and wiki pages from a project repository, with citations checked.
export CTX_DB="$T/index.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/ix/co" "$T/ix/root"
(cd "$T/ix/root" && "$CTX" project add kb >/dev/null)
inrepo() { "$CTX" sql "SELECT fsl_open('repo:kb', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
inco() { "$CTX" sql "SELECT fsl_open('$T/ix/co', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
inrepo "fsl_checkout('$T/ix/co')" >/dev/null
mkdir -p "$T/ix/co/sources/sub"
printf '# Design\n\nThe cache TTL is 30\nseconds in production.\n\n## Other\n\nUnrelated walrus text.\n' > "$T/ix/co/sources/sub/design.md"
printf '{"origin":"x"}\n' > "$T/ix/co/sources/sub/design.md.origin.json"
inco "fsl_add('sources')" >/dev/null
inco "fsl_commit('{\"comment\":\"add source\"}')" >/dev/null
CI=$(inrepo "fsl_resolve('trunk')")
python3 - "$T/ix/page.md" "$CI" <<'EOF'
import sys
p, ci = sys.argv[1:3]
open(p, "w").write(f"""# Cache

Entries live 30 seconds.[^a] A bad one.[^b] See [Other](/wiki?name=Other+Page) and [Gone](/wiki?name=Gone).

`[x](/wiki?name=InCode)`

```
[y](/wiki?name=InFence)
```

[^a]: "The cache TTL is 30 seconds in production." [design](/file?name=sources/sub/design.md&ci={ci}&txt=1&ln=3)
[^b]: "This was never written." [design](/file?name=sources/sub/design.md&ci={ci})
[^c]: "A claim from a session." [note](/technote/abc123)
""")
EOF
"$CTX" sql "SELECT fsl_open('repo:kb','tester'), fsl_use('repo:kb'), fsl_wiki_save('Cache', cast(readfile('$T/ix/page.md') as text), 'text/x-markdown')" 2>/dev/null >/dev/null || python3 - "$CTX" "$T/ix/page.md" <<'EOF'
import subprocess, sys
ctx, p = sys.argv[1:3]
t = open(p).read().replace("'", "''")
subprocess.run([ctx, "sql", f"SELECT fsl_open('repo:kb','tester'), fsl_use('repo:kb'), fsl_wiki_save('Cache', '{t}', 'text/x-markdown')"], check=True, capture_output=True)
EOF
inrepo "fsl_wiki_save('Other Page', '# Other', 'text/x-markdown')" >/dev/null
out=$(cd "$T/ix/root" && "$CTX" index); echo "$out" | grep -q '^1 sources, 2 wiki pages, 3 changed, 3 citations, 1 failing' || fail "index counts: $out"
"$CTX" sql "SELECT count(*) FROM ctx_doc WHERE name LIKE '%origin.json'" | grep -q '^0' || fail "origin files are not indexed as sources"
q() { "$CTX" sql "$1"; }
[ "$(q "SELECT status FROM ctx_citation WHERE ref='a'")" = ok ] || fail "a quote is found across a line break"
[ "$(q "SELECT status FROM ctx_citation WHERE ref='b'")" = quote-missing ] || fail "a missing quote is caught"
[ "$(q "SELECT status FROM ctx_citation WHERE ref='c'")" = unchecked ] || fail "a session citation awaits checking"
[ "$(q "SELECT ci FROM ctx_citation WHERE ref='a'")" = "$CI" ] || fail "citation pins the check-in"
[ "$(q "SELECT length(file_hash) FROM ctx_citation WHERE ref='a'")" = 64 ] || fail "citation pins a full hash"
[ "$(q "SELECT count(*) FROM ctx_link WHERE kind='links_to'")" = 2 ] || fail "page links, ignoring code"
[ "$(q "SELECT count(*) FROM ctx_link WHERE kind='compiled_from' AND dst_name='sources/sub/design.md'")" = 1 ] || fail "compiled_from link"
[ "$(q "SELECT count(*) FROM ctx_stale_wiki")" = 0 ] || fail "nothing is stale yet"
[ "$(q "SELECT group_concat(heading) FROM (SELECT heading FROM ctx_chunk c JOIN ctx_doc d ON d.id=c.doc_id WHERE d.kind='source' ORDER BY seq)")" = "Design,Other" ] || fail "chunks by heading"
(cd "$T/ix/root" && "$CTX" search walrus | grep -q 'source Other') || fail "sources are searchable"
out=$(cd "$T/ix/root" && "$CTX" index); echo "$out" | grep -q ' 2 changed\| 0 changed' || fail "an unchanged source is not rewritten: $out"
# A changed source makes the page stale, and a removed one leaves the index.
printf '# Design\n\nThe cache TTL is now 60 seconds.\n' > "$T/ix/co/sources/sub/design.md"
inco "fsl_commit('{\"comment\":\"change source\"}')" >/dev/null
(cd "$T/ix/root" && "$CTX" index >/dev/null)
[ "$(q "SELECT count(*) FROM ctx_stale_wiki")" = 1 ] || fail "a changed source makes the page stale"
[ "$(q "SELECT status FROM ctx_citation WHERE ref='a'")" = ok ] || fail "a pinned citation still resolves at its version"
inco "fsl_rm('sources/sub/design.md')" >/dev/null; inco "fsl_commit('{\"comment\":\"remove source\"}')" >/dev/null
(cd "$T/ix/root" && "$CTX" index >/dev/null)
[ "$(q "SELECT count(*) FROM ctx_doc WHERE kind='source'")" = 0 ] || fail "a removed source leaves the index"
[ "$(q "SELECT count(*) FROM ctx_chunk c JOIN ctx_doc d ON d.id=c.doc_id WHERE d.kind='source'")" = 0 ] || fail "its chunks go too"
[ "$(q "SELECT count(*) FROM ctx_stale_wiki")" = 1 ] || fail "a page citing a removed source is stale"
# Pull brings in new work from another copy.
"$CTX" sql "SELECT fsl_export('repo:kb', '$T/ix/upstream.fossil')" >/dev/null 2>&1 || "$CTX" sql "SELECT fsl_open('repo:kb','t'), fsl_export('repo:kb', '$T/ix/upstream.fossil')" >/dev/null
export CTX_DB="$T/index2.sqlite"
"$CTX" init >/dev/null
(cd "$T/ix/root" && "$CTX" project add kb2 --root "$T/other" --import "$T/ix/upstream.fossil" >/dev/null)
"$CTX" project pull kb2 --from "$T/ix/upstream.fossil" | grep -q 'received' || fail "pull"
if "$CTX" project pull kb2 2>/dev/null; then fail "pull needs a source"; fi

# The skill eval harness works end to end with a stand-in for the model.
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/../eval/test_eval.py" "$CTX" || fail "eval harness"

# A missing file is an error.
if "$CTX" extract "$T/none.jsonl" 2>/dev/null; then fail "missing file"; fi

echo "all tests passed"
