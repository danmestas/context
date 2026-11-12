# Head-to-head protocol

This is the plan for comparing ctx with other tools that give a coding agent access to
its past sessions. It is written before any tool is run, so the rules cannot be bent to
fit a result. Changes after the first run are recorded at the bottom with their date.

## The question

Given the same past coding sessions, how often can an agent answer a question whose
answer exists only in those sessions, with each tool, and at what cost?

Two things are measured separately, because they fail separately:

1. **Retrieval.** Does the tool's search return the session that holds the answer?
   No model is involved.
2. **Answers.** Does an agent with the tool installed answer correctly? This depends on
   whether the agent uses the tool at all, which is reported as its own number.

## The corpus

A public corpus built for this purpose, because the alternatives fail:

- A private archive cannot be published, and some tools send text to a model provider.
- The public sets that exist are chat, not coding (LongMemEval), or tiny and invented
  (coding-agent-life-v1, where grep nearly ties).

The corpus is real agent sessions, not invented ones:

- One open-source repository, fixed at a commit, small enough to read in a session.
- About 30 sessions spread over simulated days: bug fixes, refactors, failed attempts
  that are abandoned, decisions between options, instructions from the person, and at
  least five sessions that revisit earlier work.
- Each session is a real headless run of a coding agent on a written task, so the
  transcripts have the shape real ones have: tool calls, errors, diffs, long output.
- The transcripts are published with the questions. Nothing in them is private.

## The questions

- Written from the transcripts by someone who has not seen any tool's results on them,
  then reviewed against the repository so that code, comments and commit history do not
  answer them.
- At least 60, in five kinds: a decision and its reason, something that failed, how a
  bug was fixed, what the person asked for, and where work stopped.
- Each question has two wordings: one that reuses the session's own terms and one that
  paraphrases them. Results are reported for each wording, because exact terms favour
  keyword search and paraphrase favours embeddings.
- One in three is held out and never used while any tool is being set up.
- Each question names the sessions that hold its answer, for the retrieval score.

## The tools

Every tool is run at its defaults, at a recorded version, with the same tuning budget:
none. That includes ctx: its search settings, skill and hooks are frozen at a check-in
recorded before the questions are written.

| Arm | What it is |
|---|---|
| grep | The agent has the transcripts as files and ordinary search tools. |
| Built-in memory | The harness's own memory files and resume, nothing added. |
| ctx | This project. |
| cass | Local keyword search over agent sessions; also run with its embedding model. |
| episodic-memory | Local embeddings over transcripts, searched through MCP. |
| agentmemory | Its keyword mode, which needs no key. |
| TraceDecay | Its session history and search. |
| claude-mem | Only if it can load the same transcripts. If it cannot, it is listed as not runnable under this protocol rather than scored on other data. |

A tool joins only if it can read the published transcripts as they are and run without a
cloud account. A tool that calls a model while indexing has those calls counted.

## What is reported

For each arm, on the held-out questions:

- **Retrieval:** the share of questions where every session holding the answer is among
  the first five returned, and the share where at least one is.
- **Use:** the share of questions on which the agent called the tool at all, asked
  plainly with no hint that the question is about past work.
- **Answers:** correct, partly correct, wrong and "don't know", graded blind in one
  shuffled pass by a model different from the one answering. A sample is checked by hand.
- **Forced use:** the same questions with an instruction to search first, which separates
  how good the tool is from whether the agent thinks to use it.
- **Cost:** tokens by type for answering, tokens and time spent indexing, index size,
  and search time, cold and warm, on a machine that is not otherwise busy.

## What counts as a difference

Sample sizes are small. A gap is reported as a difference only if a sign test on the
paired questions gives p below 0.05; otherwise the arms are reported as level. No arm
is called the winner on a gap of a few questions.

## What this will not show

- How any tool behaves deep in a long session, after several compactions.
- How any tool behaves on another person's work.
- Anything about features outside session recall. ctx's rules, decision records,
  compaction brief and cited wiki, and other tools' code graphs or fact stores, are
  compared separately or not at all.

## Changes

- 2026-11-12, before any tool was run: the subject repository is ctx itself. It is the
  only public repository already on the machine that builds and tests in seconds, and
  running the sessions on another project would have meant downloading and executing
  its code. The corpus and its weaknesses are described in
  [shipyard/README.md](shipyard/README.md).
- 2026-11-12: the corpus has 32 sessions and 67 questions, of which 30 are held out.
  ctx was measured at check-in 7150d2056fec, before anything in it was changed in
  response to this corpus.
- 2026-11-12, after the first retrieval run: ctx search failed on questions that name a
  flag. The fault was found and the fix chosen using only the 37 questions that are not
  held out; the held-out 30 were then run once at check-in 4095a7b2dab0. Both results
  are published. The bench scripts now put `--` before the question's words.
- 2026-11-12: third-party tools are run in containers with only the corpus mounted, so
  their index time includes container overhead and is not compared with ctx's.
