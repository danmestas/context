-- Version 22 to 21: the usage tables go, with what ctx kept for them in ctx_meta; nothing else changes, so a
-- ctx of version 21 opens the archive as it left it.
-- Run on its own, with nothing else holding the archive:
--   sqlite3 ~/.ctx/ctx.sqlite < schema/migrate/22-down.sql   (or: ctx migrate down 21)

BEGIN IMMEDIATE;
DROP TABLE IF EXISTS ctx_usage;
DROP TABLE IF EXISTS ctx_usage_read;
DROP TABLE IF EXISTS ctx_limit;
DELETE FROM ctx_meta WHERE key GLOB 'account:*' OR key GLOB 'plan-told:*' OR key = 'handoff_points';
PRAGMA user_version = 21;
COMMIT;
