-- Derived: everything here is computed from the repositories and can be dropped and
-- rebuilt at any time, with ctx rebuild. When this file changes in a way old tables
-- cannot follow, raise CTX_DERIVED_VERSION in src/ctx.c and ctx rebuilds on next open
-- instead of migrating. State lives in state.sql. Every statement is idempotent.
--
-- What lives in the Fossil repositories, not here:
--   source documents   check-ins in the project's shared repository
--   compiled wiki      Fossil wiki pages, mimetype text/x-markdown, same repository
--   work items         tickets, same repository (see ticket-table.sql)
--   session transcripts  technotes in a per-person repository

-- One row per indexed thing, at the version last indexed.
--   kind      name
--   source    path in the check-in
--   wiki      page name
--   session   technote id
--   ticket    ticket uuid
--   code      path relative to the project root
CREATE TABLE IF NOT EXISTS ctx_doc(
  id       INTEGER PRIMARY KEY,
  project  TEXT NOT NULL,
  repo_id  INTEGER REFERENCES ctx_repo(id) ON DELETE CASCADE,  -- NULL for code on disk
  kind     TEXT NOT NULL CHECK (kind IN ('source', 'wiki', 'session', 'ticket', 'code')),
  name     TEXT NOT NULL,
  title    TEXT,
  hash     TEXT NOT NULL,  -- Fossil artifact hash, or content hash for code
  status   TEXT,           -- tickets: Open, Claimed, Done, Dropped; sources: superseded, retracted, amended; wiki: retired
  size     INTEGER NOT NULL,
  mtime    INTEGER NOT NULL,
  UNIQUE (project, kind, name)
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_doc_repo ON ctx_doc(repo_id);
CREATE INDEX IF NOT EXISTS ctx_doc_hash ON ctx_doc(hash);

-- The searchable unit: a session turn, a heading section, or a ticket's text.
-- A document is rebuilt by deleting its chunks and inserting new ones.
CREATE TABLE IF NOT EXISTS ctx_chunk(
  id      INTEGER PRIMARY KEY,
  doc_id  INTEGER NOT NULL REFERENCES ctx_doc(id) ON DELETE CASCADE,
  seq     INTEGER NOT NULL,
  heading TEXT NOT NULL DEFAULT '',  -- section heading, or the speaker for a turn
  at      TEXT,                      -- turn timestamp, sessions only
  turn    TEXT,                      -- transcript uuid of a turn, so a re-read skips it
  project TEXT,                      -- where a turn happened; a session can move between projects
  body    TEXT NOT NULL,
  UNIQUE (doc_id, seq)
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS ctx_chunk_turn ON ctx_chunk(turn) WHERE turn IS NOT NULL;

CREATE VIRTUAL TABLE IF NOT EXISTS ctx_chunk_fts USING fts5(
  heading, body,
  content = 'ctx_chunk', content_rowid = 'id',
  tokenize = "porter unicode61 tokenchars '_'"
);

CREATE TRIGGER IF NOT EXISTS ctx_chunk_ai AFTER INSERT ON ctx_chunk BEGIN
  INSERT INTO ctx_chunk_fts(rowid, heading, body) VALUES (new.id, new.heading, new.body);
END;
CREATE TRIGGER IF NOT EXISTS ctx_chunk_ad AFTER DELETE ON ctx_chunk BEGIN
  INSERT INTO ctx_chunk_fts(ctx_chunk_fts, rowid, heading, body)
  VALUES ('delete', old.id, old.heading, old.body);
END;
CREATE TRIGGER IF NOT EXISTS ctx_chunk_au AFTER UPDATE OF heading, body ON ctx_chunk BEGIN
  INSERT INTO ctx_chunk_fts(ctx_chunk_fts, rowid, heading, body)
  VALUES ('delete', old.id, old.heading, old.body);
  INSERT INTO ctx_chunk_fts(rowid, heading, body) VALUES (new.id, new.heading, new.body);
END;

-- Links are owned by the document that asserts them, so reindexing it replaces
-- exactly its own links. The target is named, not keyed, so a link can point at
-- something not indexed yet.
--   links_to       a wiki page's Markdown link, e.g. [Label](/wiki?name=Page+Name)
--   compiled_from  a wiki page's source, pinned to the source version in dst_hash
--   cites          a citation of a source, session or ticket, pinned when it can be
--   blocked_by     a ticket that must finish before this one
CREATE TABLE IF NOT EXISTS ctx_link(
  src_id   INTEGER NOT NULL REFERENCES ctx_doc(id) ON DELETE CASCADE,
  kind     TEXT NOT NULL CHECK (kind IN ('links_to', 'compiled_from', 'cites', 'blocked_by')),
  dst_kind TEXT NOT NULL CHECK (dst_kind IN ('source', 'wiki', 'session', 'ticket', 'code')),
  dst_name TEXT NOT NULL,
  dst_hash TEXT,
  PRIMARY KEY (src_id, kind, dst_kind, dst_name)
) STRICT, WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ctx_link_dst ON ctx_link(dst_kind, dst_name);

-- Wiki pages built from a source that has since changed or disappeared.
-- This is the recompile list; the agent does the compiling.
CREATE VIEW IF NOT EXISTS ctx_stale_wiki AS
SELECT w.project,
       w.name AS page,
       l.dst_name AS source,
       l.dst_hash AS compiled_from_hash,
       s.hash AS current_hash
FROM ctx_link l
JOIN ctx_doc w ON w.id = l.src_id AND w.kind = 'wiki'
LEFT JOIN ctx_doc s
  ON s.project = w.project AND s.kind = 'source' AND s.name = l.dst_name
WHERE l.kind = 'compiled_from'
  AND (s.id IS NULL OR l.dst_hash IS NOT s.hash);

-- Open tickets with nothing in the way. An unknown blocker counts as unfinished.
CREATE VIEW IF NOT EXISTS ctx_ready_ticket AS
SELECT t.project,
       t.name AS ticket,
       t.title
FROM ctx_doc t
WHERE t.kind = 'ticket'
  AND t.status = 'Open'
  AND NOT EXISTS (
    SELECT 1
    FROM ctx_link l
    LEFT JOIN ctx_doc b
      ON b.project = t.project AND b.kind = 'ticket' AND b.name = l.dst_name
    WHERE l.src_id = t.id
      AND l.kind = 'blocked_by'
      AND (b.id IS NULL OR b.status NOT IN ('Done', 'Dropped'))
  );

-- A wiki page's citations: each claim's quote, pinned to a check-in and file hash.
CREATE TABLE IF NOT EXISTS ctx_citation(
  id          INTEGER PRIMARY KEY,
  doc_id      INTEGER NOT NULL,
  ref         TEXT NOT NULL,
  quote       TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target      TEXT,
  ci          TEXT,
  file_hash   TEXT,
  status      TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_citation_target ON ctx_citation(target_kind, target);
CREATE INDEX IF NOT EXISTS ctx_citation_doc ON ctx_citation(doc_id);

-- A source's recorded origin, class and validity, from its NAME.origin.json.
CREATE TABLE IF NOT EXISTS ctx_source_meta(
  doc_id       INTEGER PRIMARY KEY,
  class        TEXT,
  review_after TEXT,
  valid_from   TEXT,
  valid_until  TEXT,
  added_at     TEXT,
  origin       TEXT,
  risk         TEXT
) STRICT;

-- The current state of each superseded source, folded from sources/SUPERSEDED.jsonl.
CREATE TABLE IF NOT EXISTS ctx_supersession(
  project  TEXT NOT NULL,
  old      TEXT NOT NULL,
  new      TEXT,
  relation TEXT NOT NULL,
  reason   TEXT,
  by_whom  TEXT,
  at       TEXT,
  PRIMARY KEY (project, old)
) STRICT;

-- Technotes indexed as sessions, at the version indexed.
CREATE TABLE IF NOT EXISTS ctx_remote_note(
  technote TEXT PRIMARY KEY,
  version  TEXT NOT NULL
) STRICT;
