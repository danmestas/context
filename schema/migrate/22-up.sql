-- Version 21 to 22: the tables of spend per response, of where each record file was read, and of plan
-- limit readings.
-- Run on its own, with nothing else holding the archive:
--   sqlite3 ~/.ctx/ctx.sqlite < schema/migrate/22-up.sql   (or: ctx does this itself when it opens the archive)

BEGIN IMMEDIATE;

-- One row per model response, from the session records each harness writes (Claude Code's
-- transcripts and subagent files, Codex's rollouts), taken in as ctx reads them. Tokens as the
-- harness reports them for that one response; for Codex, input excludes the cached part, which is
-- cache_read. account is the provider and the login address (or "anthropic:api-key" and the like),
-- kept only here. dollars is the response priced, when collected, at the price line dated
-- price_date; NULL when no line covers the model at that time.
CREATE TABLE IF NOT EXISTS ctx_usage(
  id         INTEGER PRIMARY KEY,
  harness    TEXT NOT NULL,       -- claude, codex
  session    TEXT NOT NULL,
  parent     TEXT,                -- for a subagent: the session that started it
  msg        TEXT NOT NULL,       -- the response's id within its session
  project    TEXT,
  account    TEXT,
  plan       TEXT,                -- plan name, or api-key
  billing    TEXT,
  model      TEXT NOT NULL,
  speed      TEXT,
  at         TEXT NOT NULL,       -- ISO 8601, UTC
  input      INTEGER NOT NULL,
  write_5m   INTEGER NOT NULL,
  write_1h   INTEGER NOT NULL,
  cache_read INTEGER NOT NULL,
  output     INTEGER NOT NULL,
  reasoning  INTEGER NOT NULL DEFAULT 0, -- part of output, where the harness says
  dollars    REAL,
  price_date TEXT,
  UNIQUE (harness, session, msg)
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_usage_at ON ctx_usage(at);
CREATE INDEX IF NOT EXISTS ctx_usage_session ON ctx_usage(session);

-- How far each session record file has been read for ctx_usage: the byte after the last whole
-- line, a hash of the file's start to notice a replaced file, and what a Codex rollout said
-- earlier that later lines need (its session, model, project, running totals), as JSON.
CREATE TABLE IF NOT EXISTS ctx_usage_read(
  path   TEXT PRIMARY KEY,
  offset INTEGER NOT NULL,
  head   TEXT,
  state  TEXT
) STRICT, WITHOUT ROWID;

-- Readings of a plan's limits: how much of a window is used, when it resets. Codex writes them
-- into its rollouts; Claude Code gives them to its status line, which hands them to
-- ctx usage limits-in. window is the window's length in minutes (300 for five hours, 10080 for a
-- week); context readings use window 0 and used is the share of the context window.
CREATE TABLE IF NOT EXISTS ctx_limit(
  account   TEXT NOT NULL,
  window    INTEGER NOT NULL,
  at        TEXT NOT NULL,        -- ISO 8601, UTC
  used      REAL NOT NULL,        -- percent
  resets_at INTEGER,              -- unix seconds
  session   TEXT,
  source    TEXT NOT NULL,        -- codex, statusline
  PRIMARY KEY (account, window, at)
) STRICT, WITHOUT ROWID;

PRAGMA user_version = 22;
COMMIT;
