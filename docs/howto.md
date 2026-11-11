# How to use ctx

Each section is one task. Commands assume `ctx` is on your PATH; `ctx` with no
arguments lists them all, and `ctx version` prints its version and SQLite's.

- [Install](#install)
- [Archive your sessions](#archive-your-sessions)
- [Search past work](#search-past-work)
- [Check the archive for secrets](#check-the-archive-for-secrets)
- [Keep standing rules](#keep-standing-rules)
- [Set up a project](#set-up-a-project)
- [Work with tickets](#work-with-tickets)
- [Add sources](#add-sources)
- [Retire a source](#retire-a-source)
- [Keep a wiki](#keep-a-wiki)
- [Share between machines](#share-between-machines)
- [Add past sessions to prompts](#add-past-sessions-to-prompts)
- [Rebuild and upgrade](#rebuild-and-upgrade)
- [Measure and improve the skill](#measure-and-improve-the-skill)
- [Query the database directly](#query-the-database-directly)
- [Environment](#environment)

## Install

### From a release archive

A release archive is a Claude Code plugin. It holds `bin/ctx`, the `ctx` and
`ctx-wiki` skills, and hooks that archive each session.

```sh
tar xzf ctx-0.0.1-darwin-arm64.tar.gz
claude plugin marketplace add ./ctx-0.0.1-darwin-arm64
claude plugin install ctx@ctx
ln -s "$PWD/ctx-0.0.1-darwin-arm64/bin/ctx" ~/.local/bin/ctx
ctx init
ctx scan
```

While the plugin is enabled, `ctx` is on the Bash tool's PATH inside Claude Code;
the link puts it on yours. The Linux archives need glibc 2.34 or later.

If you also have the ctx hooks in your own `settings.json`, remove them, or every
session is archived twice.

### Install from source

```sh
make                      # needs a C compiler and zlib
cp ctx ~/.local/bin/
mkdir -p ~/.claude/skills && cp -R skill/ctx skill/ctx-wiki ~/.claude/skills/
ctx init
ctx scan
```

Then add the hooks to `~/.claude/settings.json`, merged with any you have:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [
      { "type": "command", "command": "ctx hook", "async": true },
      { "type": "command", "command": "ctx ticket offer", "timeout": 3 },
      { "type": "command", "command": "ctx rules offer", "timeout": 3 }
    ] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "ctx rules offer", "timeout": 3 }] }],
    "Stop":       [{ "hooks": [{ "type": "command", "command": "ctx hook", "async": true }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "ctx hook", "async": true }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "ctx hook", "async": true }] }]
  }
}
```

Use the full path to `ctx` if `~/.local/bin` is not on the PATH hooks run with.

## Archive your sessions

With the hooks installed there is nothing to do. `ctx hook` notes the transcript
and returns at once; the archiving runs detached. At most once an hour it also
scans `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR/projects`) for transcripts that
grew without a hook, and syncs repositories that have a remote. That check runs
on any turn, at most once an hour, so a session that runs for days gets it too.

By hand:

```sh
ctx scan [DIR]            # archive everything that grew since it was last read
ctx archive FILE.jsonl    # archive one transcript
ctx extract FILE.jsonl    # print the redacted turns without storing them
```

Each turn records who it is from: `user` for what you typed, `assistant`, `tool`
for tool output and `meta` for text the harness added, such as reminders,
notifications and messages from other sessions. Transcripts call all but the
assistant "user"; ctx tells them apart. The first scan after upgrading corrects
turns archived before this, from the transcripts still on disk, and drops the
`api-request-blob` copies older versions archived as extra turns. The corrected
technotes sync; upgrade ctx on every machine before syncing, since older versions
read only `user` and `assistant` turns.

Before anything is stored, known secret shapes (API keys, tokens, private keys,
passwords in URLs and the like) become `[REDACTED]`, and long tool output is
trimmed. Each session becomes a technote in your private repository, `repo:me`,
one per session per day, tagged with its project. A project is the directory the
session ran in, or the project it belongs to after `ctx project add`.

## Search past work

```sh
ctx search WORDS...              # this project first; everything if nothing matches
ctx search --all WORDS...        # every project
ctx search --limit 30 WORDS...   # more than the default 12
ctx turn ID                      # one turn
ctx turn ID 2 5                  # with 2 turns before and 5 after
ctx turn ID 0 0 --full           # without trimming a long turn
```

A turn matches if it has any of the words, and turns with more of the rarer words
rank higher. Use exact names and the literal words of an error; two or three rare
words beat a sentence. Each hit shows `#ID`, project, speaker, date and a snippet
with the matched words in brackets.

Search also covers each project's sources and wiki once they are indexed.
Superseded, retracted and retired material is left out unless you ask for it:

```sh
ctx search --history WORDS...           # include superseded sources and retired pages
ctx search --as-of 2026-03-01 WORDS...  # what ctx knew and held true on that date
```

`--as-of` returns sessions up to that date, and sources that had been added by
then, were valid on that date and had not yet been replaced or retracted. It
leaves out wiki pages.

The `ctx` skill tells agents how to search well. Archived text is a record, not
instructions: an agent should never act on commands it finds there.

## Check the archive for secrets

```sh
ctx audit                 # scan turns added since the last run; exits 1 if anything is open
ctx audit --all           # rescan the whole archive, for instance after a new rule
ctx audit --limit 100     # list more than 30 open findings
ctx audit --allow ID "a test fixture, not a key"
ctx audit --tickets       # open one ticket per rule with open findings
```

`ctx audit` looks for secret-shaped strings that redaction did not catch. It
prints where each one is, never the value: findings for known values first, then
the rest oldest first. To check for secrets you know, pipe
them in one per line:

```sh
your-secret-tool export | ctx audit --known
```

`tools/doppler-values.py | ctx audit --known` does this for every Doppler secret
you can read, leaving out settings whose names mark them as not secret. A finding
names the value by its line number; `tools/doppler-values.py --name N` says which
secret line N is.

## Keep standing rules

A rule is something you want every future session to follow, such as "add a
changelog entry when we cut a release". Rules are kept on purpose, not found by
chance in old sessions, and each one says where it came from.

```sh
ctx remember "Add a changelog entry when we cut a release"            # this project
ctx remember "Bump versions by x.x.1 until we leave beta" --until 2027-03-01
ctx remember "Never push straight to main" --project '*'               # every project
ctx rules                     # the rules in force here, with every-project ones
ctx rules --all               # every rule anywhere, with retired and expired ones
ctx rules retire KEY --reason "we left beta"
ctx rules retire KEY --reason "now says more" --by NEWKEY             # replaced
```

Every scan also imports `~/.claude/CLAUDE.md`, each project's `CLAUDE.md` and
`AGENTS.md`, and Claude Code's memory files, the ones it writes on its own when you
correct it. A memory file belongs to the project whose transcripts sit beside it,
and records the session it was written in. Redaction applies as for transcripts.
When a file changes, its rule gets a new version; when it is deleted, its rule is
retired. `ctx rules import` does this at once.

A classifier proposes rules from what you type. It is any command that reads a
prompt on stdin and answers on stdout, so it works with whatever model you use;
ctx supplies the prompt and only ever records proposals. It sees the turns you
typed, never tool output, and nothing becomes a rule until you accept it:

```sh
ctx rules classifier "claude -p --model haiku --tools ''"   # or llm, codex exec, a local model
ctx rules propose              # classify new turns now; the hourly scan does it too
ctx rules proposed             # this project's waiting proposals; --all for every project
ctx rules accept 12 [--text "better wording"] [--until DATE]
ctx rules reject 13            # never proposed again
ctx rules classifier --off     # stop
ctx rules candidates           # the turns a classifier would see, as JSON lines
ctx rules prompt               # the question it is asked
ctx rules suggest TURN TEXT    # record a proposal from any other tool
ctx remember "..." --from 444886    # a rule that records the turn you said it in
ctx turn turn:UUID                  # read that turn again later, by the id a rule records
```

`eval/rules_bench.py --classify "CMD"` scores a classifier against a labelled set of
your turns. On 1,000 of them, Haiku found 84% of the standing instructions at 76%
precision, DeepSeek 80% at 60%; matching words such as "always" found 17%.

`ctx rules offer` is a SessionStart hook, installed by the plugin. It tells the agent
that past sessions are searchable, lists rules it would not otherwise load (those
from `ctx remember`, and memory from this project's other folders) and mentions
waiting proposals. On 90 questions about past work it raised Claude's score from
66.5 to 73.5 (better on 16, worse on 6) with 7% fewer tokens; on DeepSeek, agents
used ctx in 89 answers instead of 66 and needed half the tool calls.

Rules fade by kind, not by age. Claude Code files status snapshots ("what shipped",
"the backlog") as memory of type `project`; most go stale within weeks, so such a
note fades 30 days after its file was last written, and editing it brings it back.
Rules in your own words and corrections stay until you retire them. On 42 rules you
labelled, 12% of your own rules had gone stale, 44% of corrections and 83% of status
notes; age-based fading caught more stale rules but quieted a quarter of true ones.
A faded rule is listed by `ctx rules --all` and found by `ctx search --history`.

Two checks catch the rest, and both leave the decision to you:

```sh
ctx rules judge-with "claude -p --model sonnet --tools ''"   # any command that answers on stdout
ctx rules judge          # check rules in projects with new turns; the hourly scan does it too
ctx rules keep KEY       # still true: not asked about again for 90 days
ctx rules review         # the rules due their monthly check, 30 at a time
ctx rules review --done  # mark the listed ones reviewed
```

The judge reads a rule beside your recent turns in its project and flags it only with
a quote of your own words that appears exactly in those turns, so it cannot invent a
contradiction. Each call to the judge or classifier is stopped, with anything it
started, after 120 seconds. The next session in that project asks you once, at a natural break,
and never about the same rule within 30 days; your answer runs `keep` or `retire`.
In an experiment on 42 labelled rules, Sonnet flagged 3, all of them truly stale,
while Haiku flagged 9 with 3 wrong. Most stale rules are never contradicted in
conversation; the monthly review is for those, mentioned once a month at session
start.

Each rule is a technote in your private repository, so every version is kept and
rules sync with your archive. A rule past its `--until` date expires. Search shows
rules in force, each under its file name or key; `--history` brings back expired,
replaced and retired ones.

## Pick up after a compaction

Every question an agent asked you with AskUserQuestion is a decision record: the
question, its options, and your answer, read from the archived turns.

```sh
ctx decisions            # this project's latest questions and answers
ctx decisions --open     # those still waiting for you, from the last 14 days
ctx decisions --all      # every project
```

A question is `answered`, `declined` (you replied in your own words, which become the
answer), `interrupted` (the session ended or was compacted before you answered) or
`open`. On one archive of 745 questions, 727 were answered, 15 declined, 2 interrupted
and 1 open; 83% of the answers name one of the offered options.

When a session is compacted or resumed, `ctx rules offer` begins with where it stood,
from that session's own turns: questions still waiting for you or cut off, what you
decided in the last two days, messages from other sessions in the last day, rules you
set in it, and when you last reported a landing. A fresh session gets none of this.

## Set up a project

A project maps a directory to a shared Fossil repository held inside the ctx
database. Sessions run under that directory belong to it, and its sources and wiki
live in that repository.

Sources are committed from an ordinary Fossil checkout, so start from a Fossil
repository and clone it into ctx:

```sh
fossil init ~/fossils/myproj.fossil             # or use one you already serve
cd ~/code/myproj && fossil open ~/fossils/myproj.fossil
ctx project add myproj --clone ~/fossils/myproj.fossil
```

The clone's URL, a file path or an http URL, becomes the project's remote: `ctx
project pull` brings in check-ins from it and `ctx sync myproj` sends wiki pages
back. Other forms:

```sh
ctx project add myproj                          # an empty repository, for a wiki without sources
ctx project add myproj --import repo.fossil     # a copy of a Fossil repository file, with no remote
ctx project add myproj --root DIR --remote URL  # map another directory, and set where it syncs
ctx project list                                # name, repository, directory
ctx project pull myproj [--from URL]            # bring in new check-ins
```

Repository names keep only letters and digits: `my-proj` becomes `repo:myproj`.

## Work with tickets

Tickets live in your private repository, `repo:me`, each tagged with its project,
so they sync with your archive. `--type` is Task (the default), Bug, Feature or
Question.

```sh
ctx ticket new "Fix the importer" --type Bug --body "Stalls on files over 2 GB" \
  --acceptance "A 3 GB file imports" [--blocked-by ID]...
ctx ticket ready              # open and unblocked, for this project
ctx ticket ready --all        # every project
ctx ticket show ID
ctx ticket claim ID [--as NAME]
ctx ticket done ID --result "Fixed in 4f2a91"
ctx ticket drop ID --reason "Superseded by 9c1e"
```

A claim belongs to one person. When `repo:me` has a remote, `ctx` syncs before and
after a claim, so two machines cannot both take the same ticket.

`ctx ticket offer` runs at session start. It prints nothing unless this project
has ready work, and then lists up to five tickets for the agent, as a record, not
as instructions.

## Add sources

Sources are the documents a project's knowledge is built from: specs, papers,
vendor docs, notes. They live in the project's checkout under `sources/`, are
committed like code, and are never edited in place.

```sh
ctx source add ~/Downloads/spec.pdf --origin https://example.com/spec \
  --class versioned --valid-from 2026-01-15 [--as vendor/spec.pdf]
```

This copies the file to `sources/` and writes `spec.pdf.origin.json` beside it,
with its SHA3 hash, origin, class, dates, risk and who added it. Commit both in
the checkout, then pull into ctx and index:

```sh
fossil add sources && fossil commit -m "Add the vendor spec"   # and fossil push if served
ctx project pull myproj
ctx index
```

The class says how long a source can be trusted:

| Class | Meaning | Needs |
|---|---|---|
| `evergreen` | stays true | |
| `versioned` | true for one version of something | best with `--valid-from`, and `--valid-until` once replaced |
| `perishable` | goes stale with time | `--review-after DATE` |

Other options: `--retrieved DATE`, `--how` (how it was obtained), and
`--risk security|money|legal|api`, which keeps the wiki from retiring anything
built on it without a person.

`ctx source check` fails if any source has no origin, has changed since its origin
was recorded, or has an invalid class, and lists perishable sources due for
review. Run it in the project's CI.

## Retire a source

Old information is superseded, not erased. Add the newer source, then record one
of three relations:

```sh
ctx source add ~/Downloads/spec-v3.pdf --origin https://example.com/spec/v3 \
  --class versioned --valid-from 2026-09-01
ctx source supersede spec.pdf --by spec-v3.pdf --relation replaces --reason "v3 replaced v2"
ctx source supersede spec.pdf --by errata.md --relation amends --reason "errata"
ctx source supersede spec.pdf --relation retracts --reason "withdrawn by the vendor"
ctx source uses sources/spec.pdf  # which wiki claims depend on it
```

Names work with or without the `sources/` prefix. Each relation appends an event
to `sources/SUPERSEDED.jsonl`; commit it like any other change. After `replaces`
or `retracts`, search leaves the old source out unless asked with `--history` or
`--as-of`; an amended source stays in. Run `ctx wiki repin` afterwards, as below.

## Keep a wiki

The wiki is Markdown pages compiled from the sources. `ctx wiki save` is the only
way a page is written, and it refuses one whose provenance does not hold. The
`ctx-wiki` skill teaches agents the format; a page looks like this:

```markdown
# Cache design

The cache keeps entries for 30 seconds.[^ttl]

Synthesis: short lifetimes and nightly eviction keep the table small.[^ttl][^evict]

See [Eviction policy](/wiki?name=Eviction+policy).

[^ttl]: "The cache TTL is 30 seconds." [design.md](/file?name=sources/design.md&ci=FULLHASH&txt=1)
[^evict]: "Evictions run nightly." [ops.md](/file?name=sources/ops.md&ci=FULLHASH&txt=1)
```

The gate checks, without any model:

- every claim has a footnote, and every quote appears word for word in what it
  cites: a source or code file at a full check-in hash, or a session or ticket of
  this project;
- each cited source has an origin and still matches its recorded hash;
- a claim starting `Synthesis:` cites at least two sources;
- no citation points at a wiki page, and every page link points at a page that
  exists;
- the page is under 32 KB.

It adds a `## Sources` list and a `## Provenance` block, and reports any claim the
new version dropped. Get the full trunk hash for citations with:

```sh
ctx sql "SELECT fsl_open('repo:myproj'), fsl_use('repo:myproj'), fsl_resolve('trunk')"
```

Then:

```sh
ctx wiki save "Cache design" page.md --model MODEL [--ticket ID] [--session ID]
ctx wiki publish             # regenerate the Wiki Index and Wiki Health pages
ctx wiki check               # every citation still holds; exits 1 on a problem
ctx wiki why "Cache design"  # each claim beside its quote, to review by eye
ctx sync myproj              # push the pages to the project's remote
```

The gate proves a quote exists; only a reader can tell it supports the claim. Read
`ctx wiki why` for every page.

When sources change:

```sh
ctx wiki repin                # move each claim whose quote survives; ticket the rest
ctx wiki queue                # stale knowledge, most depended-on first
ctx wiki retire PAGE --reason WHY [--by NEWER-PAGE]
ctx wiki restore PAGE
ctx wiki retire --auto        # list pages nothing needs any more
ctx wiki retire --auto --apply
```

`--auto` retires only a page whose sources are all gone (superseded, retracted, or
more than 90 days past review), that nothing links to,
that past sessions do not mention, and that has no risk class. Anything else that
looks finished becomes a ticket for a person. A retired page keeps its text and
history.

Every command takes `--project P` to work on a project other than the current
directory's.

## Share between machines

Each repository syncs with a Fossil server over plain http, so use a private
network or an ssh tunnel; ctx has no TLS.

A remote must hold a copy of the same repository. Give `ctx remote` a local file
that does not exist yet and it writes that copy, readable only by you; one that
exists is never overwritten. Serve the file, or reach it as a file:

```sh
ctx remote me /srv/ctx/me.fossil                # writes the copy and syncs with it
fossil server --port 8080 /srv/ctx/me.fossil    # on the host; or zit serve
ssh -N -L 8080:127.0.0.1:8080 host              # on each machine
ctx remote me http://127.0.0.1:8080/
ctx sync                                        # every repository with a remote
```

On a second machine, start from that copy instead of an empty archive:

```sh
ctx init --clone http://127.0.0.1:8080/
```

Sessions archived on other machines become searchable after each sync. The hooks
also sync at most once an hour while you work.

A project syncs with the server it was cloned from (`ctx project add --clone URL`),
or with one you set:

```sh
ctx remote myproj URL
ctx sync myproj
```

## Add past sessions to prompts

`ctx inject` is a `UserPromptSubmit` hook that adds up to three short snippets
from past sessions to a prompt when its rare words match strongly, and nothing
otherwise. It is not installed by default: in an eval of 90 questions it scored
no better than the `ctx` skill alone. To try it, add to `settings.json`:

```json
"UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "ctx inject", "timeout": 3 }] }]
```

`ctx recall` is a lighter `UserPromptSubmit` hook: when your prompt opens with a
reference to earlier work ("do you remember", "last time", "didn't we"), it adds one
line telling the agent to search first. It matches words only and never opens the
database. It is not installed by default either: on your prompts it would fire less
than once a day, and in the eval agents already searched on all 13 questions that
would trigger it.

A subagent starts without the session-start note, so `ctx rules offer` also answers
the `SubagentStart` event with that one line (about 45 tokens) and nothing else.

Two measurements shaped this. Asked plainly, with no hint that a question is about
past work, fresh agents with the skill searched the archive on 18 of 23 held-out
questions; rewording the skill's triggers made it 19, so the wording stayed. And a
hook that held back an agent's question when you had answered a similar one before
was dropped: replayed over 743 real questions it fired on 133, and the earlier turns
held your eventual answer in 16% of those and a conflicting one in 8%.

## Rebuild and upgrade

```sh
ctx rebuild
```

drops the search index, citations and links and rebuilds them from the
repositories. When a new version of `ctx` changes those tables it rebuilds by
itself on first use; the kept tables are upgraded in place. A rebuild of a large
archive takes a minute or two.

## Measure and improve the skill

```sh
ctx stats              # the last 8 weeks
ctx stats --weeks 26
```

`ctx stats` shows, per week and per project, how many sessions ran and how often
agents used ctx in them: searches, searches that found nothing, `ctx turn` reads
and loads of the `ctx` skill. It counts commands agents really ran, not mentions
of them, from the archive alone, so it is free to run weekly. A project with many
sessions and no searches is where the skill is not being reached for.

`eval/skill_eval.py` measures the `ctx` skill against a private bank of questions
about past work, with blind grading and a held-out set, so a change to the skill
is kept only if results improve. The question bank and results stay in
`~/.ctx/eval`. [eval/README.md](../eval/README.md) describes the loop.

## Query the database directly

```sh
ctx sql "SELECT project, count(*) FROM ctx_capture GROUP BY 1"
```

`ctx sql` runs one statement with libfossil's SQL functions loaded, such as
`fsl_open`, `fsl_use` and `fsl_resolve`. The tables are described in
`schema/state.sql` and `schema/index.sql`.

## Environment

| Variable | Effect |
|---|---|
| `CTX_DB` | the database, instead of `~/.ctx/ctx.sqlite` |
| `CLAUDE_CONFIG_DIR` | where transcripts are found, instead of `~/.claude` |
| `USER` | the name on check-ins, claims and sources |
| `CTX_SESSION` | the session `ctx wiki save` records a page against |
