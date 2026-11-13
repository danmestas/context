# The second shipyard corpus

The same kind of thing as [../shipyard](../shipyard/README.md), six times larger: 209 real
coding-agent sessions and 139 questions whose answers exist only in those sessions.

- `sessions.tar.gz` holds `sessions/` (209 transcripts in Claude Code's format, with the
  stored tool output of twelve of them) and `memory/` (the notes each stream's agent kept).
  Unpack it and copy `questions.json` beside the two folders to run the bench scripts.
- `manifest.json` lists each session with its stream, day, date, checksum, how it ended,
  and the memory notes that existed when it started.
- `questions.json` holds the questions, in the same shape as the first corpus.
- `tasks.json` is the plan the sessions were run from, with notes where it changed
  mid-run. The question writers did not see it.

## How it differs from the first

- Five streams of work on the same codebase run side by side, each in its own working
  copy: search, archiving, rules and hooks, wiki and tickets, build and docs. A stream's
  sessions build on each other.
- The streams reuse vocabulary on purpose: 51 sessions across 11 topics say similar
  things about different work, so word overlap does not single out a session.
- Each stream has reverted attempts, decisions between options, standing instructions,
  revisits, regressions planted in one session and fixed days later, and sessions that
  stop unfinished. Six sessions were cut off by their time limit or by the run being
  paused, and are kept as they are.
- The memory notes were kept, so an arm can be given what a session had when it began.

## How it was made

As for the first corpus: each session is one headless run of a coding agent (Claude
Sonnet) on a written task; timestamps were shifted by whole days to span eight weeks;
account details and home paths were replaced with placeholders. The questions were
written stream by stream from the transcripts alone, by writers who used no search tool
and did not see the plan, and each was checked against that stream's final repository,
its commit messages and its memory notes.

Nothing in ctx was tuned on this corpus before its first results were recorded, so all
139 questions count; there is no held-out split.

## Known weaknesses

- The subject is ctx itself, as before.
- Sessions are short and end with tidy summaries, so many answers sit in one message.
- Commit messages are detailed, which pushed the questions toward reverted experiments
  and side details.
- Nine planned interruptions arrived after the agent had finished, so few questions ask
  where work stopped.
