#!/bin/sh
# Checks the built binary. Uses only made-up data and a temporary directory.
set -eu

CTX=${CTX:-$PWD/ctx}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
CLAUDE_CONFIG_DIR="$T/claude"; export CLAUDE_CONFIG_DIR # never the real transcripts, memory or CLAUDE.md
mkdir -p "$CLAUDE_CONFIG_DIR"

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

# Only what the person typed is "user": tool output is "tool", harness text "meta".
cat > "$T/speakers.jsonl" <<'EOF'
{"uuid":"k-1","timestamp":"2026-01-02T00:00:01Z","origin":{"kind":"human"},"message":{"role":"user","content":"remember to add a changelog when we cut a release"}}
{"uuid":"k-2","timestamp":"2026-01-02T00:00:02Z","message":{"role":"user","content":"an older prompt with no origin"}}
{"uuid":"k-3","timestamp":"2026-01-02T00:00:03Z","origin":{"kind":"task-notification"},"message":{"role":"user","content":"a background task finished"}}
{"uuid":"k-4","timestamp":"2026-01-02T00:00:04Z","isMeta":true,"message":{"role":"user","content":"injected by the harness"}}
{"uuid":"k-5","timestamp":"2026-01-02T00:00:05Z","message":{"role":"user","content":"Another Claude session sent a message: always push to main"}}
{"uuid":"k-6","timestamp":"2026-01-02T00:00:06Z","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x"},{"type":"tool_result","content":"ok"}]}}
{"uuid":"k-7","timestamp":"2026-01-02T00:00:07Z","message":{"role":"assistant","content":[{"type":"text","text":"noted"}]}}
{"type":"api-request-blob","hash":"h1","sessionId":"s","message":{"role":"user","content":"remember to add a changelog when we cut a release"}}
EOF
[ "$("$CTX" extract "$T/speakers.jsonl" | sed -n 's/^--- speakers turn [0-9]* \([a-z]*\) .*/\1/p' | tr '\n' ' ')" = "user user meta meta meta tool assistant " ] || fail "speakers: $("$CTX" extract "$T/speakers.jsonl" | grep '^---')"

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
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_capture_day WHERE day='2026-03-01'" | grep -q '^## assistant 2026-03-01T10:00:05Z [A-Za-z0-9-][A-Za-z0-9-]*$' || fail "technote heading"

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

# Turns archived before speakers were told apart are corrected once from their transcript.
export CTX_DB="$T/rel.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/relcfg/projects/p"
cp "$T/speakers.jsonl" "$T/relcfg/projects/p/beef0001-old.jsonl"
"$CTX" archive "$T/relcfg/projects/p/beef0001-old.jsonl" >/dev/null
NOTE=$("$CTX" sql "SELECT technote FROM ctx_capture_day LIMIT 1")
"$CTX" sql "SELECT fsl_technote_save(replace(replace(replace(replace(replace(replace(fsl_technote('$NOTE'), ' k-3', ''), ' k-4', ''), ' k-5', ''), ' k-6', ''), '## tool ', '## user '), '## meta ', '## user '), json_object('id', '$NOTE'))" >/dev/null
"$CTX" sql "SELECT fsl_technote('$NOTE')" | grep -q '^## user 2026-01-02T00:00:03Z$' || fail "an old heading has no turn id"
"$CTX" sql "SELECT fsl_technote_save(fsl_technote('$NOTE') || char(10) || '## user' || char(10) || 'a request copy of an old turn' || char(10), json_object('id', '$NOTE'))" >/dev/null
"$CTX" rebuild >/dev/null
"$CTX" sql "UPDATE ctx_chunk SET heading='user' WHERE heading IN ('tool','meta')" >/dev/null
"$CTX" sql "DELETE FROM ctx_meta WHERE key='speakers'" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE heading='user'")" = 7 ] || fail "the old labels are set up: $("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE heading='user'")"
CLAUDE_CONFIG_DIR="$T/relcfg" "$CTX" scan 2>"$T/rel.err" >/dev/null
grep -q '4 turns in 1 technotes now say tool or meta, not user; 1 request copies removed' "$T/rel.err" || fail "relabel reports: $(cat "$T/rel.err")"
"$CTX" search --all 'request copy' 2>/dev/null | grep -q 'request copy' && fail "a request copy leaves the index"
"$CTX" sql "SELECT fsl_technote('$NOTE')" | grep -q 'a request copy' && fail "a request copy leaves the technote"
[ "$("$CTX" sql "SELECT group_concat(heading, ' ') FROM (SELECT heading FROM ctx_chunk ORDER BY seq)")" = "user user meta meta meta tool assistant" ] || fail "the index follows: $("$CTX" sql "SELECT group_concat(heading, ' ') FROM ctx_chunk")"
"$CTX" sql "SELECT fsl_technote('$NOTE')" | grep -c '^## \(tool\|meta\) ' | grep -qx 4 || fail "the technote is corrected, so it syncs"
"$CTX" rebuild >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE heading='user'")" = 2 ] || fail "a rebuild keeps the correction"
CLAUDE_CONFIG_DIR="$T/relcfg" "$CTX" scan 2>"$T/rel.err" >/dev/null
[ ! -s "$T/rel.err" ] || fail "relabel runs once: $(cat "$T/rel.err")"

# Rules: CLAUDE.md and memory files are imported, ctx remember adds one, and each can
# expire, be replaced or be retired without being erased.
export CTX_DB="$T/memrules.sqlite"
"$CTX" init >/dev/null
RC="$T/rulecfg"
mkdir -p "$RC/projects/-w-rp/memory"
printf 'Never push straight to main.\n' > "$RC/CLAUDE.md"
printf -- '---\nname: notam-mono\noriginSessionId: d00d0001-0000-0000-0000-000000000001\n---\n\nRaw NOTAM text is always monospaced. Token ghp_abcdefghijklmnopqrstuvwxyz0123456789 here.\n' > "$RC/projects/-w-rp/memory/notam-mono.md"
printf -- '- [notam-mono](notam-mono.md) - index line\n' > "$RC/projects/-w-rp/memory/MEMORY.md"
printf '{"uuid":"r-1","timestamp":"2026-11-01T10:00:00Z","cwd":"/w/rp","message":{"role":"user","content":"hello"}}\n' > "$RC/projects/-w-rp/d00d0001-0000-0000-0000-000000000001.jsonl"
"$CTX" archive "$RC/projects/-w-rp/d00d0001-0000-0000-0000-000000000001.jsonl" >/dev/null
CLAUDE_CONFIG_DIR="$RC" "$CTX" rules import | grep -q '^2 rules changed, 2 active' || fail "import CLAUDE.md and a memory file"
"$CTX" rules --project rp > "$T/rules.txt"
grep -q 'rp .*Raw NOTAM' "$T/rules.txt" 2>/dev/null || grep -q 'notam-mono' "$T/rules.txt" || fail "a memory file belongs to the project its transcripts are in: $(cat "$T/rules.txt")"
grep -q '\*  Never push straight to main' "$T/rules.txt" || fail "CLAUDE.md applies to every project: $(cat "$T/rules.txt")"
"$CTX" search --all monospaced | grep -q '^#[0-9]* rp rule' || fail "a rule is searchable"
"$CTX" search --all ghp_abcdefghijklmnop 2>/dev/null | grep -q rule && fail "a secret in a memory file is redacted"
CLAUDE_CONFIG_DIR="$RC" "$CTX" rules import | grep -q '^0 rules changed' || fail "an unchanged file changes nothing"
K1=$("$CTX" remember "Add a changelog entry when we cut a release" --project rp --until 2099-01-01 | cut -d' ' -f1)
K2=$("$CTX" remember "Bump versions by x.x.1 until out of beta" --project rp --until 2020-01-01 | cut -d' ' -f1)
"$CTX" rules --project rp | grep -q "^$K1  rp  Add a changelog" || fail "remember: $("$CTX" rules --project rp)"
"$CTX" rules --project rp | grep -q "x.x.1" && fail "an expired rule is not active"
"$CTX" rules --all --project rp | grep -q "^$K2  rp expired" || fail "an expired rule is kept: $("$CTX" rules --all --project rp)"
"$CTX" search --all beta 2>/dev/null | grep -q rule && fail "search leaves an expired rule out"
"$CTX" search --all --history beta | grep -q rule || fail "--history brings an expired rule back"
K3=$("$CTX" remember "Add a changelog entry and a release note when we cut a release" --project rp | cut -d' ' -f1)
if "$CTX" rules retire "$K1" 2>/dev/null; then fail "a retirement needs a reason"; fi
"$CTX" rules retire "$K1" --reason "release notes too" --by "$K3" | grep -q replaced || fail "replace a rule"
"$CTX" rules --all --project rp | grep -q "^$K1  rp replaced" || fail "a replaced rule is kept and marked"
printf -- '---\nname: notam-mono\noriginSessionId: d00d0001-0000-0000-0000-000000000001\n---\n\nRaw NOTAM text is monospaced, like Jeppesen.\n' > "$RC/projects/-w-rp/memory/notam-mono.md"
CLAUDE_CONFIG_DIR="$RC" "$CTX" rules import | grep -q '^1 rules changed' || fail "an edited file makes a new version"
"$CTX" search --all jeppesen | grep -q rule || fail "the new version is searchable"
N=$("$CTX" sql "SELECT technote FROM ctx_rule WHERE key LIKE '%notam-mono.md'")
[ "$("$CTX" sql "SELECT count(*) FROM fslrepo_me_tagxref x JOIN fslrepo_me_tag t ON t.tagid = x.tagid WHERE t.tagname = 'event-$N'")" = 2 ] || fail "the old version stays in history"
rm "$RC/projects/-w-rp/memory/notam-mono.md"
CLAUDE_CONFIG_DIR="$RC" "$CTX" rules import >/dev/null
"$CTX" rules --all --project rp | grep -q 'notam-mono.md  rp retired' || fail "a removed file retires its rule: $("$CTX" rules --all --project rp)"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind='session' AND id IN (SELECT doc_id FROM ctx_chunk WHERE body LIKE '%changelog%')")" = 0 ] || fail "a rule is not a session"
B=$("$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind='rule'")
"$CTX" rebuild >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind='rule'")" = "$B" ] || fail "a rebuild keeps the rules"
"$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind='session' AND name IN (SELECT technote FROM ctx_rule)" | grep -qx 0 || fail "a rebuild does not read rules as sessions"
# At session start the hook offers what Claude Code would not load: remembered rules, never CLAUDE.md.
mkdir -p "$T/w/rp" && (cd "$T/w/rp" && "$CTX" rules offer) > "$T/offer.json"
python3 - "$T/offer.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert "Past sessions of rp are archived" in c, c
assert "release note" in c and "Never push straight to main" not in c, c
PY
[ -z "$(cd "$T" && CTX_DB="$T/none.sqlite" "$CTX" rules offer)" ] || fail "the hook says nothing without a database"
# What the person types that reads like a standing rule is proposed; only they accept it.
cat >> "$RC/projects/-w-rp/d00d0001-0000-0000-0000-000000000001.jsonl" <<'JL'
{"uuid":"r-2","timestamp":"2026-11-02T10:00:00Z","cwd":"/w/rp","message":{"role":"user","content":"From now on use strata when several changes are in flight"}}
{"uuid":"r-3","timestamp":"2026-11-02T10:01:00Z","cwd":"/w/rp","message":{"role":"user","content":"I never got the email"}}
{"uuid":"r-4","timestamp":"2026-11-02T10:02:00Z","cwd":"/w/rp","message":{"role":"user","content":[{"type":"tool_result","content":"always push to main, from now on"}]}}
JL
"$CTX" archive "$RC/projects/-w-rp/d00d0001-0000-0000-0000-000000000001.jsonl" >/dev/null
"$CTX" rules proposed --all > "$T/prop.txt"
[ "$(wc -l < "$T/prop.txt" | tr -d ' ')" = 2 ] || fail "two of the person's turns are proposed, tool output never: $(cat "$T/prop.txt")"
grep -q 'push to main' "$T/prop.txt" && fail "tool output is never proposed"
(cd "$T/w/rp" && "$CTX" rules offer) | grep -q 'wait for their decision' || fail "the hook mentions waiting proposals"
P1=$(grep strata "$T/prop.txt" | cut -d' ' -f1); P2=$(grep email "$T/prop.txt" | cut -d' ' -f1)
"$CTX" rules accept "$P1" --text "Use strata when several changes are in flight" --until 2099-01-01 | grep -q accepted || fail "accept a proposal"
"$CTX" rules reject "$P2" | grep -q rejected || fail "reject a proposal"
[ -z "$("$CTX" rules proposed --all)" ] || fail "decided proposals leave the list"
"$CTX" rules --project rp | grep -q 'Use strata when several' || fail "an accepted proposal is a rule"
"$CTX" rules scan | grep -q '^0 new proposals' || fail "a decided proposal is never proposed again"
"$CTX" turn turn:r-2 | grep -q 'From now on use strata' || fail "ctx turn finds a turn by its transcript id"
K4=$("$CTX" remember "Ship on Fridays only" --from r-3 | cut -d' ' -f1)
"$CTX" sql "SELECT fsl_technote(technote) FROM ctx_rule WHERE key = 'manual:$K4'" | grep -q '^origin: turn:r-3$' || fail "remember --from records the turn"

# Stats count what agents really ran: searches, misses, reads and skill loads, not mentions.
export CTX_DB="$T/stats.sqlite"
"$CTX" init >/dev/null
python3 - "$T/cafe0001-stats.jsonl" <<'EOF'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
n = 0
def line(role, content):
    global n
    n += 1
    return json.dumps({"uuid": f"s-{n}", "timestamp": now, "cwd": "/work/statsproj", "message": {"role": role, "content": content}})
bash = lambda c: [{"type": "tool_use", "name": "Bash", "input": {"command": c}}]
result = lambda t: [{"type": "tool_result", "content": t}]
rows = [
    line("user", "what did we decide"),
    line("assistant", bash("cd /work && ctx search heron timeout")),
    line("user", result("ctx: no matches")),
    line("assistant", bash("CTX_DB=/x ~/.local/bin/ctx search zebra; ctx turn 12 2 5")),
    line("user", result("#12 statsproj session user 2026-11-10")),
    line("assistant", bash("grep -n 'ctx search' README.md")),
    line("assistant", bash("(cd /w && ctx search yak) || echo \"$(date)\"")),
    line("assistant", bash("for q in a b; do ctx search $q; done")),
    line("assistant", bash("python3 - <<'PY'\nprint('ctx search inside a heredoc')\nPY\nctx turn 4")),
    line("assistant", [{"type": "tool_use", "name": "Skill", "input": {"skill": "ctx"}}]),
]
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
EOF
"$CTX" archive "$T/cafe0001-stats.jsonl" >/dev/null
"$CTX" stats > "$T/stats.txt" || fail "stats runs"
grep -qE '^statsproj +1 +4 +1 +2 +1$' "$T/stats.txt" || fail "stats by project: $(cat "$T/stats.txt")"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} +1 +4 +1 +2 +1$' "$T/stats.txt" || fail "stats by week: $(cat "$T/stats.txt")"
if "$CTX" stats --weeks 0 2>/dev/null; then fail "weeks must be positive"; fi
export CTX_DB="$T/arc.sqlite"

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

# The deadline reaches the runs a scan starts. ctx re-runs its own argv[0], so a
# stand-in reports the time its own alarm has left. No timing is involved.
python3 - "$CTX" "$T" <<'EOF'
import os, signal, subprocess, sys
ctx, T = sys.argv[1:3]
os.makedirs(f"{T}/deadline/p")
with open(f"{T}/deadline/p/d.jsonl", "w") as f:
    f.write("{}\n")
fake = f"{T}/stand-in"
with open(fake, "w") as f:
    f.write(f"#!{sys.executable}\nimport signal\nopen({T + '/stand-in.left'!r}, 'w').write(str(signal.alarm(0)))\n")
os.chmod(fake, 0o755)
p = subprocess.run([fake, "scan", f"{T}/deadline"], executable=ctx, stdout=subprocess.DEVNULL,
                   preexec_fn=lambda: signal.alarm(300))
assert p.returncode == 0, p.returncode
left = int(open(f"{T}/stand-in.left").read())
assert 0 < left <= 300, f"child inherited the deadline: {left}"
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
G="$T/cc002222-glued.jsonl"
python3 - "$G" <<'EOF'
import json, sys
glued = "AS" + "IA" + "ABCDEFGHIJKLMNOP" + "np" + "m_" + "x" * 36
open(sys.argv[1], "w").write(json.dumps({"uuid": "gl-1", "timestamp": "2026-06-03T01:00:00Z", "cwd": "/w/r", "message": {"role": "user", "content": "keys " + glued + " end"}}) + "\n")
EOF
"$CTX" archive "$G" >/dev/null
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE turn='gl-1' AND body LIKE '%xxxxxxxxxxxx%'")" = 0 ] || fail "a token glued to another is still redacted"
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
"$CTX" sql "SELECT body FROM ctx_chunk WHERE turn='dj-1'" | grep -q '"computed":"\[REDACTED\]"' || fail "the redaction marker is written"

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
"$CTX" project add my-proj | grep -q 'repo:myproj' || fail "project add maps the name"
mkdir -p "$T/other/two"; (cd "$T/other" && "$CTX" project add my-proj-two --root "$T/other/two" >/dev/null) || fail "a name extending another one works"
if "$CTX" project add my-proj 2>/dev/null; then fail "a project is added once"; fi
"$CTX" sql "SELECT fsl_export('repo:me', '$T/export.fossil')" >/dev/null
(cd "$T/other" && "$CTX" project add imported --import "$T/export.fossil" >/dev/null) || fail "project import"
[ "$("$CTX" project list | wc -l | tr -d ' ')" = 3 ] || fail "project list"
if "$CTX" project add repo --root "$T/other" 2>/dev/null; then fail "reserved repository names"; fi

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
python3 -c "import hashlib,json,sys; p=sys.argv[1]; json.dump(dict(origin='x', sha3=hashlib.sha3_256(open(p,'rb').read()).hexdigest()), open(p+'.origin.json','w'))" "$T/ix/co/sources/sub/design.md"
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
out=$(cd "$T/ix/root" && "$CTX" index); echo "$out" | grep -q '^1 sources, 2 wiki pages, 3 changed, 3 citations, 2 failing' || fail "index counts: $out"
"$CTX" sql "SELECT count(*) FROM ctx_doc WHERE name LIKE '%origin.json'" | grep -q '^0' || fail "origin files are not indexed as sources"
q() { "$CTX" sql "$1"; }
[ "$(q "SELECT status FROM ctx_citation WHERE ref='a'")" = ok ] || fail "a quote is found across a line break"
[ "$(q "SELECT status FROM ctx_citation WHERE ref='b'")" = quote-missing ] || fail "a missing quote is caught"
[ "$(q "SELECT status FROM ctx_citation WHERE ref='c'")" = no-source ] || fail "a citation to a session not in this repository fails"
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
(cd "$T/ix/root" && "$CTX" project add kb3 --root "$T/ix" --clone "$T/ix/upstream.fossil" >/dev/null) || fail "clone from a repository"
"$CTX" project pull kb3 | grep -q 'received' || fail "a clone remembers where to pull from"
if "$CTX" project pull kb2 2>/dev/null; then fail "pull needs a source"; fi

# The write gate: a page saves only if its whole provenance chain holds.
export CTX_DB="$T/wiki.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/wk/co" "$T/wk/root"
cd "$T/wk/root"
"$CTX" project add kb >/dev/null
w_repo() { "$CTX" sql "SELECT fsl_open('repo:kb', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
w_co() { "$CTX" sql "SELECT fsl_open('$T/wk/co', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
w_repo "fsl_checkout('$T/wk/co')" >/dev/null
mkdir -p "$T/wk/co/sources"
printf 'The cache TTL is 30 seconds.\nEvictions run nightly.\n' > "$T/wk/co/sources/a.md"
printf 'The cache TTL is 30 seconds.\n' > "$T/wk/co/sources/noorigin.md"
"$CTX" project add tmpsrc --root "$T/wk/co" >/dev/null
(cd "$T/wk/co" && "$CTX" source add sources/a.md --origin https://example.test/a --class evergreen --as a.md >/dev/null)
"$CTX" sql "DELETE FROM ctx_project WHERE project='tmpsrc'" >/dev/null
w_co "fsl_add('sources')" >/dev/null
w_co "fsl_commit('{\"comment\":\"sources\"}')" >/dev/null
CI=$(w_repo "fsl_resolve('trunk')")
NOTE=$(w_repo "fsl_technote_save('We chose a thirty second TTL.', '{\"comment\":\"note\"}')")
TK=$(w_repo "fsl_ticket_new('{\"title\":\"Evictions are nightly\",\"status\":\"Open\"}')")
PRIV=$("$CTX" sql "SELECT fsl_technote_save('private words here')" | tail -1)
page() { python3 - "$T/wk/p.md" "$CI" "$NOTE" "$TK" "$PRIV" "$1" <<'EOF'
import sys
out, ci, note, tk, priv, case = sys.argv[1:7]
good = f"""# Cache

Entries live thirty seconds.[^a] Evictions vs. e.g. expiry are nightly.[^b]

- Items expire.[^a]

See [Self](/wiki?name=Cache).

```
Code is not a claim here at all.
```

[^a]: "The cache TTL is 30 seconds." [a](/file?name=sources/a.md&ci={ci}&txt=1&ln=1)
[^b]: "Evictions run nightly." [a](/file?name=sources/a.md&ci={ci})
"""
extra = {
 "good": "",
 "uncited": "This paragraph states a claim with nothing behind it.\n",
 "quote": f'Bad claim here today.[^x]\n\n[^x]: "Never written anywhere." [a](/file?name=sources/a.md&ci={ci})\n',
 "short": f'Short pin claim here.[^x]\n\n[^x]: "The cache TTL is 30 seconds." [a](/file?name=sources/a.md&ci={ci[:12]})\n',
 "wiki": 'Wiki as evidence here.[^x]\n\n[^x]: "Entries live." [p](/wiki?name=Cache)\n',
 "dead": "Go to [Gone](/wiki?name=Nowhere).\n",
 "undefined": "A marker without a note.[^zz]\n",
 "synth1": "Synthesis: one source alone.[^a]\n",
 "synth2": "Synthesis: both sources together.[^a][^b]\n",
 "origin": f'No origin claim here.[^x]\n\n[^x]: "The cache TTL is 30 seconds." [n](/file?name=sources/noorigin.md&ci={ci})\n',
 "session": f'A session said this.[^s] And a ticket said that.[^t]\n\n[^s]: "chose a thirty second" [n](/technote/{note})\n[^t]: "Evictions are nightly" [t](/tktview/{tk})\n',
 "private": f'From a private session.[^p]\n\n[^p]: "private words" [n](/technote/{priv})\n',
 "oversize": "Long claim.[^a] " + "x" * 33000 + "\n",
}[case]
open(out, "w").write(good.replace("[^a]: ", extra + "\n[^a]: ", 1) if extra else good)
EOF
}
refused() { page "$1"; if "$CTX" wiki save Cache "$T/wk/p.md" --model m > "$T/wk/o.txt" 2>&1; then fail "gate let through: $1"; fi; grep -q "$2" "$T/wk/o.txt" || fail "gate reason for $1: $(cat "$T/wk/o.txt")"; }
[ "$(w_repo "fsl_wiki('Cache') IS NULL")" = 1 ] || fail "no page yet"
page good
if "$CTX" wiki save Cache "$T/wk/p.md" 2>/dev/null; then fail "--model is required"; fi
"$CTX" wiki save Cache "$T/wk/p.md" --model test-model --ticket abc --session sess1 | grep -q '^saved Cache' || fail "a good page saves"
refused uncited 'no citation: This paragraph'
refused quote 'quote-missing'
refused short 'full check-in hash'
refused wiki 'must cite a source'
refused dead 'does not exist: Nowhere'
printf '# Other\n\nBack to [Cache](/wiki?name=Cache).\n' > "$T/wk/op.md"; "$CTX" wiki save "Other Page" "$T/wk/op.md" --model m >/dev/null || fail "a second page saves"
printf '# Spaced\n\nSee [Other](/wiki?name=Other Page).\n' > "$T/wk/sp.md"; "$CTX" wiki save Spaced "$T/wk/sp.md" --model m >/dev/null || fail "a raw space in a link is accepted"
w_repo "fsl_wiki('Spaced')" | grep -q '(/wiki?name=Other+Page)' || fail "a raw space in a link is encoded"
refused undefined 'zz\] is not a quoted'
refused synth1 'synthesis must cite'
refused origin 'no-origin'
refused private 'no-source'
refused oversize 'over 32 KB'
page synth2; "$CTX" wiki save Cache "$T/wk/p.md" --model m >/dev/null || fail "synthesis citing both saves"
page session; "$CTX" wiki save Cache "$T/wk/p.md" --model m >/dev/null || fail "session and ticket citations verify"
TEXT=$(w_repo "fsl_wiki('Cache')")
page good; "$CTX" wiki save Cache "$T/wk/p.md" --model test-model --ticket abc --session sess1 | grep -q 'removed claim: "chose a thirty' || fail "dropped claims are reported"
w_repo "fsl_wiki('Cache')" > "$T/wk/saved.md"
grep -q '^## Provenance' "$T/wk/saved.md" && grep -q 'Compiled by: test-model' "$T/wk/saved.md" && grep -q 'Ticket: abc' "$T/wk/saved.md" || fail "provenance block"
grep -q "^- \[sources/a.md @ ${CI%${CI#????????????}}\](/info/$CI)" "$T/wk/saved.md" || fail "sources section links the check-in"
[ "$(grep -c '^## Provenance' "$T/wk/saved.md")" = 1 ] || fail "provenance is replaced, not repeated"
if grep -q sess1 "$T/wk/saved.md"; then fail "a shared page must not name a private session"; fi
[ "$("$CTX" sql "SELECT session FROM ctx_wiki_log ORDER BY id DESC LIMIT 1")" = sess1 ] || fail "session is in the private log"
UUID=$("$CTX" sql "SELECT b.uuid FROM fslrepo_kb_blob b JOIN fslrepo_kb_tagxref x ON x.rid=b.rid JOIN fslrepo_kb_tag t ON t.tagid=x.tagid WHERE t.tagname='wiki-Cache' ORDER BY x.mtime DESC, b.rid DESC LIMIT 1")
w_repo "cast(fsl_content('$UUID') as text)" | grep -q '^N text/x-markdown' || fail "saved as Markdown"
"$CTX" wiki why Cache > "$T/wk/why.txt"
grep -q '^\[^a\] Entries live thirty seconds' "$T/wk/why.txt" || fail "why shows the claim: $(head -3 "$T/wk/why.txt")"
grep -q '^\[^b\] Evictions vs. e.g. expiry are nightly.$' "$T/wk/why.txt" || fail "why keeps a sentence whole across abbreviations: $(grep '^\[^b' "$T/wk/why.txt")"
grep -q 'quote: "The cache TTL is 30 seconds."' "$T/wk/why.txt" || fail "why shows the quote"
grep -q 'origin: https://example.test/a, retrieved' "$T/wk/why.txt" || fail "why reaches the origin"
"$CTX" source uses a.md | grep -q '^2 claims depend on sources/a.md' || fail "source uses counts claims"
"$CTX" wiki check > "$T/wk/c.txt" || fail "check passes: $(cat "$T/wk/c.txt")"
grep -q '^0 problems' "$T/wk/c.txt" || fail "check is clean"
printf 'Replaced entirely.\n' > "$T/wk/co/sources/a.md"
w_co "fsl_commit('{\"comment\":\"change\"}')" >/dev/null
if "$CTX" wiki check > "$T/wk/c2.txt"; then fail "a stale page fails the check"; fi
grep -q 'Cache: stale, source changed: sources/a.md' "$T/wk/c2.txt" || fail "stale is named"
"$CTX" source uses a.md | grep -q 'older version' || fail "uses shows an older pin"
cd - >/dev/null

# Retirement: nothing is erased, retired material leaves retrieval, and claims follow their sources.
export CTX_DB="$T/retire.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/rt/co" "$T/rt/root"
cd "$T/rt/root"
"$CTX" project add kb >/dev/null
r_repo() { "$CTX" sql "SELECT fsl_open('repo:kb', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
r_co() { "$CTX" sql "SELECT fsl_open('$T/rt/co', 'tester'), fsl_use('repo:kb'), $1" | cut -f3-; }
r_commit() { r_co "fsl_add('sources')" >/dev/null 2>&1; r_co "fsl_commit('{\"comment\":\"$1\"}')" >/dev/null; }
r_repo "fsl_checkout('$T/rt/co')" >/dev/null
mkdir -p "$T/rt/co/sources"
"$CTX" project add tmpsrc --root "$T/rt/co" >/dev/null
printf 'The zebra limit is five.\nThe heron timeout is ten.\n' > "$T/rt/old.md"
printf 'The zebra limit is five.\nThe heron timeout is forty.\n' > "$T/rt/new.md"
printf 'The albatross rule is firm.\n' > "$T/rt/bad.md"
(cd "$T/rt/co" && "$CTX" source add "$T/rt/old.md" --origin u1 --class versioned --valid-from 2026-01-01 >/dev/null; "$CTX" source add "$T/rt/bad.md" --origin u2 --class evergreen --valid-from 2026-01-01 >/dev/null)
r_commit one
CI=$(r_repo "fsl_resolve('trunk')")
python3 - "$T/rt/p.md" "$CI" <<'EOF'
import sys
out, ci = sys.argv[1:3]
open(out, "w").write(f"""# Limits

The limit is five.[^a] The timeout is ten.[^b] The rule is firm.[^c]

[^a]: "The zebra limit is five." [o](/file?name=sources/old.md&ci={ci})
[^b]: "The heron timeout is ten." [o](/file?name=sources/old.md&ci={ci})
[^c]: "The albatross rule is firm." [b](/file?name=sources/bad.md&ci={ci})
""")
EOF
"$CTX" index >/dev/null
"$CTX" wiki save Limits "$T/rt/p.md" --model m >/dev/null || fail "first page saves"
(cd "$T/rt/co" && "$CTX" source add "$T/rt/new.md" --origin u3 --class versioned --valid-from 2026-06-01 >/dev/null)
ev() { (cd "$T/rt/co" && "$CTX" source supersede "$@"); }
if ev old.md --relation replaces --reason r 2>/dev/null; then fail "replaces needs a successor"; fi
if ev old.md --relation replaces --by new.md 2>/dev/null; then fail "a reason is required"; fi
if ev old.md --relation nonsense --by new.md --reason r 2>/dev/null; then fail "relation is checked"; fi
if ev old.md --relation retracts --by new.md --reason r 2>/dev/null; then fail "a retraction has no successor"; fi
if ev old.md --relation replaces --by nosuch.md --reason r 2>/dev/null; then fail "successor needs an origin"; fi
if ev old.md --relation replaces --by old.md --reason r 2>/dev/null; then fail "no self supersession"; fi
ev old.md --relation replaces --by new.md --reason "heron timeout raised" >/dev/null || fail "supersede"
ev bad.md --relation retracts --reason "was wrong" >/dev/null || fail "retract"
if ev old.md --relation replaces --by new.md --reason again 2>/dev/null; then fail "superseded once"; fi
if ev new.md --relation replaces --by old.md --reason cycle 2>/dev/null; then fail "a successor must be current"; fi
(cd "$T/rt/co" && "$CTX" source check) | grep -q ' 0 problems' || fail "the events file is not a source"
[ "$(wc -l < "$T/rt/co/sources/SUPERSEDED.jsonl" | tr -d ' ')" = 2 ] || fail "events are appended"
r_commit two
"$CTX" index >/dev/null
q() { "$CTX" sql "$1"; }
[ "$(q "SELECT status FROM ctx_doc WHERE name='sources/old.md'")" = superseded ] || fail "old is superseded"
[ "$(q "SELECT status FROM ctx_doc WHERE name='sources/bad.md'")" = retracted ] || fail "bad is retracted"
[ "$("$CTX" search zebra | grep -c '^#[0-9]* kb source')" = 1 ] || fail "only the current source is served"
"$CTX" search albatross 2>/dev/null | grep -q '^#[0-9]* kb source' && fail "a retracted source is not served"
"$CTX" search --history albatross | grep -q '^#[0-9]* kb source' || fail "--history brings it back"
if "$CTX" wiki check > "$T/rt/c.txt"; then fail "check sees superseded citations"; fi
grep -q 'cites a superseded source' "$T/rt/c.txt" && grep -q 'cites a retracted source' "$T/rt/c.txt" || fail "check names them"
page2() { sed 's/old.md/old.md/' "$T/rt/p.md" > "$T/rt/p2.md"; }
page2; if "$CTX" wiki save Limits "$T/rt/p2.md" --model m > "$T/rt/g.txt"; then fail "the gate refuses a superseded source"; fi
grep -q 'cites a superseded source' "$T/rt/g.txt" || fail "gate names supersession"
"$CTX" wiki repin > "$T/rt/r.txt"
grep -q '^1 re-pinned, 2 tickets opened' "$T/rt/r.txt" || fail "repin: $(cat "$T/rt/r.txt")"
r_repo "fsl_wiki('Limits')" > "$T/rt/s.md"
grep -q 'name=sources/new.md' "$T/rt/s.md" || fail "a surviving quote moves to the successor"
grep -q '\[^b\]: .*name=sources/old.md' "$T/rt/s.md" || fail "a lost quote keeps its old pin"
[ "$("$CTX" ticket ready --all | grep -c 'Wiki: re-source')" = 2 ] || fail "lost quotes become tickets"
"$CTX" wiki repin | grep -q '^0 re-pinned, 0 tickets' || fail "repin is idempotent"
[ "$("$CTX" ticket ready --all | grep -c 'Wiki: re-source')" = 2 ] || fail "tickets are not repeated"
# as-of answers from what was known then.
"$CTX" sql "UPDATE ctx_source_meta SET added_at='2026-02-01'" >/dev/null
"$CTX" sql "UPDATE ctx_supersession SET at='2026-07-01'" >/dev/null
"$CTX" search --as-of 2026-03-01 heron | grep -q '^#[0-9]* kb source' || fail "as-of sees the old source"
[ "$("$CTX" search --as-of 2026-03-01 heron | grep -c '^#')" = 1 ] || fail "as-of excludes what was not yet valid"
[ "$("$CTX" search --as-of 2026-08-01 heron | grep -c '^#')" = 1 ] || fail "as-of respects a later supersession"
"$CTX" sql "UPDATE ctx_source_meta SET valid_from=NULL WHERE doc_id=(SELECT id FROM ctx_doc WHERE name='sources/new.md')" >/dev/null
[ "$("$CTX" search --as-of 2026-08-01 heron | grep -c '^#')" = 1 ] || fail "as-of serves a source with no valid-from date"
# A retired page keeps its history, leaves retrieval, and can come back.
if "$CTX" wiki retire Limits 2>/dev/null; then fail "retirement needs a reason"; fi
"$CTX" wiki retire Limits --reason "no longer relevant" | grep -q 'retired' || fail "retire"
r_repo "fsl_wiki('Limits')" | head -1 | grep -q '^> \*\*Retired' || fail "the page carries a banner"
[ "$(q "SELECT status FROM ctx_doc WHERE kind='wiki' AND name='Limits'")" = retired ] || fail "retired status"
"$CTX" search limit 2>/dev/null | grep -q '^#[0-9]* kb wiki' && fail "a retired page is not served"
"$CTX" search --history limit | grep -q '^#[0-9]* kb wiki' || fail "--history finds a retired page"
"$CTX" index >/dev/null
[ "$(q "SELECT status FROM ctx_doc WHERE kind='wiki' AND name='Limits'")" = retired ] || fail "retirement survives a rebuild"
[ "$(q "SELECT count(*) FROM fslrepo_kb_event WHERE type='w'")" -ge 2 ] || fail "history is kept"
"$CTX" wiki restore Limits | grep -q 'restored' || fail "restore"
if r_repo "fsl_wiki('Limits')" | head -1 | grep -q 'Retired'; then fail "restore removes the banner"; fi
# The review queue orders stale knowledge by what depends on it.
"$CTX" index >/dev/null
"$CTX" wiki queue > "$T/rt/q.txt"
grep -Eq '^[0-9.]+ sources/(bad|old).md' "$T/rt/q.txt" || fail "queue lists stale sources: $(cat "$T/rt/q.txt")"
grep -q 'sources/new.md' "$T/rt/q.txt" && fail "a current source is not queued"
# Generated pages are computed, change only when the facts do, and are not knowledge.
"$CTX" wiki publish | grep -q ' 2 generated pages updated' || fail "publish writes both pages"
"$CTX" wiki publish | grep -q ' 0 generated pages updated' || fail "publish is stable"
r_repo "fsl_wiki('Wiki Index')" | grep -q '^- \[Limits\](/wiki?name=Limits): 3 claims' || fail "index lists the page"
r_repo "fsl_wiki('Wiki Health')" | grep -q 'sources/bad.md' || fail "health lists the queue"
[ "$(q "SELECT count(*) FROM ctx_doc WHERE kind='wiki' AND name LIKE 'Wiki %'")" = 0 ] || fail "generated pages are not indexed"
if "$CTX" wiki save "Wiki Index" "$T/rt/p.md" --model m 2>/dev/null; then fail "generated pages cannot be saved by hand"; fi
# Automatic retirement touches only what nothing needs.
printf '# Dead\n\nOld claim.[^x]\n\n[^x]: "The albatross rule is firm." [b](/file?name=sources/bad.md&ci=%s)\n' "$CI" > "$T/rt/dead.md"
python3 - "$CTX" "$T/rt/dead.md" <<'EOF'
import subprocess, sys
ctx, p = sys.argv[1:3]
t = open(p).read().replace("'", "''")
for name in ("Dead Page", "Kept Page"):
    body = t if name == "Dead Page" else t + "\nSee [Dead](/wiki?name=Dead+Page).\n"
    subprocess.run([ctx, "sql", f"SELECT fsl_open('repo:kb','t'), fsl_use('repo:kb'), fsl_wiki_save('{name}', '{body}', 'text/x-markdown')"], check=True, capture_output=True)
EOF
"$CTX" index >/dev/null
"$CTX" wiki retire --auto > "$T/rt/a.txt"
grep -q 'needs a person: Dead Page' "$T/rt/a.txt" || fail "linked page needs a person: $(cat "$T/rt/a.txt")"
grep -q 'would retire: Kept Page' "$T/rt/a.txt" || fail "unused page is eligible: $(cat "$T/rt/a.txt")"
[ "$(q "SELECT count(*) FROM ctx_doc WHERE kind='wiki' AND status='retired'")" = 0 ] || fail "a dry run changes nothing"
"$CTX" wiki retire --auto --apply > "$T/rt/a2.txt"
[ "$(q "SELECT status FROM ctx_doc WHERE name='Kept Page'")" = retired ] || fail "auto retires the eligible page"
[ "$(q "SELECT coalesce(status,'current') FROM ctx_doc WHERE name='Dead Page'")" = current ] || fail "a linked page stays"
"$CTX" ticket ready --all | grep -q 'decide whether to retire Dead Page' || fail "a person is asked"
cd - >/dev/null

# Sync: a second machine starts from the private repository, sees the first one's
# sessions, and tickets do not get claimed twice.
export CTX_DB="$T/m1.sqlite"
"$CTX" init >/dev/null
printf '{"uuid":"sy-1","timestamp":"2026-08-01T10:00:00Z","cwd":"/w/syncproj","message":{"role":"user","content":"the quokka migration plan"}}\n' > "$T/ab12cd34-sync.jsonl"
"$CTX" archive "$T/ab12cd34-sync.jsonl" >/dev/null
"$CTX" remote me "$T/hubdir/sub/hub.fossil" | grep -q 'copied repo:me' || fail "a remote that does not exist yet is created from this machine"
[ "$(ls -l "$T/hubdir/sub/hub.fossil" | cut -c1-10)" = "-rw-------" ] || fail "the copy of the private archive is private"
"$CTX" remote me "$T/hub.fossil" >/dev/null
[ -s "$T/hub.fossil" ] || fail "the copy is written"
cp "$T/hub.fossil" "$T/hub.before"
"$CTX" remote me "$T/hub.fossil" | grep -q 'copied' && fail "an existing remote is never overwritten"
cmp -s "$T/hub.fossil" "$T/hub.before" || fail "an existing remote is left as it is"
TK=$("$CTX" ticket new "Shared work" --project syncproj)
"$CTX" remember "Quokka migrations run on Tuesdays" --project syncproj >/dev/null
"$CTX" sync >/dev/null || fail "first machine syncs"
export CTX_DB="$T/m2.sqlite"
"$CTX" init --clone "$T/hub.fossil" | grep -q '1 sessions from other machines indexed' || fail "a clone indexes the other machine's sessions"
"$CTX" search --all quokka | grep -q 'quokka' || fail "the other machine's session is searchable"
"$CTX" rules --project syncproj | grep -q 'Quokka migrations' || fail "a rule syncs to another machine"
[ "$("$CTX" sql "SELECT remote FROM ctx_repo WHERE name='me'")" = "$T/hub.fossil" ] || fail "a clone remembers its remote"
if "$CTX" init --clone "$T/hub.fossil" 2>/dev/null; then fail "a private repository is cloned once"; fi
export CTX_DB="$T/m1.sqlite"
printf '{"uuid":"sy-2","timestamp":"2026-08-02T10:00:00Z","cwd":"/w/syncproj","message":{"role":"user","content":"the wombat follow-up"}}\n' >> "$T/ab12cd34-sync.jsonl"
printf '{"uuid":"sy-3","cwd":"/w/syncproj","message":{"role":"assistant","content":"an undated platypus reply"}}\n' >> "$T/ab12cd34-sync.jsonl"
printf '{"uuid":"sy-4","timestamp":"2026-08-02T11:00:00Z","cwd":"/w/syncproj","message":{"role":"user","content":"binary \\u0000 output"}}\n{"uuid":"sy-5","timestamp":"2026-08-02T12:00:00Z","cwd":"/w/syncproj","message":{"role":"assistant","content":"the echidna after a nul"}}\n' >> "$T/ab12cd34-sync.jsonl"
"$CTX" archive "$T/ab12cd34-sync.jsonl" >/dev/null
"$CTX" sync >/dev/null || fail "push"
NOTES=$("$CTX" sql "SELECT count(*) FROM ctx_capture_day")
export CTX_DB="$T/m2.sqlite"
"$CTX" sync | grep -q 'sessions from other machines indexed' || fail "a pull indexes new sessions"
"$CTX" search --all wombat | grep -q 'wombat' || fail "a new turn arrives"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE body LIKE '%platypus%' AND body NOT LIKE '%wombat%'")" = 1 ] || fail "a turn with no timestamp stays its own turn"
"$CTX" search --all echidna | grep -q echidna || fail "text after a NUL byte arrives"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind='session'")" = "$NOTES" ] || fail "one session per technote, not duplicated"
"$CTX" sync | grep -q 'sessions from other machines' && fail "an unchanged note is not indexed again"
"$CTX" ticket claim "$TK" --as machine2 >/dev/null || fail "machine 2 claims"
export CTX_DB="$T/m1.sqlite"
if "$CTX" ticket claim "$TK" --as machine1 2>"$T/claim.err" >/dev/null; then fail "a claim made on another machine is seen first"; fi
grep -q 'Claimed by machine2' "$T/claim.err" || fail "the other machine's claim is named: $(cat "$T/claim.err")"
"$CTX" sync >/dev/null
[ "$("$CTX" ticket show "$TK" | sed -n 's/^assignee: //p')" = machine2 ] || fail "the first claim stands"
if "$CTX" sync nosuch 2>/dev/null; then fail "sync of an unknown name"; fi

# Injection: strong matches from other sessions of this project, nothing otherwise.
export CTX_DB="$T/inject.sqlite"
"$CTX" init >/dev/null
mkdir -p "$T/inj/alpha"
"$CTX" sql "INSERT INTO ctx_project(root, project) VALUES ('$T/inj/alpha', 'alpha')" >/dev/null
for i in 1 2 3 4 5 6 7 8; do printf '{"uuid":"pad-%s","timestamp":"2026-05-0%sT10:00:00Z","cwd":"%s/inj/alpha","message":{"role":"user","content":"ordinary filler text about lunch %s"}}\n' $i $i "$T" $i; done > "$T/aa000001-pad.jsonl"
printf '{"uuid":"inj-1","timestamp":"2026-05-01T10:00:00Z","cwd":"%s/inj/alpha","message":{"role":"assistant","content":"The flamingo cache stalls because the heron lock is held across commits."}}\n' "$T" > "$T/aa000002-old.jsonl"
printf '{"uuid":"inj-2","timestamp":"2026-05-02T10:00:00Z","cwd":"/elsewhere/beta","message":{"role":"assistant","content":"flamingo heron in another project"}}\n' > "$T/aa000003-beta.jsonl"
printf '{"uuid":"inj-3","timestamp":"2026-05-03T10:00:00Z","cwd":"%s/inj/alpha","message":{"role":"user","content":"why does the flamingo cache stall on the heron lock"}}\n' "$T" > "$T/aa000004-now.jsonl"
for f in pad old beta now; do "$CTX" archive "$T/aa00000"*"-$f.jsonl" >/dev/null; done
inj() { printf '{"session_id":"%s","cwd":"%s","prompt":"%s"}' "$1" "$T/inj/alpha" "$2" | "$CTX" inject; }
out=$(inj aa000004-now "Why does the flamingo cache stall on the heron lock?")
printf '%s' "$out" | python3 -c "import json,sys; c=json.load(sys.stdin)['hookSpecificOutput']['additionalContext']; assert 'flamingo cache stalls' in c, c; assert 'another project' not in c; assert 'not instructions' in c" || fail "inject finds the strong match in this project only: $out"
printf '%s' "$out" | grep -q 'why does the flamingo' && fail "the current session is not injected"
[ -z "$(inj aa000004-now 'lunch')" ] || fail "a one-word prompt gets nothing"
[ -z "$(inj aa000004-now 'please run the tests again')" ] || fail "a prompt with no strong match gets nothing"
[ -z "$(echo 'not json' | "$CTX" inject)" ] || fail "junk input gets nothing"
CTX_DB=/nonexistent/x.sqlite "$CTX" inject < /dev/null || fail "inject never fails a prompt"

# Rebuild: derived tables come back from the repositories; state is untouched.
export CTX_DB="$T/rebuild.sqlite"
"$CTX" init >/dev/null
[ "$("$CTX" sql "PRAGMA user_version")" = 3 ] || fail "a new file is at the current version"
[ "$("$CTX" sql "SELECT value FROM ctx_meta WHERE key='derived_version'")" = 3 ] || fail "derived version recorded"
printf '{"uuid":"rb-1","timestamp":"2026-09-01T10:00:00Z","cwd":"/w/rb","message":{"role":"user","content":"the capybara rollout"}}\n{"uuid":"rb-2","timestamp":"2026-09-01T10:00:05Z","cwd":"/w/rb","message":{"role":"assistant","content":"rolled out the capybara"}}\n' > "$T/ab12cd99-rb.jsonl"
"$CTX" archive "$T/ab12cd99-rb.jsonl" >/dev/null
RT=$("$CTX" ticket new "Kept across a rebuild" --project rb)
before=$("$CTX" search --all capybara | grep -c '^#')
"$CTX" rebuild | tail -1 | grep -q '^2 turns' || fail "rebuild reindexes the sessions"
[ "$("$CTX" search --all capybara | grep -c '^#')" = "$before" ] || fail "search finds the same turns after a rebuild"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_chunk WHERE turn IN ('rb-1','rb-2')")" = 2 ] || fail "turn ids survive a rebuild"
"$CTX" archive "$T/ab12cd99-rb.jsonl" | grep -q '^0 turns' || fail "nothing is stored twice after a rebuild"
"$CTX" ticket show "$RT" | grep -q 'Kept across' || fail "tickets are state"
[ "$("$CTX" sql "SELECT count(*) FROM ctx_capture")" = 1 ] || fail "capture state is kept"
# An index from an older version is rebuilt on open, once.
"$CTX" sql "UPDATE ctx_meta SET value='1' WHERE key='derived_version'" >/dev/null
"$CTX" search --all capybara 2>"$T/rb.err" >/dev/null
grep -q 'rebuilding it once' "$T/rb.err" || fail "an old index is rebuilt on open"
[ "$("$CTX" sql "SELECT value FROM ctx_meta WHERE key='derived_version'")" = 3 ] || fail "then it is current"
"$CTX" search --all capybara 2>"$T/rb2.err" >/dev/null; [ -s "$T/rb2.err" ] && fail "and is not rebuilt again"
# A file from before versioning upgrades in place, without a rebuild.
"$CTX" sql "DROP TABLE ctx_meta" >/dev/null; "$CTX" sql "PRAGMA user_version = 1" >/dev/null
"$CTX" search --all capybara 2>"$T/rb3.err" | grep -q capybara || fail "an unversioned file still works"
[ -s "$T/rb3.err" ] && fail "an unversioned file is upgraded without a rebuild"
[ "$("$CTX" sql "PRAGMA user_version")" = 3 ] || fail "and is marked current"

# The skill eval harness works end to end with a stand-in for the model.
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/../eval/test_eval.py" "$CTX" || fail "eval harness"

# A missing file is an error.
if "$CTX" extract "$T/none.jsonl" 2>/dev/null; then fail "missing file"; fi

echo "all tests passed"
