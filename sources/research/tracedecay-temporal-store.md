# TraceDecay: temporal store study

Paths relative to the clone `td.Xnn88w/r`. `STS` = `crates/tracedecay-session-temporal-store/src`.

## Headline
The temporal store has no decay. The only decay in the repo is a ranking multiplier in a different crate (the memory fact store). The "freshness" claim in the README is a daemon/generation mechanism, not a quote-pinning one.

## Data model: valid time and recorded time
- Two time fields exist. `knowledge_at` is recorded/knowledge time. `valid_time_json` is valid time. Both are on occurrences and assertions (`STS/schema_constants.rs:265,292`).
- Valid time is only `Known{valid_at}` or `Unknown`. It is a single instant, not an interval: no `valid_to` and no end marker (`crates/tracedecay-domain/src/session/occurrence.rs:382-385`).
- Four query modes: Current, AsOf{cutoff}, Evolution, Forensic (`occurrence.rs:259-264`).
- `as_of` is strict. It requires `knowledge_at <= cutoff` and `valid_at <= cutoff`, and excludes Unknown valid time (`occurrence.rs:392-400`; same predicate in SQL at `STS/expand.rs:429-440`).
- Assertion kinds are Corrects, Supersedes, Contradicts, Supports (`occurrence.rs:748-753`). Assertions are append-only and generation-scoped.

## Supersession
- It is derived, not authored. `STS/projection/persist.rs:1361-1407` computes a transitive closure into `session_assertion_supersession(superseded, superseding, created_at)`.
- A new assertion supersedes a prior one only when both are Corrects or Supersedes, both have Known valid time, and the new one's `subject_anchor` equals the old one's `object_anchor`. Order is by `valid_at`, then `knowledge_at`, then `assertion_id`. Ties are broken deterministically.
- Current mode is "assertions with no row in the supersession table" (`expand.rs:441-451`). Nothing is deleted. Contradicts and Supports never supersede.

## What decays
- Nothing in the temporal store. `grep -w decay` finds only ranking-score text elsewhere.
- Memory fact search, a separate crate, uses `score = (0.4*fts + 0.3*jaccard + 0.3*holographic) * trust * temporal_decay * usage_boost` (`docs/RETRIEVAL-QUALITY-EVAL.md:~105-125`).
  - `temporal_decay = 0.5^(age_days/365)`, clamped to [0.10, 1.0], computed from `updated_at` at query time (`crates/tracedecay-session-memory/src/fact_store/scoring.rs:269-276`).
  - Nothing is persisted or deleted. `trust_score` never decays on its own (`docs/TRUST-DECAY-SEMANTICS.md:22-30`).
  - `usage_boost` is `1 + min(0.02*ln(1+n), 0.5)`.
- Evidence for the parameters: only unit tests of the formula at the boundaries (`scoring.rs:432-435`). There is no tuning data or benchmark behind the 365-day half-life, the 0.10 floor or the weights.
- Supersession does not touch ranking. `evals/memory/scenarios/memory-ranking-supersession.json` pins that a superseded fact can still outrank its replacement, and states that this is today's behaviour and a known risk.

## Invalidation and propagation
- Raw-source revision marks dependent summaries stale: `UPDATE session_summary_availability SET availability='stale', reason='raw_source_revised'` (`STS/operations/generation.rs:136-139`).
- Summaries whose predecessor was superseded are marked `stale` with reason `predecessor_superseded` (`generation.rs:483-489`).
- Propagation follows a lineage closure over `predecessor_summary_id` and the `canonical_sources` of kind summary (`STS/relation_projection.rs:639-660`).
- Stale nodes stay in the graph. Availability selects retrieval roots, not membership.
- A doctor check flags spurious stale state: stale without a supersession (`STS/doctor_health/relation_health.rs:280-285`).

## Freshness and provenance
- The state is `SessionDataFreshness` = Fresh | Stored{generation_lag} | Partial{generation_lag}, derived from a source-coverage receipt (`STS/execution.rs:464-481`).
- Every projection is an immutable numbered generation. Receipts carry row-multiset digests, for example `supersession_count` and `supersession_digest` (`STS/projection/receipts.rs:81,131`).
- Queries bind to a generation and report lag. They never sync silently.
- The README claim of "repository, worktree, ref, commit, generation" provenance (README.md:28, 176-195) is for the code index and is implemented in the daemon, outside this crate. This crate carries generations and receipts, not commits.
- Doctor is read-only diagnosis (`STS/doctor_health.rs:1-4`).

## Evals
- `benchmark_data/session-temporal/` is a latency harness only (rebuild_activate, exact_replay, compact_rank, late_hydrate; 30 reps).
- `result-provisional.json` is labelled `acceptance_eligible: false` and `historical_stale`.
- There is no temporal-correctness or retrieval-quality eval. No as-of accuracy, no supersession precision and no decay ablation.

## Worth borrowing
1. Two timestamps on every claim: when it was recorded and when it was true. Strict as-of rule: both must be at or before the cutoff, and unknown valid time is excluded rather than assumed.
2. Append-only claims plus a derived supersession relation. "Current" is a pure query, and history is never deleted. For the wiki, that is "latest pinned check-in wins".
3. A deterministic total order for tie-breaks: valid time, recorded time, id.
4. Stale-with-reason propagation. When a source check-in changes, mark dependents stale with a reason code and keep them. This matches pinned-source claims directly.
5. A cheap health lint for contradictory state, such as stale without a cause.
6. Typed freshness states reported on every answer, with lag as an integer.

## Over-built or oversold
- Generation, receipt and digest machinery, cursors, participant freeze and signed cursor keys: this is distributed-consistency machinery for a daemon. A version-pinned check-in already gives immutability and identity.
- Transitive closure materialized in SQL: for a wiki, a single `supersedes` pointer per claim suffices.
- The name "decay": the multiplicative half-life decay is a ranking heuristic with no evidence, and the temporal store has none. Do not copy decay. A pinned quote is either true at its check-in or not.
- "Supersession" does not affect memory ranking, by the project's own test.
- The README's "exact provenance" is a code-index freshness claim and does not cover claim-level quote checking. You would still need to hash and compare the quoted span against the pinned source yourself.
