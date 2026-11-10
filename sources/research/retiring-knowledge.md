# Retiring, superseding and decaying knowledge: evidence review

Date: 2026-11-09. Labels: [M] measured study, [P] practitioner report, [O] opinion/spec. "Not fetched" = I did not open the source in this session; claim is from search snippets or prior knowledge. Evidence is thin where stated.

## 1. Supersession models

- **Bi-temporal (XTDB, SQL:2011)** [O/spec]. Two axes: system time (when the DB learned it, immutable) and valid time (when true in the world). XTDB's `_system_from/_to` cannot be modified; valid time can be set only on new versions of a row. https://docs.xtdb.com/intro/data-model , https://docs.xtdb.com/quickstart/control-the-timeline . No measured benefit found; vendor material only. Fit for ctx: check-in = system time (already immutable); "valid time" is the new, optional axis.
- **Zep/Graphiti** [M, authors' own eval, no independent replication found]. Edges get `invalid_at` rather than deletion; bi-temporal (event timeline T vs ingest timeline T'). LongMemEval: up to +18.5% accuracy and ~90% lower latency vs full-context; gains reported in temporal and knowledge-update categories. https://arxiv.org/abs/2501.13956 . Edge-invalidation ablation not found, so the gain cannot be attributed to invalidation specifically.
- **Event sourcing** [P]. Append-only log, state derived by fold; "retire" = a new event. Same shape as ctx check-ins. No measured results sought; well-known pattern.
- **W3C PROV** [O/spec, not fetched]. `prov:wasRevisionOf`, `prov:wasInvalidatedBy`, `prov:invalidatedAtTime`; invalidation is a statement about an entity, not deletion. https://www.w3.org/TR/prov-o/ . Directly usable vocabulary for supersede edges.
- **RFC Obsoletes/Updates; ADR "Superseded by"** [P, not fetched]. Both are one-directional pointers written on the *new* document, with the old one later annotated. RFC distinguishes Obsoletes (replace) from Updates (amend, old still valid). https://www.rfc-editor.org/rfc/rfc7322 . Useful distinction: *replace* vs *amend* are different relations.
- **Retractions** [M]. Crossref took over the Retraction Watch database in 2023, updated each working day (secondary report, not fetched). Flag coverage is inconsistent across Crossref, Retraction Watch, Scopus and Web of Science (union list of 49,924 items; 208 DOIs lost their Crossref retraction flag between Apr 2023 and Jul 2024) (https://arxiv.org/pdf/2012.11475 is a related paper; the union-list figures came via search snippet). Retracted papers keep being cited, often without noting retraction: 46 of 151 cited retracted papers gained post-retraction citations (https://retractionwatch.com/2018/06/27/retracted-papers-keep-being-cited-as-if-they-werent-retracted-two-researchers-suggest-how-elsevier-could-help-fix-that/).
- **Wikipedia** [M]. 1,181 citations to retracted papers on English Wikipedia; median persistence 3.68 years; 71.6% of citations analyzed were "problematic"; correction is faster when a bot flags it; slowest in life/health sciences. Just over half were added before retraction. Authors call the retraction data and the editors' workflow "disconnected". https://arxiv.org/abs/2509.18403 , https://retractionwatch.com/2026/06/18/some-wikipedia-citations-to-retracted-papers-persist-for-years-study-finds/ . {{Outdated}} templates: no measured effect found.

Lesson: a supersede link that lives only on the old record, or that depends on humans noticing, goes stale. Propagation must be computed, not remembered.

## 2. Decay models

- **ACT-R base-level** [M for human memory, O for agent use]. B = ln(sum t_i^-d), d≈0.5, from Anderson & Schooler 1991; both recency and frequency of *use* matter, power-law not exponential. https://dlewissandy.github.io/teaparty/research/act-r/ (secondary). No agent-KB test found.
- **MemoryBank** [P/weak M]. Exponential retention R=e^(-t/S); retrieval bumps S. Evaluated with a chatbot, small human-rated study. https://arxiv.org/abs/2305.10250 . Not evidence that decay improves accuracy.
- **Generative Agents** [M, narrow]. Score = recency + importance (LLM 1-10 at write time) + relevance, each min-max normalised. https://arxiv.org/abs/2304.03442 . The paper ablates whole components (reflection, planning), not each weight; a blog's per-factor numbers were unverified, ignore them.
- **Elasticsearch/Vespa/Google freshness** [P]. ES has gauss/exp/linear decay on date fields multiplied into relevance; decay is on *score*, content untouched. https://www.elastic.co/guide/en/elasticsearch/guide/current/decay-functions.html . Vespa and Google QDF: not searched successfully; no evidence recorded.
- **Half-life of facts** [O/popular, some M]. Arbesman (2012) cites 45 years for cirrhosis/hepatitis clinical knowledge; half-life is per-domain, so one global rate is wrong. Review: https://reason.com/2012/12/24/half-the-facts-you-know-are-probably-wro/printer/ (secondary).
- **FSRS** [P, not searched]. Models memory *of a person*; there is no analog of a source being "reviewed". Scheduling of re-verification is the transferable idea.
- **Letta/MemGPT** [P]. Eviction = move old messages out of context to recall storage plus recursive summary; nothing is deleted, still searchable. https://docs.letta.com/guides/agents/architectures/memgpt . mem0: ADD/UPDATE/DELETE operations; reported LoCoMo temporal J of ~55-58 vs 21.7 full-context (secondary readings, vendor paper) https://arxiv.org/abs/2504.19413 . Note mem0 UPDATE/DELETE destroys history, the opposite of ctx's requirement.

What decays: every system with a good record decays **rank/score or context residency**, not stored content. Decaying content contradicts the provenance goal and nobody reports needing it.

## 3. Temporal retrieval evaluation

- **FreshQA** [M]. All models struggle on fast-changing and false-premise questions regardless of size; search-augmented prompting (FreshPrompt) improved GPT-4 by 32.6 (relaxed) / 49.0 (strict) points; several models can debunk a false premise if asked to check. https://arxiv.org/abs/2310.03214 .
- **LongMemEval** [M]. Long-context LLMs lose 30-60% vs oracle; time-aware indexing and query expansion improved temporal recall ~7-11%. https://arxiv.org/abs/2410.10813 . Per-category numbers for knowledge-update not verified by me.
- **Outdated documents in RAG** [M, preprint/new]. ACL 2026 long.1180 (Re3, Re2 Bench) argues semantic similarity cannot tell obsolete from current versions and reports ~9.7% generation-accuracy gain. I could not read the PDF text; figures are from a search summary. https://aclanthology.org/2026.acl-long.1180.pdf . Also a conflict taxonomy (CONFLICTS benchmark): https://arxiv.org/abs/2506.08500 .
- **Practitioner** [P, one anecdote]: adding timestamps and "prefer recent" to the prompt helped little and produced blended old/new answers; filtering deprecated docs *before* retrieval cut conflicts from 37% to 4%. https://dev.to/faraz_farhan_83ed23a154a2/the-rag-system-that-found-contradicting-answers-and-confidently-picked-the-wrong-one-5elh . Uncontrolled.
- TimeQA, RealTimeQA, StreamingQA: not searched; no numbers given. Evidence on measured damage for *code/doc* KBs specifically: none found.

Which approaches reduce damage: structural filtering/versioning before generation (P, supported by Re3 [M]); time-aware indexing (M, modest). Prompt-only fixes: weak.

## 4. Impact estimation

I found no study that estimates "what breaks if this fact is wrong" for a KB. Evidence is thin; what exists is by analogy:
- Citation/dependency counts as exposure: Wikipedia study suggests exposure (field, whether flagged) predicts correction speed [M]; retracted prestigious papers get *more* post-retraction citations (secondary, search snippet) [M], so high-impact items are the ones that need active repair.
- Wikipedia pending changes / flagged revisions: reduced visible vandalism with little evidence of trade-offs (cited secondhand in https://arxiv.org/abs/2402.17880 ) [M, not verified]. Policy: https://en.wikipedia.org/wiki/Wikipedia:Pending_changes . Vital articles: not searched.
- Reasonable design (my opinion [O]): impact = in-degree in the claim/page graph + retrieval hit count + risk class set by the author (security, API contract, invariant). Use as review *priority*, not as truth.

## 5. Propagation

- **Truth maintenance** [M/classic, only ATMS fetched]. Doyle's JTMS (1979, not fetched) records justifications so retracting a premise withdraws dependents; de Kleer's ATMS (1986) labels each datum with minimal assumption sets so many contexts coexist without retraction. https://www.dekleer.org/Publications/An%20Assumption-Based%20TMS.pdf . Maps directly: claim = datum, source check-in = assumption, quote = justification.
- **Salsa / rustc red-green** [P]. On input change, mark dependents; re-verify; *early cutoff* stops propagation when a recomputed result is unchanged; durability tiers skip checks for rarely-changing inputs. https://rust-analyzer.github.io/blog/2023/07/24/durable-incrementality.html , https://rust.googlesource.com/rust-lang/rustc-dev-guide/+show/refs/heads/main/src/queries/incremental-compilation.md . Bazel: not searched; same idea (change pruning on content hash).
- Design implication [O]: when source S is superseded by S', don't invalidate dependents blindly; re-check each quote against S'. If the quote still occurs verbatim, early-cutoff: claim stays green with a new pin. Only quote misses go red. Cheap and exact for a literal-quote system.
- Real-world propagation is poor: see Wikipedia and Crossref above.

## 6. Failure modes

- **LLMs ignoring stale/retracted labels** [M, narrow]. ChatGPT given 217 retracted/problematic articles: none of 6,510 reports mentioned retraction (Thelwall et al., via https://www.sheffield.ac.uk/ijc/news/new-research-suggests-chatgpt-ignores-article-retractions-and-errors-when-used-inform-literature , secondary). 21 chatbots identified fewer than half of retracted papers, and repeat runs disagreed (https://retractionwatch.com/2025/11/19/ai-unreliable-identifying-retracted-research-papers-study ). These test *parametric* knowledge, not a label present in retrieved text. I found **no direct measurement** of whether models honor an inline "superseded" banner. Practitioner anecdote above says prompts alone are unreliable. Evidence thin; ctx should measure this itself.
- **Recency bias** [M, preprint]. Prepending a date to passages moved newer ones up in all 7 LLM rerankers tested; top-10 mean year up to +4.78; pairwise preference flipped up to 25% of the time; larger models more robust. https://arxiv.org/abs/2509.11353 . So dates in text are a bias source; keep status out of prose and in structure.
- **Decay hiding valuable old knowledge** [O]: the same preprint says authoritative old content is undervalued. No KB-specific measurement.
- **Over-deleting** [P]: mem0-style DELETE loses history; Letta keeps recall storage. Not measured.
- **Failure of flags** [M]: Crossref flags disappeared for 208 DOIs; Wikipedia correction tied to bots. A retirement signal needs an owner and an audit.

## Design-relevant summary

1. Never decay content; decay retrieval rank only, and keep a "pinned/evergreen" override. [practice-consistent; no direct measurement]
2. Filter/retarget superseded sources structurally before the model sees them; do not rely on labels in text. [P + early M]
3. Compute propagation with early cutoff on quote re-verification. [P by analogy]
4. Distinguish Replaces vs Amends vs Retracts (RFC, PROV). [O/spec]
5. Rate varies by domain; make half-life a per-page/class field, not global. [weak M]
