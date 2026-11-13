# Head-to-head retrieval results on shipyard2 (209 sessions, 139 questions)

Run on 2026-11-13 on an arm64 macOS host with Docker Desktop 28.2.2 (linux/arm64 containers,
`--cpus 4 --memory 4g` each). The host was loaded (load average roughly 11 to 24 during the run),
so times are upper bounds. The two arms indexed at the same time, so index times are slightly
inflated by contention between them.

Arms and versions:

- cass-hybrid: cass v0.11.0 (release binary `cass-linux-arm64.tar.gz`) with all-minilm-l6-v2
  installed by `cass models install -y`.
- episodic-memory: commit 7e06519357777badd7a115d2014a7ef845904310 (package 1.6.0), same commit
  as the 32-session run, `EPISODIC_MEMORY_SKIP_SUMMARIES=1`.

The recipe is the one in `../../shipyard/results/README.md`, unchanged: same Dockerfiles, same
runner scripts, same query commands, `sessions/` mounted read-only at `/corpus`, network on for
build, model download and indexing and off for the queries. The corpus has 209 transcripts;
the `sessions/` folder also contains 12 subdirectories, which were copied along with the files
as they are. The only differences from the earlier run are the corpus and the two arms indexing
concurrently.

## Scores

Every gold session in the first five / at least one, from `score.py`, all 139 questions
(nothing was tuned on this corpus):

| Arm | question, all 139 | paraphrase, all 139 |
|---|---|---|
| cass-hybrid | 116 / 130 | 43 / 57 |
| episodic-memory | 125 / 135 | 49 / 63 |

## Index

| Arm | index time | index size | notes |
|---|---|---|---|
| cass-hybrid | 298.8 s (model install 8.1 s extra) | 200 MB, of which the model is 91 MB | 209 conversations, 5296 messages, 9723 vector documents; all 278 queries ran in hybrid mode |
| episodic-memory | 300.3 s, including the embedding model download | 50 MB: 3.9 MB index plus a 46.0 MB archive copy of the transcripts | 209 conversations synced and indexed; 0 errors in 278 queries |

Mean query time: cass-hybrid 0.38 s, episodic-memory 0.54 s.
