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
| Answering questions about past work | Passed its bar | Telling the agent at session start that an archive exists is worth about 7 questions in 90 and costs no extra tokens. The difference is borderline by a sign test (p = 0.052), so it is kept as likely but not proven. |
| Reaching for the archive unprompted | Failed its bar | Rewording the triggers made no real difference (one question in 23), so the wording was not changed. Fresh agents already search about four times in five without being told. |
| A reminder when a prompt refers to earlier work | Failed its bar | The reminder changed nothing because agents already searched every time. The hook exists but is off by default. This test cannot show what happens deep in a long session, where the reminder might matter more. |
| Finding standing instructions in what a person types | No bar | A small model finds about five in six standing instructions; cue words find one in six. About a quarter of what it proposes is not a rule, which is why a person accepts or rejects each proposal. |
| Flagging rules that have gone stale | Passed its bar | The stronger model never flagged a rule that was still true, so it is the one ctx uses. It finds only a few of the stale rules, because most are never contradicted in conversation; a monthly review covers the rest. |
| Which kinds of rule go stale | No bar | Status notes go stale within weeks and rules in a person's own words rarely do, so ctx fades by kind. Fading by age would have silenced about a quarter of rules that were still true. |
| Holding back a question the archive may answer | Failed its bar | The idea failed clearly. Three in four firings were irrelevant and one in twelve pointed at a conflicting answer, so the hook was removed before it shipped. |
| Matching answers to the questions agents asked | Passed its bar | The record of questions and answers is consistent on a real archive. This checks that answers are attached to the right question, not that they were read correctly word for word. |
| Hooks and commands on a real archive | Failed its bar | At the median every hook takes under 50 ms, far inside its limit. The run failed its bar because one compaction brief took 1.2 s on a machine running at three times its capacity; the slowest runs are the ones to watch. |
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

## Agent behaviour

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

### Hooks and commands on a real archive

How long an agent session waits for ctx. Hooks run on every session start, compaction and subagent start, so they are held to a 3-second limit and should take a small fraction of it.

- **Compared with:** the 3-second limit Claude Code gives a hook, and the 1-second bar set here
- **Bar:** every hook's slowest run under 1,000 ms. **Failed.**
- **What it means:** At the median every hook takes under 50 ms, far inside its limit. The run failed its bar because one compaction brief took 1.2 s on a machine running at three times its capacity; the slowest runs are the ones to watch.

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
