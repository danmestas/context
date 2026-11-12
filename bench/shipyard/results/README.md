# Head-to-head retrieval results on shipyard-v1

Run on 2026-11-12, on an arm64 macOS host with Docker Desktop 28.2.2 (linux/arm64 containers,
`--cpus 4 --memory 4g`). The host was heavily loaded throughout (load average 30 to 100), so the
times are upper bounds and not comparable with times taken on a quiet machine.

Each arm file `<arm>.json` holds, for every question in both wordings, the first 10 distinct
session ids the tool returned, in rank order. `score.py` prints the same table as
`bench/shipyard.py`: `python3 score.py`.

Every tool was fetched, installed and run inside a container. The only host mount was
`sessions/` read-only at `/corpus`. No API key, token or host environment was passed. The
query file given to the tools held only `id`, `question` and `paraphrase`.

```sh
S=/path/to/shipyard-v1/sessions
python3 -c "import json;q=json.load(open('questions.json'));json.dump([{k:x[k] for k in ('id','question','paraphrase')} for x in q],open('queries.json','w'))"
```

Runner scripts are reproduced at the end of this file. Each runs one search per question and
wording, keeps the first occurrence of each session, and records the first 10.

## Scores

Every gold session in the first five / at least one, from `score.py`:

| Arm | question, all 67 | question, held out 30 | paraphrase, all 67 | paraphrase, held out 30 |
|---|---|---|---|---|
| cass-lexical | 1 / 2 | 1 / 1 | 0 / 0 | 0 / 0 |
| cass-hybrid | 63 / 65 | 30 / 30 | 48 / 52 | 23 / 24 |
| episodic-memory | 66 / 67 | 30 / 30 | 44 / 49 | 20 / 22 |
| agentmemory-bm25 | 59 / 63 | 25 / 28 | 21 / 25 | 10 / 11 |
| agentmemory-hybrid | 65 / 66 | 28 / 29 | 34 / 41 | 17 / 18 |
| tracedecay | 48 / 53 | 20 / 23 | 7 / 9 | 3 / 4 |

## cass (coding_agent_session_search) v0.11.0

Release binary `cass-linux-arm64.tar.gz` from the v0.11.0 release (checksum file fetched
alongside).

```dockerfile
FROM debian:bookworm-slim
LABEL h2h=1
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates jq python3 && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && curl -fsSLO https://github.com/Dicklesworthstone/coding_agent_session_search/releases/download/v0.11.0/cass-linux-arm64.tar.gz \
 && tar xzf cass-linux-arm64.tar.gz && find . -name cass -type f -exec install -m755 {} /usr/local/bin/cass \; && rm -rf /tmp/* && cass --version
ENV HOME=/root
```

### cass-lexical (no semantic model)

```sh
docker build --label h2h=1 -t h2h-cass cass
docker run -d --label h2h=1 --name h2h-cass-lex --network none --cpus 4 --memory 4g -v $S:/corpus:ro h2h-cass sleep 7200
docker exec h2h-cass-lex bash -c 'mkdir -p ~/.claude/projects/-bench-shipyard && cp -r /corpus/. ~/.claude/projects/-bench-shipyard/ && cd ~ && cass index --full --json'
docker cp run_cass.py h2h-cass-lex:/run_cass.py; docker cp queries.json h2h-cass-lex:/queries.json
docker exec h2h-cass-lex bash -c 'cd ~ && python3 /run_cass.py /queries.json'
```

Query: `cass search "<question>" --robot --robot-meta --fields summary` (default mode,
default limit). Index: 32 conversations, 709 messages, 2.2 s, 22 MB. Network off for the whole
run. Every query reported `search_mode: lexical` with fallback reason "consent required for
model download".

The default lexical match needs every query term, so a whole question as typed returned hits
for only 4 of the 134 queries. cass suggests a wildcard rewrite in its response; that was not
run, because the protocol is the question as typed at defaults. This arm measures cass's
default behaviour on natural-language questions, not what its index can find with keyword
queries.

### cass-hybrid (all-minilm-l6-v2)

```sh
docker run -d --label h2h=1 --name h2h-cass-hyb --cpus 4 --memory 4g -v $S:/corpus:ro h2h-cass sleep 7200
docker exec h2h-cass-hyb bash -c 'mkdir -p ~/.claude/projects/-bench-shipyard && cp -r /corpus/. ~/.claude/projects/-bench-shipyard/ && cd ~ && cass models install -y && cass index --full --semantic --json'
docker network disconnect bridge h2h-cass-hyb
docker exec h2h-cass-hyb bash -c 'cd ~ && python3 /run_cass.py /queries.json'
```

Model install 5.8 s, index 67 s (1220 vectors), 115 MB of which the model is 91 MB. Network on
for model download and indexing, off for the queries. Every query reported
`search_mode: hybrid`, `fully_hybrid_refined`.

## episodic-memory, commit 7e06519357777badd7a115d2014a7ef845904310 (package 1.6.0)

```dockerfile
FROM node:22-bookworm
LABEL h2h=1
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates python3 build-essential sqlite3 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/obra/episodic-memory /opt/episodic-memory \
 && cd /opt/episodic-memory && git rev-parse HEAD && npm install --no-fund --no-audit && npm link
ENV HOME=/root EPISODIC_MEMORY_SKIP_SUMMARIES=1
```

```sh
docker build --label h2h=1 -t h2h-em em
docker run -d --label h2h=1 --name h2h-em-run --cpus 4 --memory 4g -e EPISODIC_MEMORY_SKIP_SUMMARIES=1 -v $S:/corpus:ro h2h-em sleep 7200
docker exec h2h-em-run bash -c 'mkdir -p ~/.claude/projects/-bench-shipyard && cp -r /corpus/. ~/.claude/projects/-bench-shipyard/ && cd ~ && episodic-memory sync'
docker network disconnect bridge h2h-em-run
docker exec h2h-em-run bash -c 'cd ~ && python3 /run.py /queries.json'      # run_em.py
```

Query: `episodic-memory search "<question>"` (documented CLI; default mode is vector plus
text, limit 10). Sync indexed 32 conversations as 55 exchanges: one exchange is a user prompt
with the assistant work that followed, so a session with two prompts is two documents. Sync
took 584 s including the download of Xenova/bge-small-en-v1.5, on the loaded host. Index 2.0 MB
plus a 6.3 MB archive copy of the transcripts. Each search loads the model (4.3 s mean).
Network on for sync, off for queries. No summaries, no model provider.

## agentmemory v0.9.33, commit 3e48fcb533baaf026cdf8ba371c9f1f0d5f1f03e

Built from the repository's own `deploy/Dockerfile` (base `node:24-slim`, iii engine 0.25.1
copied from `iiidev/iii:0.25.1`), from a `git clone --depth 1` made inside a container.

```sh
docker build --label h2h=1 -t h2h-am -f deploy/Dockerfile .      # in the shallow clone
```

### agentmemory-bm25 (keyless)

```sh
docker run -d --label h2h=1 --name h2h-am-bm25 --cpus 4 --memory 4g -v $S:/corpus:ro h2h-am
# wait for http://127.0.0.1:3111/agentmemory/livez inside the container
docker exec -u node h2h-am-bm25 sh -c 'mkdir -p $HOME/.claude/projects/-bench-shipyard && cp -r /corpus/. $HOME/.claude/projects/-bench-shipyard/ && cd /opt/agentmemory && node dist/cli.mjs import-jsonl'
docker network disconnect bridge h2h-am-bm25
docker cp run_am.mjs h2h-am-bm25:/tmp/run.mjs; docker cp queries.json h2h-am-bm25:/tmp/queries.json
docker exec -u node h2h-am-bm25 node /tmp/run.mjs /tmp/queries.json
```

Query: `POST /agentmemory/search` with body `{"query": "<question>"}` and the server's own
bearer secret (this is `mem::search`, the path behind the `memory_recall` tool and the one the
project's own evaluation adapter calls). The default returns 20 observations. Status reported
"Embeddings: bm25-only" and "Provider: noop". Import: 32 files, 709 observations, 13.7 s; state
store 1.5 MB. A server is required; its first start downloads two pinned workers from the iii
registry, so the network was on for startup and import and off for the queries.

### agentmemory-hybrid (EMBEDDING_PROVIDER=local)

```sh
docker run -d --label h2h=1 --name h2h-am-hyb --cpus 4 --memory 4g -e EMBEDDING_PROVIDER=local -v $S:/corpus:ro h2h-am
# same copy, import-jsonl, disconnect and query steps as agentmemory-bm25
```

The one change is `EMBEDDING_PROVIDER=local` (on-device Xenova/all-MiniLM-L6-v2, downloaded at
the first embedding). Status reported "Embeddings: local (384 dims)", "Provider: noop".

`import-jsonl` printed "import timed out after 2 minutes", which is the CLI's own request
timeout, and the worker reconnected to the engine once. The server went on importing: `status`
showed 9 sessions after about 5 minutes and all 32 sessions and 709 observations about 19
minutes after start (host at load 60 to 100). `index_seconds` (1120) is that wall time. State
store 3.1 MB. Network on for startup and import, off for the queries.

The first query after the network was cut exceeded the runner's 120 s limit while the model
loaded. The whole set was run again and the second run is the one recorded; 133 of the 134
rankings were identical between the two runs, the exception being that first query.

## TraceDecay v0.0.74

Release archive `tracedecay-v0.0.74-aarch64-linux.tar.gz`, checked against the release's
`SHA256SUMS`.

```dockerfile
FROM debian:bookworm-slim
LABEL h2h=1
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates jq python3 git procps && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && curl -fsSLO https://github.com/ScriptedAlchemy/tracedecay/releases/download/v0.0.74/tracedecay-v0.0.74-aarch64-linux.tar.gz \
 && curl -fsSLO https://github.com/ScriptedAlchemy/tracedecay/releases/download/v0.0.74/SHA256SUMS \
 && grep aarch64-linux SHA256SUMS | sha256sum -c - && mkdir x && tar xzf tracedecay-*.tar.gz -C x && install -m755 x/tracedecay /usr/local/bin/tracedecay && rm -rf /tmp/*
ENV HOME=/root
```

```sh
docker build --label h2h=1 -t h2h-td td
docker run -d --label h2h=1 --name h2h-td-run --network none --cpus 4 --memory 4g -v $S:/corpus:ro h2h-td sleep 7200
docker exec h2h-td-run bash -c '
  mkdir -p /private/tmp/shipyard/ctx ~/.claude/projects/-private-tmp-shipyard-ctx
  cp -r /corpus/. ~/.claude/projects/-private-tmp-shipyard-ctx/
  cd /private/tmp/shipyard/ctx && git init -q -b main . && echo "# ctx" > README.md
  git -c user.email=bench@example.invalid -c user.name=bench add -A
  git -c user.email=bench@example.invalid -c user.name=bench commit -qm init
  tracedecay init
  (nohup tracedecay daemon run > /tmp/daemon.log 2>&1 &)
  until [ -S ~/.tracedecay/daemon.sock ]; do sleep 1; done
  tracedecay sessions ingest'
docker exec h2h-td-run python3 /run.py /queries.json                      # run_td.py
```

Sessions are stored per project, and a project is a git repository registered with
`tracedecay init`. The transcripts record their working directory as `/private/tmp/shipyard/ctx`,
so a stub repository (one README) was created at that path and the transcripts were placed in
the Claude Code folder for that path. The daemon picked up some sessions itself when it started
and `sessions ingest` took the rest: 32 sessions, 623 messages. Init plus ingest 3.3 s, 26 MB
(including the code index of the stub repository). Network off for the whole run.

Query: the documented `tracedecay sessions search "<q>"` fails in this release at its defaults
("since must be a non-negative Unix timestamp ..."), so the queries went through its documented
twin, `tracedecay tool message_search --args '{"query": "<q>"}'`, with no other argument
(10 messages, catch-up on). 41 of 134 queries returned nothing.

## What did not run

### claude-mem (not run, by design)

Version read: 15.18.1, commit c4a9f5725f420bf9c6e866cdd3b94bd36498af09 (shallow clone inside a
container; source read only, nothing executed).

Can it import existing transcript files without a model provider? No.

- The only model-free import is `claude-mem memory ingest`, which imports Claude Code's
  auto-memory notes (`~/.claude/projects/<cwd>/memory/*.md`). `docs/public/usage/memory-ingest.mdx`
  says: "Only the memory notes are imported. A sibling transcript is read for its `cwd`, to key
  the project like live capture does; its content is never ingested."
- Transcript content reaches the store only as observations written by an observer model.
  `src/services/transcripts/` holds a transcript watcher (used for Codex subagents and Grok Bot),
  and `processor.ts` hands each event to `ingestObservation`; `docs/public/configuration.mdx`
  describes that capture as "one more request to your observer provider", and
  `CLAUDE_MEM_PROVIDER` must be one of `claude`, `codex`, `gemini`, `openrouter`,
  `openai-compatible`. There is no keyless provider, and the watcher ships no schema for Claude
  Code transcripts (`SAMPLE_CONFIG.schemas` is empty; Claude Code is captured by live hooks).

So claude-mem is not runnable under this protocol.

## Things that are unfair, in either direction

- cass-lexical: zero hits on 130 of 134 whole-sentence queries is a property of its default
  query parser (all terms required), not of its index. A keyword query would do far better.
- episodic-memory indexes exchanges (55 documents for 32 sessions), so its unit is large and
  the top ten results almost always span the right session on a corpus this small.
- agentmemory needs a running server; its first start downloads two workers. Its 1.5 MB state
  store against about 1.26 MB of transcript text gives no sign that tool output was dropped.
- TraceDecay stored 0.88 MB of message text (the transcripts hold about 1.26 MB of text, 0.86 MB
  of it tool output; its longest stored message is longer than the longest tool result, so tool
  output is kept). It returns messages (10 by default) rather than sessions, needs a daemon and
  a registered git project at the transcripts' working directory, and was queried through
  `tool message_search` because its `sessions search` command fails at defaults in v0.0.74. A
  stub repository stood in for the real one; session search does not read the code index.
- All arms return messages or exchanges, not sessions; sessions were derived by first
  occurrence. With a default of 10 or 20 hits, an arm whose hits cluster in one session returns
  fewer than five distinct sessions.
- agentmemory-hybrid's import outlived its own CLI's two-minute timeout on this host; a person
  following the CLI's message would have believed the import failed.
- Times were taken on a host at load 30 to 100, one run each.

## Runner scripts

### run_cass.py

```python
import json, re, subprocess, sys, time
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
qs = json.load(open(sys.argv[1]))
out, meta = [], {}
for w in ("question", "paraphrase"):
    for q in qs:
        t = time.time()
        p = subprocess.run(["cass", "search", q[w], "--robot", "--robot-meta", "--fields", "summary"],
                           capture_output=True, text=True, timeout=180)
        dt = time.time() - t
        sess, nhits, mode = [], 0, None
        try:
            d = json.loads(p.stdout)
            mode = d.get("_meta", {}).get("search_mode")
            for h in d.get("hits", []):
                nhits += 1
                m = UUID.search(h.get("source_path") or "")
                if m and m.group(0) not in sess:
                    sess.append(m.group(0))
        except ValueError:
            mode = "error: " + (p.stderr or p.stdout)[:200]
        meta[mode] = meta.get(mode, 0) + 1
        out.append({"id": q["id"], "wording": w, "sessions": sess[:10], "seconds": round(dt, 3), "hits": nhits})
json.dump({"modes": meta, "results": out}, sys.stdout)
```

### run_em.py

```python
import json, re, subprocess, sys, time
PATH = re.compile(r"Lines \d+-\d+ in (\S+)")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
qs = json.load(open(sys.argv[1]))
out, errs = [], 0
for w in ("question", "paraphrase"):
    for q in qs:
        t = time.time()
        p = subprocess.run(["episodic-memory", "search", q[w]], capture_output=True, text=True, timeout=300)
        dt = time.time() - t
        if p.returncode != 0:
            errs += 1
        sess, hits = [], 0
        for path in PATH.findall(p.stdout):
            hits += 1
            m = UUID.search(path)
            if m and m.group(0) not in sess:
                sess.append(m.group(0))
        out.append({"id": q["id"], "wording": w, "sessions": sess[:10], "seconds": round(dt, 3), "hits": hits})
json.dump({"errors": errs, "results": out}, sys.stdout)
```

### run_am.mjs

```js
import { readFileSync } from "node:fs";
const secret = readFileSync("/data/secret", "utf8").trim();
const qs = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = []; let errors = 0;
for (const w of ["question", "paraphrase"]) for (const q of qs) {
  const t = performance.now();
  let sessions = [], hits = 0;
  try {
    const r = await fetch("http://127.0.0.1:3111/agentmemory/search", { method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + secret },
      body: JSON.stringify({ query: q[w] }), signal: AbortSignal.timeout(120000) });
    const d = await r.json();
    if (!r.ok || !Array.isArray(d.results)) throw new Error("status " + r.status);
    for (const row of d.results) {
      hits++;
      const s = row.sessionId ?? row.observation?.sessionId;
      if (s && !sessions.includes(s)) sessions.push(s);
    }
  } catch (e) { errors++; console.error(q.id, w, String(e)); }
  out.push({ id: q.id, wording: w, sessions: sessions.slice(0, 10), seconds: +((performance.now() - t) / 1000).toFixed(3), hits });
}
console.log(JSON.stringify({ errors, results: out }));
```

### run_td.py

```python
import json, re, subprocess, sys, time
SESS = re.compile(r"session `([0-9a-f-]{36})`")
qs = json.load(open(sys.argv[1]))
out, errs = [], 0
for w in ("question", "paraphrase"):
    for q in qs:
        t = time.time()
        p = subprocess.run(["tracedecay", "tool", "message_search", "--args", json.dumps({"query": q[w]})],
                           capture_output=True, text=True, timeout=180, cwd="/private/tmp/shipyard/ctx")
        dt = time.time() - t
        if p.returncode != 0:
            errs += 1
        sess = []
        for s in SESS.findall(p.stdout):
            if s not in sess:
                sess.append(s)
        out.append({"id": q["id"], "wording": w, "sessions": sess[:10], "seconds": round(dt, 3)})
json.dump({"errors": errs, "results": out}, sys.stdout)
```
