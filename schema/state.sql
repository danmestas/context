-- State: what ctx cannot recompute, kept across a rebuild and never dropped. It sits
-- in the machine's one SQLite file, ~/.ctx/ctx.sqlite, beside the derived tables in
-- index.sql and the libfossil host repositories (repo:NAME). Every statement is
-- idempotent, so this file is applied on each open.

-- Which project a working directory belongs to. The longest root that contains the
-- directory wins, so a nested project is found before its parent:
--   SELECT project FROM ctx_project
--   WHERE @cwd = root OR substr(@cwd, 1, length(root) + 1) = root || '/'
--   ORDER BY length(root) DESC LIMIT 1;
CREATE TABLE IF NOT EXISTS ctx_project(
  root    TEXT PRIMARY KEY,
  project TEXT NOT NULL
) STRICT, WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ctx_project_name ON ctx_project(project);

-- One row per repository in this file. Each project has one shared repository; each
-- person has one private repository, which belongs to no project.
CREATE TABLE IF NOT EXISTS ctx_repo(
  id      INTEGER PRIMARY KEY,
  name    TEXT NOT NULL UNIQUE,  -- the NAME in repo:NAME
  project TEXT,
  scope   TEXT NOT NULL CHECK (scope IN ('shared', 'private')),
  remote  TEXT,                  -- sync URL; NULL never leaves the machine
  CHECK (scope = 'private' OR project IS NOT NULL)
) STRICT;

-- How far each transcript has been archived. Offsets are bytes into the file;
-- head_hash is of its first 64 KB, so a replaced file is noticed and read again.
CREATE TABLE IF NOT EXISTS ctx_capture(
  session   TEXT PRIMARY KEY,
  path      TEXT NOT NULL,
  project   TEXT NOT NULL,
  offset    INTEGER NOT NULL DEFAULT 0,
  head_hash TEXT
) STRICT;

-- The technote holding one session's turns for one UTC day.
CREATE TABLE IF NOT EXISTS ctx_capture_day(
  session  TEXT NOT NULL REFERENCES ctx_capture(session) ON DELETE CASCADE,
  day      TEXT NOT NULL,
  technote TEXT NOT NULL,
  PRIMARY KEY (session, day)
) STRICT, WITHOUT ROWID;

-- Audit runs and findings. A finding names a chunk by id, which a rebuild changes;
-- the fingerprint is what an allowance follows.
CREATE TABLE IF NOT EXISTS ctx_audit_run(
  id      INTEGER PRIMARY KEY,
  at      TEXT NOT NULL,
  scanned INTEGER NOT NULL,
  to_id   INTEGER NOT NULL,
  known   INTEGER NOT NULL,
  found   INTEGER NOT NULL,
  open    INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS ctx_audit_finding(
  id          INTEGER PRIMARY KEY,
  rule        TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  chunk       INTEGER NOT NULL,
  project     TEXT,
  day         TEXT,
  shape       TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open',
  note        TEXT NOT NULL DEFAULT '',
  UNIQUE (rule, fingerprint, chunk)
) STRICT;

-- Which session compiled which page version. Private: a shared page never names it.
CREATE TABLE IF NOT EXISTS ctx_wiki_log(
  id      INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  page    TEXT NOT NULL,
  version TEXT NOT NULL,
  model   TEXT NOT NULL,
  ticket  TEXT NOT NULL,
  session TEXT,
  at      TEXT NOT NULL
) STRICT;

-- Settings ctx keeps for itself, such as the version of the derived tables.
CREATE TABLE IF NOT EXISTS ctx_meta(
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Rules: which technote holds each rule, by its key. A memory file's key is its
-- path; a rule added by hand gets a random one.
CREATE TABLE IF NOT EXISTS ctx_rule(
  key      TEXT PRIMARY KEY,
  technote TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Proposed rules: turns the person typed that read like standing instructions. Only
-- the person accepts one into a rule; a rejected one is never proposed again.
CREATE TABLE IF NOT EXISTS ctx_rule_proposal(
  id      INTEGER PRIMARY KEY,
  turn    TEXT NOT NULL UNIQUE,        -- transcript uuid, stable across rebuilds
  project TEXT NOT NULL,
  at      TEXT,
  text    TEXT NOT NULL,               -- already redacted
  status  TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
  rule    TEXT                         -- the rule an accepted one became
) STRICT;

-- Turns the rule classifier has already seen, so each is sent once.
CREATE TABLE IF NOT EXISTS ctx_rule_seen(
  turn TEXT PRIMARY KEY
) STRICT, WITHOUT ROWID;

-- Checks on rules: the judge's last verdict with a quote from the person's own turns,
-- when the agent last asked about it, and when the person kept or reviewed it.
CREATE TABLE IF NOT EXISTS ctx_rule_check(
  key      TEXT PRIMARY KEY,
  checked  TEXT,           -- when the judge last looked
  verdict  TEXT,           -- stale or true
  evidence TEXT,           -- a quote found word for word in the person's turns
  asked    TEXT,           -- when a session last asked the person about it
  kept     TEXT,           -- when the person said it still holds
  reviewed TEXT            -- when it was last in a monthly review
) STRICT, WITHOUT ROWID;
