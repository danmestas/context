# The shipyard corpus

Real coding-agent sessions on a public repository, with questions whose answers exist
only in those sessions. It is the shared input for the comparison described in
[../head-to-head.md](../head-to-head.md).

- `sessions/` holds 32 transcripts in Claude Code's format, one file per session, named
  by session id. Six have a folder of stored tool output beside them.
- `manifest.json` gives, for each session, its day, date, turn counts and checksum, and
  the check-in of the subject repository the sessions started from.
- `questions.json` holds 67 questions. Each has two wordings (`question` reuses the
  session's own terms, `paraphrase` avoids them), an answer, the facts a correct answer
  must contain, and the sessions that hold the evidence.
- `questions2.json` holds 40 more questions (ids starting `r-`), written later by a writer who
  had read the first set only to avoid repeating it. It is kept for final checks: nothing
  in ctx is tuned against it.
- `tasks.json` is the plan the sessions were run from. The question writer did not see it.

## How it was made

Each session is one headless run of a coding agent (Claude Sonnet) on a written task, in
one working copy that carries over from session to session. The runs happened on one day;
every timestamp in a transcript was then shifted by whole days so the sessions span three
weeks, as `manifest.json` records. Account details and home paths in the transcripts were
replaced with placeholders.

The questions were written from the transcripts alone, by a writer who had not seen the
task plan and used no search tool, then checked against the final repository and its
commit messages. Thirteen drafts were dropped or reworked because the code answered them.

One question in three is held out: a question is held out when the SHA-256 of its id,
read as a number, is divisible by three.

## Known weaknesses

- The subject repository is ctx itself. Tools search the transcripts, not the repository,
  but questions about ctx's own code may still suit it.
- In one session the agent reads earlier transcripts directly to recover a list.
- Standing instructions were saved to the harness's memory folder and re-read in later
  sessions, which helps any arm that has that folder.
- Two of the three planned unfinished sessions ended with nothing to do, so only two
  sessions stop mid-task.
- 32 sessions is small. Scoring whole sessions by word overlap works well at this size
  and would not at a thousand.
