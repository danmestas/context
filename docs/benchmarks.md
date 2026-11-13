# Benchmarks

This page lists what ctx has been measured to do. Every figure comes from a result file in `bench/results/`, and each result shows the date it was measured, the check-in it was measured on and the command that reruns it. Figures measured on the author's own private session archive give counts only, because the sessions themselves are not published. Results that failed the bar set before the run are kept on purpose.

## How to read this page

- **Compared with** names the baseline. It is always ctx against what an agent would do without it, or ctx with a change against ctx without it. No other tool has been run here. Where another project publishes a score on the same public data under the same scoring, it is quoted and named as theirs; nothing else on this page says ctx is better or worse than another product.
- **Bar** is the threshold that was written down before the run. "Passed" and "failed" refer to that threshold and nothing else. A result with no bar only describes; it was not a test.
- **What it means** says what the result changed: what was kept, what was removed, and what is still unknown.
- A score such as recall is out of 1, and a score "of 90" is out of that many questions. Sample sizes are small, so a difference of one or two questions is not evidence of anything.
- Most figures come from one person's session archive. They show how ctx behaves on that archive, not on yours.

## At a glance

| Result | Outcome | What it means |
| --- | --- | --- |
| Ranking: full-text search against grep | Passed its bar | The ranking ctx uses finds about 57% of the labelled documents in its top 10, against 37% for grep. It is a clear win over grep and still misses a lot; no target for the absolute score has been set. |
| LongMemEval-S, retrieval only | No bar | ctx's search is level with another tool's published keyword search (two questions apart in 470, which is noise) and well ahead of grep. Both are weakest where evidence is spread over several sessions or depends on dates. Tools that use embeddings report higher figures on this benchmark, but those are their own reports under other scoring, so they are not shown as a comparison. |
| A small public set of coding sessions | Passed its bar | ctx clears the check. It says little more than that: the set is 15 invented sessions, and grep does as well. A harder public set of coding sessions does not exist yet. |
| 209 coding sessions: finding the session that holds the answer | Passed its bar | At this size the index is clearly better than ranked grep. In the session's own terms ctx found the right session for 125 of 139 questions and grep for 71; ctx alone was right on 54 and grep alone on none (p below 0.0001). Where the answer is spread over two or more sessions, ctx found all of them for 27 of 40 questions and grep for 6. On the 32-session corpus the two were level. Paraphrased questions are still poor: 23 of 139, though again well ahead of grep's 5. |
| Coding sessions: finding the session that holds the answer, first run | No bar | ctx did worse than ranked grep here, 20 against 26 of 30 held-out questions in the session's own terms, and the cause was a fault, not ranking. Questions that name a flag, such as --json, made ctx search stop with an error and return nothing; an agent searching its history for a flag would have hit the same error. The result is kept as it was measured. The next result shows the same questions after the fault was fixed. Paraphrased, both methods fail most of the time. |
| Coding sessions: finding the session, after search accepted flag names | No bar | With the fault fixed, ctx finds the right session for 28 of 30 held-out questions in the session's own terms, against grep's 26. ctx alone was right on 3 and grep alone on 1, which is not a difference by the rule set beforehand, so the two are level on this small corpus. Over all 67 questions it is 64 against 52. The change was chosen using only the questions that are not held out, and the held-out ones were run once. Paraphrased questions did not improve: 5 of 30 for ctx and 7 for grep. That is the limit of keyword search, and it is what tools using embeddings should be tested on. |
| Coding sessions: other tools on the same questions | No bar | In the session's own terms every tool that ran properly is level with ctx; only TraceDecay was worse (p = 0.008). Paraphrased, the three tools using embeddings are clearly better than ctx: cass found 23 of 30, episodic-memory 20 and agentmemory 17, against ctx's 5 (each p below 0.001). That is the real gap in ctx's search. It costs them indexing time: one to nineteen minutes for 32 sessions, against seconds for keyword indexes. cass with keywords alone scored 1 of 30 because its default search needs every word of the question to match; that is its default, not its ceiling. This measures finding the session only. In the separate answer test, paraphrasing barely changed what agents got right, because agents rewrite their searches. |
| Would small embeddings close the paraphrase gap? | Failed its bar | A real gain, but short of the bar. Fusing the 30 MB model with keyword search finds 13 of 30 paraphrased questions instead of 5 (better on 9, worse on 1, p = 0.02) and loses nothing in the session's own terms. That is about half of what the neural tools gain, for almost no indexing cost. The smaller model does less and the larger one no better. ctx does not use embeddings as a result: the bar was not met, and in the answer test paraphrasing did not make agents answer worse, so the gain here may not reach the answers. |
| Small embeddings on 209 sessions | Failed its bar | The gain does not hold. Fused search found 126 and 25 of 139 against 125 and 23 for keywords alone, which is no difference (p = 0.77 on paraphrased questions). The improvement on the small corpus came from its size: with few sessions a rough sense of topic is enough to pick one, and with many sessions on one codebase it is not. ctx does not use embeddings. Tools that run a neural model were not tried at this size. |
| Coding sessions: do agents answer better with ctx? | No bar | Plain transcript files with a hint where they are scored highest. ctx as installed is level with them by the test set beforehand (better on 2 questions, worse on 6, p = 0.29) but three points lower, and ctx without its note is significantly worse (p = 0.04). The whole gap is use: the agent searched with ctx on 24 of 30 questions with the note and 19 without, and where it did search, its answers were as good as the transcript arm's. What ctx buys is cost: about a third fewer tokens, less than half the time, and two or three tool calls where grep needs seven to nine. Paraphrasing the question made almost no difference to any arm, because agents rewrite their own searches. With only the repository the agent could answer 6 of 30, so the questions do need session history. |
| Coding sessions: adding snippets or a reminder to the prompt | Failed its bar | Neither helps, and both arms scored below ctx as installed, significantly so on paraphrased questions. The reason is that they almost never act: snippets were added for 4 and 3 of 30 questions and the reminder for 1 and 0, so these arms are in effect the skill alone. On the few questions where snippets were added, the answers were right. The session-start note remains the one thing shown to make agents search, and both hooks stay off by default. |
| Answering questions about past work | Passed its bar | Telling the agent at session start that an archive exists is worth about 7 questions in 90 and costs no extra tokens. The difference is borderline by a sign test (p = 0.052), so it is kept as likely but not proven. |
| Reaching for the archive unprompted | Failed its bar | Rewording the triggers made no real difference (one question in 23), so the wording was not changed. Fresh agents already search about four times in five without being told. |
| A reminder when a prompt refers to earlier work | Failed its bar | The reminder changed nothing because agents already searched every time. The hook exists but is off by default. This test cannot show what happens deep in a long session, where the reminder might matter more. |
| Finding standing instructions in what a person types | No bar | A small model finds about five in six standing instructions; cue words find one in six. About a quarter of what it proposes is not a rule, which is why a person accepts or rejects each proposal. |
| Flagging rules that have gone stale | Passed its bar | The stronger model never flagged a rule that was still true, so it is the one ctx uses. It finds only a few of the stale rules, because most are never contradicted in conversation; a monthly review covers the rest. |
| Which kinds of rule go stale | No bar | Status notes go stale within weeks and rules in a person's own words rarely do, so ctx fades by kind. Fading by age would have silenced about a quarter of rules that were still true. |
| Holding back a question the archive may answer | Failed its bar | The idea failed clearly. Three in four firings were irrelevant and one in twelve pointed at a conflicting answer, so the hook was removed before it shipped. |
| Matching answers to the questions agents asked | Passed its bar | The record of questions and answers is consistent on a real archive. This checks that answers are attached to the right question, not that they were read correctly word for word. |
| Hooks and commands on a real archive, machine heavily loaded | Failed its bar | At the median every hook takes under 50 ms even with the machine running at three times its capacity. The run failed its bar because the first compaction brief took 1.2 s. A second run on a quiet machine gave the same first-run figure, so that cost belongs to the brief and not to the load. |
| Hooks and commands on a real archive, machine not busy | Failed its bar | With the machine quiet every hook takes 5 to 35 ms at the median. The compaction brief still failed the bar, at 1.2 s on its first run and about 35 ms after that. The same first-run figure appeared under heavy load, so it is not caused by load: the first brief after a while reads index pages that are no longer in memory. It is inside the 3-second limit, and it is the real cost after a compaction. |
| Background work | No bar | Background work costs a few seconds of processor time an hour. The rebuild is a one-off of a few minutes when the index format changes. |
| Fuzzing and sanitizers | No bar | Fuzzing found a real bug this week, in a rule that could match across a line break. It did not let a secret through. The failing input is now replayed on every check. |

## Search

### Ranking: full-text search against grep

Whether SQLite FTS5 with BM25 ranking, which ctx search uses, finds the right documents more often than ranked grep, the method an agent falls back on without it.

- **Compared with:** ranked grep over the same files, which is how an agent searches without ctx
- **Bar:** BM25 ahead of grep on recall at 10 and nDCG at 10. **Passed.**
- **What it means:** The ranking ctx uses finds about 57% of the labelled documents in its top 10, against 37% for grep. It is a clear win over grep and still misses a lot; no target for the absolute score has been set.

| Measure | Result |
| --- | --- |
| BM25, recall at 10 | 0.565 |
| BM25, recall at 50 | 0.784 |
| BM25, nDCG at 10 | 0.470 |
| BM25, mean reciprocal rank | 0.517 |
| grep, recall at 10 | 0.372 |
| grep, recall at 50 | 0.528 |
| grep, nDCG at 10 | 0.313 |
| grep, mean reciprocal rank | 0.348 |

Measured 2026-11-08; good until 2027-02-06.

- corpora: 5 repositories, 16,434 documents
- queries: 150, each labelled with the documents that answer it
- grep: ripgrep counts per term, ranked by terms matched then hits

```sh
bench/run.sh
```

[Result file](../bench/results/search-ranking.json)

### LongMemEval-S, retrieval only

A public benchmark of long-term memory in chat assistants. Run retrieval-only, it asks whether a search returns the sessions that hold the evidence for each question. It is chat, not coding work, but it is data anyone can rerun and others publish scores on.

- **Compared with:** the keyword search of the agentmemory project on the same file under the same scoring (84.7% strict, 96.2% any hit, measured 2026-10-28), and its grep baseline (72.1% strict)
- **Bar:** none; this result describes and was not a test.
- **What it means:** ctx's search is level with another tool's published keyword search (two questions apart in 470, which is noise) and well ahead of grep. Both are weakest where evidence is spread over several sessions or depends on dates. Tools that use embeddings report higher figures on this benchmark, but those are their own reports under other scoring, so they are not shown as a comparison.

| Measure | Result |
| --- | --- |
| Strict recall at 5 (every evidence session found) | 85.1% (400 of 470) |
| Fractional recall at 5 | 92.1% |
| Any hit at 5 | 96.6% (454 of 470) |
| Strict, knowledge-update | 71 of 72 |
| Strict, multi-session | 88 of 121 |
| Strict, single-session-assistant | 56 of 56 |
| Strict, single-session-preference | 25 of 30 |
| Strict, single-session-user | 63 of 64 |
| Strict, temporal-reasoning | 97 of 127 |

Measured 2026-11-12; check-in 9ca411f83487; good until 2027-05-11.

- data: LongMemEval-S cleaned, 500 questions of which 470 are answerable, about 50 chat sessions each; public, checksum pinned in the script
- pipeline: each question's sessions archived into a fresh ctx database, then ctx search with the question as typed
- scoring: the first five distinct sessions among the ranked turns; no model involved

```sh
bench/longmemeval.py --data longmemeval_s_cleaned.json
```

[Result file](../bench/results/longmemeval.json)

### A small public set of coding sessions

The only public set of coding-session questions found. It is tiny and invented, and plain grep nearly ties on it, so it is a check that nothing is broken and not a measure of how good a tool is.

- **Compared with:** the scores its authors publish on the same files: their keyword component found every evidence session for 14 of 15 questions, and their grep baseline for 15 of 15 (measured 2026-10-28)
- **Bar:** every evidence session found for at least 14 of 15 questions. **Passed.**
- **What it means:** ctx clears the check. It says little more than that: the set is 15 invented sessions, and grep does as well. A harder public set of coding sessions does not exist yet.

| Measure | Result |
| --- | --- |
| Questions with every evidence session in the first 5 | 15 of 15 |
| Recall at 5 | 1.000 |
| Questions with at least one evidence session in the first 5 | 15 of 15 |

Measured 2026-11-12; check-in 9ca411f83487; good until 2027-05-11.

- data: coding-agent-life-v1 from the agentmemory project: 15 invented sessions on a Rust command-line tool, 15 questions with the sessions that answer them; public, checksums pinned in the script
- pipeline: the sessions archived into a fresh ctx database, then ctx search with each question as typed
- scoring: the first five distinct sessions among the ranked turns; no model involved

```sh
bench/coding_life.py --data DIR
```

[Result file](../bench/results/coding-life.json)

### 209 coding sessions: finding the session that holds the answer

The first corpus had 32 sessions, few enough that counting matching words per session works about as well as an index. This one is six times larger, and its streams reuse each other's vocabulary.

- **Compared with:** ranked grep over the same transcript files: each session scored by how many of the question's words it contains, then by how often
- **Bar:** a difference counts only if a sign test on the paired questions gives p below 0.05 (set in bench/head-to-head.md). **Passed.**
- **What it means:** At this size the index is clearly better than ranked grep. In the session's own terms ctx found the right session for 125 of 139 questions and grep for 71; ctx alone was right on 54 and grep alone on none (p below 0.0001). Where the answer is spread over two or more sessions, ctx found all of them for 27 of 40 questions and grep for 6. On the 32-session corpus the two were level. Paraphrased questions are still poor: 23 of 139, though again well ahead of grep's 5.

| Measure | Result |
| --- | --- |
| ctx, session's own terms | 125 of 139 (one session needed: 98 of 99; two or more: 27 of 40) |
| grep, session's own terms | 71 of 139 (one session needed: 65 of 99; two or more: 6 of 40) |
| ctx, paraphrased | 23 of 139 |
| grep, paraphrased | 5 of 139 |
| Questions only one method got right, own terms | ctx 54, grep 0 |
| Questions only one method got right, paraphrased | ctx 22, grep 4 (p = 0.0005) |

Measured 2026-11-12; check-in 87fb691a8cb2; good until 2027-05-11.

- corpus: the second shipyard corpus: 209 real agent sessions in five streams of work on one codebase over a simulated eight weeks, with vocabulary shared between streams; 139 questions that the repositories, their commit messages and the agents' memory notes do not answer
- freshness: ctx's search was frozen before this corpus existed, and none of its questions was used to tune anything, so all 139 count
- scoring: every session holding the answer among the first five returned; no model involved

```sh
tar -xzf bench/shipyard2/sessions.tar.gz -C DIR && cp bench/shipyard2/questions.json DIR && bench/shipyard.py --data DIR --turns 200
```

[Result file](../bench/results/shipyard2-retrieval.json)

### Coding sessions: finding the session that holds the answer, first run

Each question is asked twice: once in the session's own terms, once paraphrased with none of its distinctive words. Exact terms favour keyword search; paraphrase is where it is weakest.

- **Compared with:** ranked grep over the same transcript files: each session scored by how many of the question's words it contains, then by how often
- **Bar:** a difference counts only if a sign test on the paired held-out questions gives p below 0.05 (set in bench/head-to-head.md before the run). **Not judged.**
- **What it means:** ctx did worse than ranked grep here, 20 against 26 of 30 held-out questions in the session's own terms, and the cause was a fault, not ranking. Questions that name a flag, such as --json, made ctx search stop with an error and return nothing; an agent searching its history for a flag would have hit the same error. The result is kept as it was measured. The next result shows the same questions after the fault was fixed. Paraphrased, both methods fail most of the time.

| Measure | Result |
| --- | --- |
| ctx, session's own terms | 20 of 30 |
| grep, session's own terms | 26 of 30 |
| ctx, paraphrased | 5 of 30 |
| grep, paraphrased | 7 of 30 |
| ctx, all questions, own terms and paraphrased | 48 and 18 of 67 |
| grep, all questions, own terms and paraphrased | 52 and 16 of 67 |

Measured 2026-11-12; check-in 7150d2056fec; good until 2027-05-11.

- corpus: 32 real agent sessions on a public repository over a simulated three weeks, with 67 questions that the repository and its commit messages do not answer
- held out: 30 questions, chosen by a hash of their ids
- scoring: every session holding the answer among the first five returned; no model involved

```sh
bench/shipyard.py --data DIR
```

[Result file](../bench/results/shipyard-retrieval.json)

### Coding sessions: finding the session, after search accepted flag names

Each question is asked twice: once in the session's own terms, once paraphrased with none of its distinctive words. Exact terms favour keyword search; paraphrase is where it is weakest.

- **Compared with:** ranked grep over the same transcript files, and ctx's own result before the change
- **Bar:** a difference counts only if a sign test on the paired held-out questions gives p below 0.05 (set in bench/head-to-head.md before the run). **Not judged.**
- **What it means:** With the fault fixed, ctx finds the right session for 28 of 30 held-out questions in the session's own terms, against grep's 26. ctx alone was right on 3 and grep alone on 1, which is not a difference by the rule set beforehand, so the two are level on this small corpus. Over all 67 questions it is 64 against 52. The change was chosen using only the questions that are not held out, and the held-out ones were run once. Paraphrased questions did not improve: 5 of 30 for ctx and 7 for grep. That is the limit of keyword search, and it is what tools using embeddings should be tested on.

| Measure | Result |
| --- | --- |
| ctx, session's own terms | 28 of 30 |
| grep, session's own terms | 26 of 30 |
| ctx, paraphrased | 5 of 30 |
| grep, paraphrased | 7 of 30 |
| ctx, all questions, own terms and paraphrased | 64 and 18 of 67 |
| grep, all questions, own terms and paraphrased | 52 and 16 of 67 |

Measured 2026-11-12; check-in 4095a7b2dab0; good until 2027-05-11.

- corpus: 32 real agent sessions on a public repository over a simulated three weeks, with 67 questions that the repository and its commit messages do not answer
- held out: 30 questions, chosen by a hash of their ids
- scoring: every session holding the answer among the first five returned; no model involved

```sh
bench/shipyard.py --data DIR
```

[Result file](../bench/results/shipyard-retrieval-after.json)

### Coding sessions: other tools on the same questions

The same held-out questions, given to four other tools that search past agent sessions. Three of them can use embeddings as well as keywords; ctx uses keywords only.

- **Compared with:** ctx on the same questions (28 of 30 in the session's own terms, 5 of 30 paraphrased), with a sign test on the paired questions
- **Bar:** a difference counts only if a sign test on the paired held-out questions gives p below 0.05 (set in bench/head-to-head.md before the run). **Not judged.**
- **What it means:** In the session's own terms every tool that ran properly is level with ctx; only TraceDecay was worse (p = 0.008). Paraphrased, the three tools using embeddings are clearly better than ctx: cass found 23 of 30, episodic-memory 20 and agentmemory 17, against ctx's 5 (each p below 0.001). That is the real gap in ctx's search. It costs them indexing time: one to nineteen minutes for 32 sessions, against seconds for keyword indexes. cass with keywords alone scored 1 of 30 because its default search needs every word of the question to match; that is its default, not its ceiling. This measures finding the session only. In the separate answer test, paraphrasing barely changed what agents got right, because agents rewrite their searches.

| Measure | Result |
| --- | --- |
| cass, keywords and embeddings | 30 and 23 of 30 (own terms and paraphrased; index 67 s) |
| episodic-memory, embeddings | 30 and 20 of 30 (index 584 s) |
| agentmemory, keywords and embeddings | 28 and 17 of 30 (index about 1,120 s) |
| ctx, keywords | 28 and 5 of 30 (index a few seconds) |
| ranked grep | 26 and 7 of 30 |
| agentmemory, keywords | 25 and 10 of 30 (index 14 s) |
| TraceDecay, session search | 20 and 3 of 30 (index 3 s) |
| cass, keywords only | 1 and 0 of 30 (its default requires every word to match) |

Measured 2026-11-12; check-in 4095a7b2dab0; good until 2027-05-11.

- corpus: the shipyard corpus: 32 sessions, 30 held-out questions, each asked in the session's own terms and paraphrased
- tools: each at its defaults and a recorded version, in a container with only the corpus mounted and the network off while searching; commands in bench/shipyard/results/README.md
- scoring: every session holding the answer among the first five distinct sessions returned; no model involved
- versions: cass v0.11.0; episodic-memory 1.6.0 (7e06519); agentmemory v0.9.33; TraceDecay v0.0.74
- not run: claude-mem 15.18.1 cannot load existing transcripts without a model provider, so it is not runnable under this protocol

```sh
bench/shipyard/results/score.py
```

[Result file](../bench/results/shipyard-tools.json)

### Would small embeddings close the paraphrase gap?

ctx finds 5 of 30 paraphrased questions; tools that run a small neural network over every chunk find 17 to 23 and take minutes to index 32 sessions. This asks whether embeddings with no network at all, which index the same corpus in a tenth of a second, get most of that.

- **Compared with:** ctx's keyword search (5 of 30 paraphrased, 28 of 30 in the session's own terms) and the neural tools on the same questions (17 to 23 paraphrased)
- **Bar:** at least 15 of 30 paraphrased questions on tuning-B, with no loss in the session's own terms (set before the run). **Failed.**
- **What it means:** A real gain, but short of the bar. Fusing the 30 MB model with keyword search finds 13 of 30 paraphrased questions instead of 5 (better on 9, worse on 1, p = 0.02) and loses nothing in the session's own terms. That is about half of what the neural tools gain, for almost no indexing cost. The smaller model does less and the larger one no better. ctx does not use embeddings as a result: the bar was not met, and in the answer test paraphrasing did not make agents answer worse, so the gain here may not reach the answers.

| Measure | Result |
| --- | --- |
| ctx keywords | 28 and 5 of 30 (own terms and paraphrased) |
| 30 MB static model fused with keywords | 28 and 13 of 30 (index 0.1 s, 2 MB of vectors) |
| 30 MB static model alone | 27 and 11 of 30 |
| 8 MB static model fused with keywords | 28 and 10 of 30 |
| 129 MB retrieval-tuned static model fused with keywords | 27 and 9 of 30 (alone: 28 and 12) |
| Neural tools, for comparison | 28 to 30 and 17 to 23 of 30 (index 67 to 1,120 s) |

Measured 2026-11-12; check-in 4095a7b2dab0; good until 2027-05-11.

- corpus: the shipyard corpus, first question set; tuning-B is the 30 questions that were held out for the earlier runs
- models: static embedding models from the Model2Vec family: potion-base-2M (8 MB), potion-base-8M (30 MB), potion-retrieval-32M (129 MB). A static model has no network to run; a text's vector is the average of its word pieces' vectors.
- method: vectors for overlapping windows of 64 word pieces of what people and agents wrote, tool output left out; sessions ranked by their best window; fused with ctx's keyword ranking by reciprocal rank
- selection: window size and what to embed were chosen on the 37 tuning-A questions among four variants; tuning-B was looked at twice, so its figures are not a blind test

```sh
bench/vectors.py --models DIR --model potion-base-8M
```

[Result file](../bench/results/vectors-static.json)

### Small embeddings on 209 sessions

On the first corpus, fusing a static embedding model with keyword search found 13 of 30 paraphrased questions instead of 5, and agents answered slightly better with it, though not significantly. This repeats the retrieval test on a corpus six times larger, on questions the method was not chosen with.

- **Compared with:** ctx's keyword search on the same questions (125 of 139 in the session's own terms, 23 paraphrased)
- **Bar:** a difference counts only if a sign test on the paired questions gives p below 0.05 (set in bench/head-to-head.md). **Failed.**
- **What it means:** The gain does not hold. Fused search found 126 and 25 of 139 against 125 and 23 for keywords alone, which is no difference (p = 0.77 on paraphrased questions). The improvement on the small corpus came from its size: with few sessions a rough sense of topic is enough to pick one, and with many sessions on one codebase it is not. ctx does not use embeddings. Tools that run a neural model were not tried at this size.

| Measure | Result |
| --- | --- |
| ctx keywords | 125 and 23 of 139 (own terms and paraphrased) |
| Static model fused with keywords | 126 and 25 of 139 |
| Static model alone | 108 and 22 of 139 |
| Paraphrased questions only one method got right | fused 7, keywords 5 |

Measured 2026-11-12; check-in 87fb691a8cb2; good until 2027-05-11.

- corpus: the second shipyard corpus, 209 sessions and 139 questions, none used for tuning
- method: exactly as chosen on the first corpus: the 30 MB static model over windows of 64 word pieces of what people and agents wrote, fused with ctx's keyword ranking
- cost: 15,206 vectors, 15.6 MB, embedded in one second

```sh
bench/vectors.py --models DIR --model potion-base-8M --data CORPUS --whole
```

[Result file](../bench/results/vectors-static-209.json)

## Agent behaviour

### Coding sessions: do agents answer better with ctx?

An agent is asked each question under four conditions: with only the repository, with the transcript files and ordinary search tools, with ctx and its skill, and with ctx as it is installed (the skill plus the one-line note its session-start hook adds). A correct answer scores 1 and a partly correct one a half.

- **Compared with:** the agent with the transcript files and ordinary tools, and the agent with only the repository
- **Bar:** a difference counts only if a sign test on the paired held-out questions gives p below 0.05 (set in bench/head-to-head.md before the run). **Not judged.**
- **What it means:** Plain transcript files with a hint where they are scored highest. ctx as installed is level with them by the test set beforehand (better on 2 questions, worse on 6, p = 0.29) but three points lower, and ctx without its note is significantly worse (p = 0.04). The whole gap is use: the agent searched with ctx on 24 of 30 questions with the note and 19 without, and where it did search, its answers were as good as the transcript arm's. What ctx buys is cost: about a third fewer tokens, less than half the time, and two or three tool calls where grep needs seven to nine. Paraphrasing the question made almost no difference to any arm, because agents rewrite their own searches. With only the repository the agent could answer 6 of 30, so the questions do need session history.

| Measure | Result |
| --- | --- |
| Transcripts and ordinary tools | 27.0 and 26.5 of 30 (own terms and paraphrased; 7 to 9 tool calls, 15 to 21 s, 796k and 943k tokens) |
| ctx as installed, skill and session-start note | 24.0 and 24.5 of 30 (used ctx on 24 and 26 questions; 2 to 3 tool calls, 6 to 8 s, 540k and 617k tokens) |
| ctx, skill only | 21.5 and 22.5 of 30 (used ctx on 19 and 23 questions; 591k and 616k tokens) |
| Repository only | 6.0 of 30 (own terms; 22 answers of "don't know") |
| Wrong answers, own terms | 1 in every arm |

Measured 2026-11-12; check-in 4095a7b2dab0; good until 2027-05-11.

- corpus: the shipyard corpus; 30 held-out questions, each asked in the session's own terms and paraphrased
- asking: the question alone, with no hint that it is about past work, to a fresh agent per question
- answering model: Claude Sonnet
- grading: Claude Opus, blind, every arm in one shuffled pass
- transcripts arm: its prompt names the folder that holds the transcript files; the ctx arms are told nothing beyond what is listed
- missing arm: the harness's built-in memory alone was not run, because that memory folder was not kept when the corpus was made

```sh
eval/skill_eval.py --bank BANK run --set all --only HELD_OUT --ask plain --cond A,B,C,H && eval/skill_eval.py grade RUNS
```

[Result file](../bench/results/shipyard-answers.json)

### Coding sessions: adding snippets or a reminder to the prompt

Two ways of helping without waiting for the agent to search: put matching snippets in front of it, or remind it to search. Both are hooks that ctx has and does not install by default.

- **Compared with:** ctx as installed, with the skill and the session-start note (24.0 and 24.5 of 30)
- **Bar:** ships only if better than ctx as installed on a paired sign test at p below 0.05, with no more wrong answers (set before the run). **Failed.**
- **What it means:** Neither helps, and both arms scored below ctx as installed, significantly so on paraphrased questions. The reason is that they almost never act: snippets were added for 4 and 3 of 30 questions and the reminder for 1 and 0, so these arms are in effect the skill alone. On the few questions where snippets were added, the answers were right. The session-start note remains the one thing shown to make agents search, and both hooks stay off by default.

| Measure | Result |
| --- | --- |
| Snippets added to the prompt | 19.5 and 19.5 of 30 (own terms and paraphrased; added for 4 and 3 questions) |
| Reminder to search | 20.0 and 18.5 of 30 (given for 1 and 0 questions) |
| ctx as installed, for comparison | 24.0 and 24.5 of 30 |
| Answers when snippets were added | 4 of 4 and 1.5 of 3 |

Measured 2026-11-12; check-in 4095a7b2dab0; good until 2027-05-11.

- corpus: the shipyard corpus; the same 30 held-out questions, in both wordings
- arms: the skill plus snippets from past sessions added to the prompt when its rare words match strongly; and the skill plus a one-line reminder when the prompt refers to earlier work. Neither arm has the session-start note.
- answering model: Claude Sonnet
- grading: Claude Opus, blind, in one shuffled pass with the other arms

```sh
eval/skill_eval.py --bank BANK run --set all --only HELD_OUT --ask plain --cond I,R && eval/skill_eval.py grade RUNS
```

[Result file](../bench/results/shipyard-delivery.json)

### Answering questions about past work

Agents answer questions whose answers exist only in past sessions. Both conditions have ctx and its skill; one also gets the one-line note that the session-start hook adds.

- **Compared with:** the same agent with ctx and its skill but without the session-start note
- **Bar:** score no lower, no more wrong answers, tokens up at most 15%. **Passed.**
- **What it means:** Telling the agent at session start that an archive exists is worth about 7 questions in 90 and costs no extra tokens. The difference is borderline by a sign test (p = 0.052), so it is kept as likely but not proven.

| Measure | Result |
| --- | --- |
| Score with the session-start note | 73.5 of 90 |
| Score with the skill alone | 66.5 of 90 |
| Questions where the note did better | 16 (worse on 6; sign test p = 0.052) |
| New tokens with the note | 7% fewer |

Measured 2026-11-10; good until 2027-02-08.

- questions: 90, written from real sessions in 10 projects and reviewed against the code so that only session history answers them
- source: the author's own session archive; only counts leave it
- answering model: Claude Sonnet, a fresh process per question
- grading model: Claude Opus, blind, both conditions in one shuffled pass

```sh
eval/skill_eval.py run --set all --cond C,H && eval/skill_eval.py grade RUN
```

[Result file](../bench/results/skill-eval.json)

### Reaching for the archive unprompted

Whether rewording the skill's trigger description around agent situations ("before asking the user", "after a compaction") makes agents search more often. It did not, so the wording was left alone.

- **Compared with:** the same skill with its existing trigger wording
- **Bar:** at least 15 points more questions searched. **Failed.**
- **What it means:** Rewording the triggers made no real difference (one question in 23), so the wording was not changed. Fresh agents already search about four times in five without being told.

| Measure | Result |
| --- | --- |
| Searched the archive, existing wording | 18 of 23 |
| Searched the archive, reworded triggers | 19 of 23 |

Measured 2026-11-11; good until 2027-02-09.

- questions: 23 held out, asked plainly with no hint that they are about past work
- source: the author's own session archive; only counts leave it
- answering model: Claude Sonnet

```sh
eval/skill_eval.py run --set holdout --ask plain --cond C [--skill OLD.md]
```

[Result file](../bench/results/reach.json)

### A reminder when a prompt refers to earlier work

ctx recall adds one line telling the agent to search first. Agents already searched every time, so the hook is not installed by default.

- **Compared with:** the same agent without the reminder
- **Bar:** at least 60% searched with it, and more than without. **Failed.**
- **What it means:** The reminder changed nothing because agents already searched every time. The hook exists but is off by default. This test cannot show what happens deep in a long session, where the reminder might matter more.

| Measure | Result |
| --- | --- |
| Searched the archive, with the reminder | 13 of 13 |
| Searched the archive, without it | 13 of 13 |

Measured 2026-11-11; good until 2027-02-09.

- questions: 13 whose wording triggers the reminder ("do you remember", "last time", "didn't we")
- source: the author's own session archive; only counts leave it
- answering model: Claude Sonnet

```sh
eval/skill_eval.py run --set all --only IDS --ask plain --cond C,R
```

[Result file](../bench/results/recall-line.json)

## Rules

### Finding standing instructions in what a person types

A classifier proposes rules from a person's own turns; only the person accepts one. Matching cue words such as "always" and "never" is the baseline.

- **Compared with:** matching cue words such as "always" and "never"
- **Bar:** none; this result describes and was not a test.
- **What it means:** A small model finds about five in six standing instructions; cue words find one in six. About a quarter of what it proposes is not a rule, which is why a person accepts or rejects each proposal.

| Measure | Result |
| --- | --- |
| Claude Haiku | 84% recall, 76% precision |
| DeepSeek | 80% recall, 60% precision |
| Cue words | 17% recall |

Measured 2026-11-10; good until 2027-02-08.

- sample: 1,000 typed turns, each labelled by the person as a standing instruction or not
- source: the author's own session archive; only counts leave it

```sh
eval/rules_bench.py --classify "CMD"
```

[Result file](../bench/results/rules-classifier.json)

### Flagging rules that have gone stale

A judge reads a rule beside the person's recent turns and may flag it only with their own words as evidence. Most stale rules are never contradicted in conversation, so recall is low by design; precision is what matters.

- **Compared with:** the person's own labels of which rules were stale
- **Bar:** no rule that is still true flagged. **Passed.**
- **What it means:** The stronger model never flagged a rule that was still true, so it is the one ctx uses. It finds only a few of the stale rules, because most are never contradicted in conversation; a monthly review covers the rest.

| Measure | Result |
| --- | --- |
| Claude Sonnet | 3 flagged, 3 truly stale |
| Claude Haiku | 9 flagged, 6 truly stale |

Measured 2026-11-10; good until 2027-02-08.

- sample: 42 rules the person labelled as still true or stale
- source: the author's own session archive; only counts leave it
- evidence rule: a flag counts only with a quote found word for word in one of the person's turns

```sh
ctx rules judge-with CMD && ctx rules judge
```

[Result file](../bench/results/rules-judge.json)

### Which kinds of rule go stale

Whether rules should fade by age or by kind. Fading by age quieted about a quarter of rules that were still true, so ctx fades only status notes, 30 days after their file was last written.

- **Compared with:** fading every rule by age
- **Bar:** none; this result describes and was not a test.
- **What it means:** Status notes go stale within weeks and rules in a person's own words rarely do, so ctx fades by kind. Fading by age would have silenced about a quarter of rules that were still true.

| Measure | Result |
| --- | --- |
| Stale, rules in the person's own words | 12% |
| Stale, corrections | 44% |
| Stale, status notes | 83% |

Measured 2026-11-10; good until 2027-02-08.

- sample: 42 labelled rules of three kinds
- source: the author's own session archive; only counts leave it

```sh
bench/rules/decay.py
```

[Result file](../bench/results/rules-decay.json)

## Records

### Holding back a question the archive may answer

A hook that stopped an agent's question once when the person seemed to have answered it before. Most questions agents ask are new decisions, so the hook was removed.

- **Compared with:** the answer the person actually gave each time
- **Bar:** at least 60% holding the answer and at most 10% conflicting. **Failed.**
- **What it means:** The idea failed clearly. Three in four firings were irrelevant and one in twelve pointed at a conflicting answer, so the hook was removed before it shipped.

| Measure | Result |
| --- | --- |
| Questions it would have held back | 18% (133 firings) |
| Firings where the earlier turns held the answer then given | 16% |
| Firings where they held a conflicting answer | 8% |
| Firings that were irrelevant | 76% |

Measured 2026-11-11; good until 2027-02-09.

- method: every question agents had really asked was replayed as of the moment it was asked, and a judge compared the earlier turns it found with the answer the person then gave
- source: the author's own session archive; only counts leave it
- judge: Claude Sonnet

[Result file](../bench/results/ask-replay.json)

### Matching answers to the questions agents asked

ctx reads each question an agent asked and the person's answer from the archived turns. An answer must belong to exactly one question, including when it arrived after midnight or the session was cut off first.

- **Compared with:** a correct record, in which each answer belongs to exactly one question
- **Bar:** no answer shared between questions. **Passed.**
- **What it means:** The record of questions and answers is consistent on a real archive. This checks that answers are attached to the right question, not that they were read correctly word for word.

| Measure | Result |
| --- | --- |
| Answers credited to more than one question | 0 |
| Questions left without a status | 0 |

Measured 2026-11-11; good until 2027-02-09.

- sample: more than 700 recorded questions
- source: the author's own session archive; only counts leave it

```sh
ctx decisions --all
```

[Result file](../bench/results/decisions.json)

## Speed

### Hooks and commands on a real archive, machine heavily loaded

How long an agent session waits for ctx. Hooks run on every session start, compaction and subagent start, so they are held to a 3-second limit and should take a small fraction of it.

- **Compared with:** the 3-second limit Claude Code gives a hook, and the 1-second bar set here
- **Bar:** every hook's slowest run under 1,000 ms. **Failed.**
- **What it means:** At the median every hook takes under 50 ms even with the machine running at three times its capacity. The run failed its bar because the first compaction brief took 1.2 s. A second run on a quiet machine gave the same first-run figure, so that cost belongs to the brief and not to the load.

| Measure | Result |
| --- | --- |
| Session start: rules and archive note | 17 ms (slowest 41 ms) |
| Session start: open tickets | 16 ms (slowest 25 ms) |
| After a compaction: the brief | 48 ms (slowest 1234 ms) |
| Subagent start: archive note | 10 ms (slowest 12 ms) |
| Prompt submitted: recall check | 8 ms (slowest 9 ms) |
| Status line | 9 ms (slowest 21 ms) |
| Search, two words | 148 ms (slowest 491 ms) |
| Read a turn with its neighbours | 12 ms (slowest 22 ms) |
| List decisions | 443 ms (slowest 6318 ms) |
| List published pages | 552 ms (slowest 1631 ms) |

Measured 2026-11-11; check-in 3b1415efd3e0; good until 2027-02-09.

- archive: 1.3 GB, about 470,000 turns
- machine: 14 cores, load average 45 while measuring
- runs: 7 each; the median is reported

```sh
bench/speed.py --runs 7
```

[Result file](../bench/results/speed.json)

### Hooks and commands on a real archive, machine not busy

How long an agent session waits for ctx. Hooks run on every session start, compaction and subagent start, so they are held to a 3-second limit and should take a small fraction of it.

- **Compared with:** the 3-second limit Claude Code gives a hook, and the 1-second bar set here
- **Bar:** every hook's slowest run under 1,000 ms. **Failed.**
- **What it means:** With the machine quiet every hook takes 5 to 35 ms at the median. The compaction brief still failed the bar, at 1.2 s on its first run and about 35 ms after that. The same first-run figure appeared under heavy load, so it is not caused by load: the first brief after a while reads index pages that are no longer in memory. It is inside the 3-second limit, and it is the real cost after a compaction.

| Measure | Result |
| --- | --- |
| Session start: rules and archive note | 8 ms (slowest 12 ms) |
| Session start: open tickets | 7 ms (slowest 8 ms) |
| After a compaction: the brief | 35 ms (slowest 1237 ms) |
| Subagent start: archive note | 6 ms (slowest 7 ms) |
| Prompt submitted: recall check | 5 ms (slowest 5 ms) |
| Status line | 5 ms (slowest 5 ms) |
| Search, two words | 99 ms (slowest 339 ms) |
| Read a turn with its neighbours | 7 ms (slowest 8 ms) |
| List decisions | 531 ms (slowest 3740 ms) |
| List published pages | 383 ms (slowest 746 ms) |

Measured 2026-11-12; check-in 7150d2056fec; good until 2027-02-10.

- archive: 1.3 GB, about 470,000 turns
- machine: 14 cores, load average 9 while measuring
- runs: 7 each; the median is reported

```sh
bench/speed.py --runs 7
```

[Result file](../bench/results/speed-quiet.json)

### Background work

What ctx does away from the session: the hourly scan, the judge's pass over rules, and the one-off rebuild when the index format changes.

- **Compared with:** the same work before an index was added, where shown
- **Bar:** none; this result describes and was not a test.
- **What it means:** Background work costs a few seconds of processor time an hour. The rebuild is a one-off of a few minutes when the index format changes.

| Measure | Result |
| --- | --- |
| Hourly scan, processor time | about 2.5 s (20 to 32 s elapsed on a heavily loaded machine) |
| Choosing rules to judge | 0.12 s (about 140 s before an index was added) |
| One-off index rebuild | 101 to 212 s |

Measured 2026-11-11; good until 2027-02-09.

- archive: 1.3 GB, about 470,000 turns
- machine: 14 cores

```sh
time ctx scan
```

[Result file](../bench/results/background.json)

## Safety

### Fuzzing and sanitizers

Redaction must never crash, must change nothing when run twice, and must leave no secret that a rule recognizes. Every input that ever broke one of these is kept as a seed and replayed on each check.

- **Compared with:** three properties that must always hold for redaction
- **Bar:** none; this result describes and was not a test.
- **What it means:** Fuzzing found a real bug this week, in a rule that could match across a line break. It did not let a secret through. The failing input is now replayed on every check.

| Measure | Result |
| --- | --- |
| Bugs found by fuzzing this week | 1 (a token rule matched across a line break, so redacting twice differed from once; fixed) |
| Saved inputs replayed for redaction | 6 |

Measured 2026-11-11; good until 2027-02-09.

- targets: redaction, transcript extraction, wiki citations, technote parsing, usage statistics
- each check: 20 s of libFuzzer per target under AddressSanitizer and UndefinedBehaviorSanitizer, plus the whole test suite under both

```sh
make check
```

[Result file](../bench/results/fuzzing.json)
