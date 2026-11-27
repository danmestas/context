-- Version 22 to 23: ctx_usage is keyed on the response alone and gains a folder and a purpose; its rows go
-- and the places read are cleared, so the next collection reads every record again into the new table.
-- The logins seen per config folder are a new table.
-- Run on its own, with nothing else holding the archive:
--   sqlite3 ~/.ctx/ctx.sqlite < schema/migrate/23-up.sql   (or: ctx does this itself when it opens the archive)

BEGIN IMMEDIATE;
DROP TABLE IF EXISTS ctx_usage;
DELETE FROM ctx_usage_read;

-- One row per model response, from the session records each harness writes (Claude Code's
-- transcripts and subagent files, Codex's rollouts), taken in as ctx reads them. Tokens as the
-- harness reports them for that one response; for Codex, input excludes the cached part, which is
-- cache_read. account is the provider and the login address (or "anthropic:api-key" and the like),
-- kept only here, and NULL when it is not known: a Claude Code response made before ctx first saw
-- the login that was current when it read it (ctx_account_seen), or a Codex session that does not
-- name its account. msg is the harness's message id for Claude Code, which a forked or copied
-- transcript repeats, so a response is one row whichever file it is read from; for Codex it is the
-- session and its running total. dollars is the response priced, when collected, at the price line dated
-- price_date; NULL when no line covers the model at that time.
CREATE TABLE IF NOT EXISTS ctx_usage(
  id         INTEGER PRIMARY KEY,
  harness    TEXT NOT NULL,       -- claude, codex, pic
  session    TEXT NOT NULL,
  parent     TEXT,                -- for a subagent: the session that started it
  msg        TEXT NOT NULL,       -- the response's id
  project    TEXT,
  folder     TEXT,                -- the working directory as Claude Code names its folder, which ctx exclude matches
  purpose    TEXT,                -- pic: compaction or branch_summary; NULL for a reply
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
  UNIQUE (harness, msg)
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_usage_at ON ctx_usage(at);
CREATE INDEX IF NOT EXISTS ctx_usage_session ON ctx_usage(session);

-- The logins ctx has seen in each Claude Code config folder, from when it first saw each. A
-- response is given the login seen latest at or before its time; one older than every login seen
-- has none, since .claude.json says only who is logged in now.
CREATE TABLE IF NOT EXISTS ctx_account_seen(
  config     TEXT NOT NULL,       -- the config folder
  first_seen TEXT NOT NULL,       -- ISO 8601, UTC
  account    TEXT NOT NULL,
  plan       TEXT,
  billing    TEXT,
  PRIMARY KEY (config, first_seen)
) STRICT, WITHOUT ROWID;

PRAGMA user_version = 23;
COMMIT;
