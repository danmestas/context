-- Version 23 to 22: ctx_usage goes back to its version-22 shape, empty, and the places read are cleared so a
-- ctx of version 22 reads every record again; the logins seen and the handoff points go.
-- Run on its own, with nothing else holding the archive:
--   sqlite3 ~/.ctx/ctx.sqlite < schema/migrate/23-down.sql   (or: ctx migrate down 22)

BEGIN IMMEDIATE;
DROP TABLE IF EXISTS ctx_usage;
DROP TABLE IF EXISTS ctx_account_seen;
DELETE FROM ctx_usage_read;
DELETE FROM ctx_meta WHERE key = 'handoff_points';

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

PRAGMA user_version = 22;
COMMIT;
