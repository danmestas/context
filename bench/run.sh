#!/usr/bin/env bash
# Build the bench database from the pinned corpora, run every method, print the report.
# Needs Homebrew's sqlite3 (or SQLITE3 set to any build that allows extensions) and ripgrep.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
corpora=${CTX_CORPORA:-$HOME/projects/ctx-corpora}
db=${CTX_BENCH_DB:-$corpora/bench.sqlite}
sqlite=${SQLITE3:-/opt/homebrew/opt/sqlite/bin/sqlite3}

case "$sqlite" in
  /usr/bin/sqlite3) echo "Apple's sqlite3 cannot load extensions; use Homebrew's." >&2; exit 1 ;;
esac
[ -x "$sqlite" ] || { echo "sqlite3 not found at $sqlite" >&2; exit 1; }
command -v rg >/dev/null || { echo "ripgrep is required" >&2; exit 1; }
if "$sqlite" :memory: 'PRAGMA compile_options' | grep -q OMIT_LOAD_EXTENSION; then
  echo "$sqlite was built without extension loading" >&2; exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

rm -f "$db" "$db-wal" "$db-shm"
"$sqlite" "$db" < "$here/schema.sql"

"$sqlite" -separator ' ' "$db" 'SELECT name, labels FROM corpus' > "$work/corpora"
while read -r name labels; do
  echo "loading $name" >&2
  "$sqlite" \
    -cmd ".parameter set @corpus '$name'" \
    -cmd ".parameter set @root '$corpora/$name'" \
    -cmd ".parameter set @labels '$corpora/labels/$labels'" \
    "$db" < "$here/load.sql"
done < "$work/corpora"

"$sqlite" "$db" < "$here/terms.sql"

echo "building full-text indexes" >&2
tokenize="tokenize=\"porter unicode61 tokenchars '_'\""
"$sqlite" "$db" "CREATE VIRTUAL TABLE fts_all USING fts5(path, body, content='doc', content_rowid='id', $tokenize);
                 INSERT INTO fts_all(rowid, path, body) SELECT id, path, body FROM doc;"
n=0
while read -r name _; do
  n=$((n + 1))
  "$sqlite" "$db" "CREATE VIRTUAL TABLE fts_$n USING fts5(path, body, content='doc', content_rowid='id', $tokenize);
                   INSERT INTO fts_$n(rowid, path, body) SELECT id, path, body FROM doc WHERE corpus = '$name';"
done < "$work/corpora"

echo "running grep" >&2
while read -r name _; do
  cd "$corpora/$name"
  "$sqlite" "$db" "SELECT DISTINCT term FROM grep_term WHERE corpus = '$name'" |
    while read -r term; do
      { rg -c -i -w -F --no-ignore --hidden --null --no-messages -g '!.git' -- "$term" . || true; } |
        tr '\000' '\037' |
        awk -v c="$name" -v t="$term" 'BEGIN { FS = "\037"; ORS = "\036"; OFS = "\037" }
          { p = $1; sub(/^\.\//, "", p); print c, t, p, $2 }'
    done > "$work/hits"
  "$sqlite" "$db" ".import --ascii $work/hits grep_hit"
done < "$work/corpora"
"$sqlite" "$db" < "$here/grep_rank.sql"

echo "running bm25" >&2
n=0
while read -r name _; do
  n=$((n + 1))
  sed -e "s/__FTS__/fts_$n/g" -e "s/__METHOD__/bm25/" -e "s/__CORPUS__/$name/" "$here/bm25.sql" | "$sqlite" "$db"
  sed -e "s/__FTS__/fts_all/g" -e "s/__METHOD__/bm25_pooled/" -e "s/__CORPUS__/$name/" "$here/bm25.sql" | "$sqlite" "$db"
done < "$work/corpora"

"$sqlite" "$db" < "$here/report.sql"
