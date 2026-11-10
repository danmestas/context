# LLM-compiled wiki: build and maintenance methods (researched 2026-11-09)

Evidence grades: **[M]** measured study, **[P]** practitioner report, **[O]** opinion or vendor. Sources I fetched are marked (read); the rest are search-snippet level only and should be re-checked before anyone cites them.

## Headline
Nobody has measured long-term maintenance of an LLM wiki. Every maintenance control below is **[P]/[O]**. The measured evidence covers only one-shot comparisons and citation verification, and it is small.

## 1. Page structure and types
- Karpathy's gist (April 2026, read): three layers. Raw sources are immutable and the LLM never edits them. The wiki is LLM-owned markdown. A schema file (CLAUDE.md or AGENTS.md) sets conventions. Page types are source summary, entity, concept, comparison, overview, plus `index.md` (a categorized catalog, read first) and `log.md` (append-only, greppable `## [date] op | title` lines). One ingest typically touches 10-15 pages. [O/P] https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- He says the index works "surprisingly well" at about 100 sources and hundreds of pages, and suggests adding search (qmd: BM25 + vector + rerank) beyond that. Scale threshold is his own report. [P]
- Granularity guidance beyond the gist is thin. Practitioner guides recommend one concept per page, aliases in front matter, and splitting pages that mix meanings (Glukhov, read, undated): https://www.glukhov.org/knowledge-management/knowledge-systems-architectures/compiled-knowledge/llm-wiki-maintenance-knowledge-drift/ [P]
- Front matter fields recommended there: `status` (current/historical/superseded/draft/uncertain), `review_after`, `last_reviewed`, source type and access date, `superseded_by` with reason. [P]
- CodeWiki (arXiv 2510.24428, ACL Findings 2026): hierarchical module decomposition of repos. It scores 68.8% vs DeepWiki's 64.1% on its own rubric benchmark, but trails on C/C++ (53.2% vs 56.4%). The human check had three participants. Nothing on staleness or hallucination. [M, weak] https://arxiv.org/abs/2510.24428 . Relevant to us: the C-code result is a warning.

## 2. Compilation and change propagation
- Gist and community skills do incremental ingest, one source at a time, with a human watching. There is no automatic "which pages does this changed source affect" mechanism in any source I found. [P]
- The only dependency-tracking idea I found is date-based: flag sources newer than a page's `last_reviewed`. Glukhov explicitly lacks source-hash staleness; you would build it. [P]
- Related index-maintenance literature: EraRAG reports selective re-clustering cuts update tokens by up to 57.6% against RAPTOR, and rebuild time by 77.5% on QuALITY. Authors' own experiments. It notes GraphRAG re-clusters fully on update. [M, self-reported] https://arxiv.org/pdf/2506.20963 . LightRAG claims incremental update without full rebuild, but the cost figures circulating come from blogs. [O]
- Design implication (my inference, not evidenced): record, per page, the (source id, content hash) pairs it was compiled from. Changed hash then gives the affected set exactly, with no LLM. No source tested this.

## 3. Maintenance operations
All **[P]/[O]**. Glukhov's split is the most concrete:
- Structural lint, deterministic: broken links, orphans, duplicate titles/aliases, empty sections, invalid front matter, pages past `review_after`. Safe to auto-fix: link fixes, index entries, backlinks.
- Semantic lint, report-only: claims without source support, cross-page contradictions, old decisions presented as current, unlabeled version-specific claims. Not auto-rewritten.
- Gist adds: contradictions are flagged at ingest, and lint finds claims superseded by newer sources. It never says how conflicts get resolved.
- Supersession: keep the old page or claim with `status: superseded` and a pointer, not deletion. Zep/Graphiti does the same at fact level, with edges carrying validity windows and bi-temporal timestamps, so old facts are invalidated, not overwritten. Mechanism documented, but accuracy claims are vendor self-reports (LongMemEval: Zep 63.8% independently measured vs Mem0 49.0% per one aggregator, while Mem0 self-reports 94.4). https://blog.getzep.com/state-of-the-art-agent-memory/ [O]
- Warning: "LLMs often remove details while smoothing prose," so review deletions in diffs (Glukhov). [P]
- I found nothing on merge/split or dedupe beyond title/alias checks.

## 4. Provenance and citation
- Gist: provenance is only "raw sources are immutable plus cited answers plus the log." No span or version pinning. [O]
- Claim-level locators beat file-path citations; a wiki `status` field describes synthesis maturity, not truth. A single repo review makes this point. [P] https://github.com/hiennguyen9874/llm-wiki/issues/3
- CAMS "Attributable by Construction" (arXiv 2606.23989, Jun-Sep 2026, read): extract claims from sources, resolve quotes to token spans deterministically, then write summaries whose every sentence ends in claim IDs. Multi-source attribution accuracy rose 38% to 64%, human verification time per claim fell 3.4x. Evaluated on news summarization only. The span being a literal quote makes provenance checkable by string match, independent of model accuracy. [M] https://arxiv.org/abs/2606.23989 . This is the closest match to "pin to source version and span."
- Faithfulness checking is weak. Judge agreement with humans on claim support was 50-54%, rising to 65-69% after a bug fix, in the wiki-vs-RAG study (below). [M] LLM judges tested on 624 deep-research citation pairs were indistinguishable on factual support, so choosing a bigger model does not help (arXiv 2607.08700). [M] Legal-citation recall on hard cases was 37-61% (arXiv 2608.12571). [M] Conclusion: do not rely on an LLM verifier as the gate. A literal-quote-exists check is cheap and reliable; entailment checking is advisory.
- Source change: a claim can be attributable at one date and stale at the next (reliablecontext.com claim-level guide, [O]). With a pinned content hash and a stored quote, the check "does the quote still appear in the current version" is deterministic. I found no system that does this for wikis.
- Wikipedia practice (mirrors only, verify at en.wikipedia.org): LLM output may hallucinate references, so editors must verify each source exists and supports the text; unreviewed LLM pages are speedy-deletable (G15); LLM-from-scratch articles are discouraged. [P] Relevant: human verification of citations is the community's answer.

## 5. Retrieval and wiki vs raw
- Vector RAG vs compiled wiki, preregistered (arXiv 2605.18490, v3 Oct 2026, read): 24 papers, 13 questions, one model, two LLM judges. Wiki gave better cross-paper synthesis but below the preregistered threshold when judges were combined. RAG won single-fact groundedness, judge-sensitive. The wiki used about 21x more LLM tokens per query, "no break-even point exists." A decomposition-RAG variant recovered most of the synthesis gap more cheaply. The wiki's apparent citation advantage was a scorer truncation artifact. **Strongest negative result found.** [M, small] https://arxiv.org/abs/2605.18490
- Positive result: "Retrieval as Reasoning" (arXiv 2605.25480, May 2026): agent navigating a wiki beats HippoRAG 2, LightRAG, GraphRAG by 2.0-8.1 F1 on HotpotQA/MuSiQue/2Wiki (abstract only read). It reads 2.5-3.9 pages per query. Authors built the system; per-dataset numbers not verified. [M, author-reported] https://arxiv.org/abs/2605.25480
- These two disagree on tokens (21x worse vs fewer pages read). Likely cause is wiki size and navigation tooling; unresolved.
- Practitioner reports: compiled wikis win on small curated corpora; RAG wins on larger raw ones; a thresholds claim of about 100-200 articles has no benchmark behind it. [O] https://www.mindstudio.ai/blog/llm-wiki-vs-rag-knowledge-base
- I found no measured study of GraphRAG/RAPTOR vs wiki on code corpora, and no head-to-head evaluation of DeepWiki accuracy for coding agents.
- Index-first vs search: only the gist's own claim. No comparison found. Hybrid (index plus search tool) is the common recommendation. [P]

## 6. Failure modes and controls
- Error cascade: one wrong summary propagates into several cited pages (one six-week anecdote). Control: weekly lint. [P] https://youcanbuildthings.substack.com/p/llm-wiki-maintenance-one-wrong-summary (snippet only)
- Drift types: source drift, citation drift, structure drift, orphan accumulation, silent entity contradictions, paraphrase over-simplification. [P]
- Hallucination laundering and self-citation: the wiki is an LLM summary, and if a later ingest or query cites a wiki page as if it were a source, errors become "sourced." Controls (design inference, not measured): sources and wiki live in separate stores; citations may point only at source spans; wiki-to-wiki links are navigation, not evidence; filing query answers back (gist) needs an `origin: synthesis` flag.
- Model collapse (Shumailov, Nature 2024) shows recursive training on model output loses distribution tails. Applies to training, not to a wiki, so it is an analogy only. [M, indirect]
- Unbounded growth: the 21x token result suggests cost is real. Controls: page size caps, archive status, and a budget per query. Evidence thin. [O]

## 7. Human review
- Practitioner tiering (Glukhov): human required for deleting claims, rewriting canonical pages, resolving contradictions, marking superseded, and security/legal/pricing/benchmark claims. Recommended for new concept pages and merges. Not needed for link and index fixes. [P]
- Cheapening review: CAMS cut verification time 3.4x by presenting claim, quote, and span side by side. [M] Small operation-named commits and diff review keep review atomic. [P] Review queues (stale, contradictions, recent ingests) as generated pages. [P]
- Wikipedia's experience says unreviewed LLM text is the thing that gets deleted. [P]

## Where evidence is thin
Long-run maintenance; change propagation; merge/split; span-pinned citation in wikis; wiki vs raw on code. Everything above on these is reasoning from adjacent work.

## Other sources
Karpathy-gist derivatives: https://zby.github.io/commonplace/sources/karpathy-llm-wiki.ingest/ ; Graphiti overview https://blog.getzep.com/state-of-the-art-agent-memory/ ; judge benchmark https://arxiv.org/abs/2607.08700 ; Shumailov https://www.pure.ed.ac.uk/ws/portalfiles/portal/460496122/ShumailovEtalNature2024AIModelsCollapseWhen.pdf . Letta and RAPTOR staleness: searches returned nothing usable.
