-- The machine-wide ctx index. Everything here is derived: it can be rebuilt from
-- the Fossil repositories and project files, and it is never synced.
--
-- What lives in Fossil, not here:
--   source documents   check-ins in the project's shared repository
--   compiled wiki      Fossil wiki pages, mimetype text/x-markdown, same repository
--   work items         tickets, same repository (see ticket-table.sql)
--   session transcripts  technotes in a per-person repository

PRAGMA user_version = 1;

-- One row per Fossil repository found under ~/.ctx/repos/<project>/<name>.fossil.
CREATE TABLE ctx_repo(
  id      INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  name    TEXT NOT NULL,
  path    TEXT NOT NULL UNIQUE,
  scope   TEXT NOT NULL CHECK (scope IN ('shared', 'private')),
  UNIQUE (project, name)
) STRICT;

-- One row per indexed thing, at the version last indexed.
--   kind      name
--   source    path in the check-in
--   wiki      page name
--   session   technote id
--   ticket    ticket uuid
--   code      path relative to the project root
CREATE TABLE ctx_doc(
  id       INTEGER PRIMARY KEY,
  project  TEXT NOT NULL,
  repo_id  INTEGER REFERENCES ctx_repo(id) ON DELETE CASCADE,  -- NULL for code on disk
  kind     TEXT NOT NULL CHECK (kind IN ('source', 'wiki', 'session', 'ticket', 'code')),
  name     TEXT NOT NULL,
  title    TEXT,
  hash     TEXT NOT NULL,  -- Fossil artifact hash, or content hash for code
  status   TEXT,           -- tickets only: Open, Claimed, Done or Dropped
  size     INTEGER NOT NULL,
  mtime    INTEGER NOT NULL,
  UNIQUE (project, kind, name)
) STRICT;
CREATE INDEX ctx_doc_repo ON ctx_doc(repo_id);
CREATE INDEX ctx_doc_hash ON ctx_doc(hash);

-- The searchable unit: a session turn, a heading section, or a ticket's text.
-- A document is rebuilt by deleting its chunks and inserting new ones.
CREATE TABLE ctx_chunk(
  id      INTEGER PRIMARY KEY,
  doc_id  INTEGER NOT NULL REFERENCES ctx_doc(id) ON DELETE CASCADE,
  seq     INTEGER NOT NULL,
  heading TEXT NOT NULL DEFAULT '',  -- section heading, or the speaker for a turn
  at      TEXT,                      -- turn timestamp, sessions only
  body    TEXT NOT NULL,
  UNIQUE (doc_id, seq)
) STRICT;

CREATE VIRTUAL TABLE ctx_chunk_fts USING fts5(
  heading, body,
  content = 'ctx_chunk', content_rowid = 'id',
  tokenize = "porter unicode61 tokenchars '_'"
);

CREATE TRIGGER ctx_chunk_ai AFTER INSERT ON ctx_chunk BEGIN
  INSERT INTO ctx_chunk_fts(rowid, heading, body) VALUES (new.id, new.heading, new.body);
END;
CREATE TRIGGER ctx_chunk_ad AFTER DELETE ON ctx_chunk BEGIN
  INSERT INTO ctx_chunk_fts(ctx_chunk_fts, rowid, heading, body)
  VALUES ('delete', old.id, old.heading, old.body);
END;
CREATE TRIGGER ctx_chunk_au AFTER UPDATE OF heading, body ON ctx_chunk BEGIN
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
CREATE TABLE ctx_link(
  src_id   INTEGER NOT NULL REFERENCES ctx_doc(id) ON DELETE CASCADE,
  kind     TEXT NOT NULL CHECK (kind IN ('links_to', 'compiled_from', 'cites', 'blocked_by')),
  dst_kind TEXT NOT NULL CHECK (dst_kind IN ('source', 'wiki', 'session', 'ticket', 'code')),
  dst_name TEXT NOT NULL,
  dst_hash TEXT,
  PRIMARY KEY (src_id, kind, dst_kind, dst_name)
) STRICT, WITHOUT ROWID;
CREATE INDEX ctx_link_dst ON ctx_link(dst_kind, dst_name);

-- Wiki pages built from a source that has since changed or disappeared.
-- This is the recompile list; the agent does the compiling.
CREATE VIEW ctx_stale_wiki AS
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
CREATE VIEW ctx_ready_ticket AS
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
