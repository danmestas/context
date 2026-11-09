-- The ticket schema for ctx's shared project repositories. Stored as the value of
-- the repository's 'ticket-table' config entry, then applied by a rebuild.
--
-- Tickets are the work agents and people pick up. ctx ships this schema and applies
-- it to each shared repository.
--   type     Task, Bug, Feature or Question
--   status   Open, Claimed, Done or Dropped
--
-- The first fourteen columns are Fossil's defaults. The rest are ctx's:
--   assignee         the person or agent working it; empty while unclaimed
--   claimed_at       when it was claimed
--   acceptance       what must be true for it to be done
--   blocked_by       space-separated tkt_uuids that must finish first
--   source_session   technote id of the session it came from
--   source_turn      the turn within that session
--   result           check-in hash, or link, of the finished work
CREATE TABLE repository.ticket(
  tkt_id INTEGER PRIMARY KEY,
  tkt_uuid TEXT UNIQUE,
  tkt_mtime DATE,
  tkt_ctime DATE,
  type TEXT,
  status TEXT,
  subsystem TEXT,
  priority TEXT,
  severity TEXT,
  foundin TEXT,
  private_contact TEXT,
  resolution TEXT,
  title TEXT,
  comment TEXT,
  assignee TEXT,
  claimed_at TEXT,
  acceptance TEXT,
  blocked_by TEXT,
  source_session TEXT,
  source_turn INTEGER,
  result TEXT
);
CREATE TABLE repository.ticketchng(
  tkt_id INTEGER REFERENCES ticket,
  tkt_rid INTEGER REFERENCES blob,
  tkt_mtime DATE,
  tkt_user TEXT,
  login TEXT,
  username TEXT,
  mimetype TEXT,
  icomment TEXT
);
CREATE INDEX repository.ticketchng_idx1 ON ticketchng(tkt_id, tkt_mtime);
