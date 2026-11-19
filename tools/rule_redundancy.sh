#!/bin/sh
# Reports how much of an archive's rules the automatic clean-up would touch, changing nothing:
# rules in force, identical copies a rules import would collapse, rules the covered check would
# send to the judge, and groups of the same rule saved in several projects.
#
#   cp ~/.ctx/ctx.sqlite /tmp/copy.sqlite    # with ctx not running
#   CTX_DB=/tmp/copy.sqlite tools/rule_redundancy.sh
#
# Each agent's global instructions are the rules keyed by the paths ctx reads them from, with
# the same environment (CLAUDE_CONFIG_DIR, CODEX_HOME and the rest, else HOME) as for ctx.
set -eu

CTX=${CTX:-ctx}
[ -n "${CTX_DB:-}" ] || { echo "rule_redundancy: set CTX_DB to a scratch copy of the archive" >&2; exit 2; }
[ -n "${HOME:-}" ] && [ "$CTX_DB" -ef "$HOME/.ctx/ctx.sqlite" ] && { echo "rule_redundancy: CTX_DB is the live archive; use a copy" >&2; exit 2; }
export CTX_DB

echo "active rules: $("$CTX" sql "SELECT count(*) FROM ctx_doc WHERE kind = 'rule' AND status IS NULL")"
echo "identical copies to collapse: $("$CTX" rules collapse --dry-run | sed -n 's/^\([0-9]*\) identical cop.* would collapse$/\1/p')"
echo "rules to send to the covered check: $("$CTX" rules covered --dry-run | sed -n 's/^\([0-9]*\) rules would be sent.*/\1/p')"
echo "groups of the same rule in several projects: $("$CTX" rules same | sed -n 's/^\([0-9]*\) groups\{0,1\} of the same rule.*/\1/p')"
