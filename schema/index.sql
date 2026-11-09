-- The ctx tables in the machine's one SQLite file, ~/.ctx/ctx.sqlite. The Fossil
-- repositories live in the same file as libfossil host repositories (repo:NAME).
--
-- State, kept across a rebuild: ctx_project, ctx_repo, ctx_capture.
-- Derived, cleared and rebuilt from the repositories and project files, and never
-- synced: ctx_doc, ctx_chunk, ctx_chunk_fts, ctx_link.
--
-- What lives in the Fossil repositories, not here:
--   source documents   check-ins in the project's shared repository
--   compiled wiki      Fossil wiki pages, mimetype text/x-markdown, same repository
--   work items         tickets, same repository (see ticket-table.sql)
--   session transcripts  technotes in a per-person repository

PRAGMA user_version = 1;

-- Which project a working directory belongs to. The longest root that contains the
-- directory wins, so a nested project is found before its parent:
--   SELECT project FROM ctx_project
--   WHERE @cwd = root OR substr(@cwd, 1, length(root) + 1) = root || '/'
--   ORDER BY length(root) DESC LIMIT 1;
CREATE TABLE ctx_project(
  root    TEXT PRIMARY KEY,
  project TEXT NOT NULL
) STRICT, WITHOUT ROWID;
CREATE INDEX ctx_project_name ON ctx_project(project);

-- One row per repository in this file. Each project has one shared repository; each
-- person has one private repository, which belongs to no project.
CREATE TABLE ctx_repo(
  id      INTEGER PRIMARY KEY,
  name    TEXT NOT NULL UNIQUE,  -- the NAME in repo:NAME
  project TEXT,
  scope   TEXT NOT NULL CHECK (scope IN ('shared', 'private')),
  remote  TEXT,                  -- sync URL; NULL never leaves the machine
  CHECK (scope = 'private' OR project IS NOT NULL)
) STRICT;

-- How far each transcript has been archived. Offsets are bytes into the file;
-- head_hash is of its first 64 KB, so a replaced file is noticed and read again.
CREATE TABLE ctx_capture(
  session   TEXT PRIMARY KEY,
  path      TEXT NOT NULL,
  project   TEXT NOT NULL,
  offset    INTEGER NOT NULL DEFAULT 0,
  head_hash TEXT
) STRICT;

-- The technote holding one session's turns for one UTC day.
CREATE TABLE ctx_capture_day(
  session  TEXT NOT NULL REFERENCES ctx_capture(session) ON DELETE CASCADE,
  day      TEXT NOT NULL,
  technote TEXT NOT NULL,
  PRIMARY KEY (session, day)
) STRICT, WITHOUT ROWID;

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
  turn    TEXT,                      -- transcript uuid of a turn, so a re-read skips it
  project TEXT,                      -- where a turn happened; a session can move between projects
  body    TEXT NOT NULL,
  UNIQUE (doc_id, seq)
) STRICT;
CREATE UNIQUE INDEX ctx_chunk_turn ON ctx_chunk(turn) WHERE turn IS NOT NULL;

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
