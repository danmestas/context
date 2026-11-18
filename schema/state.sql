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

-- When each proposal was made. One left undecided for 30 days leaves the list: a queue
-- nobody reads helps no one. Proposals from before this table get their 30 days from now.
CREATE TABLE IF NOT EXISTS ctx_proposal_made(
  id   INTEGER PRIMARY KEY REFERENCES ctx_rule_proposal(id) ON DELETE CASCADE,
  made TEXT NOT NULL
) STRICT;
CREATE TRIGGER IF NOT EXISTS ctx_proposal_made_on_insert AFTER INSERT ON ctx_rule_proposal
BEGIN
  INSERT OR IGNORE INTO ctx_proposal_made(id, made) VALUES (new.id, datetime('now'));
END;
INSERT OR IGNORE INTO ctx_proposal_made(id, made) SELECT id, datetime('now') FROM ctx_rule_proposal;

-- Times the person said an open proposal again, in another session, as a model judged it:
-- the turn and when. Paid judgements, so state: a rebuild keeps them.
CREATE TABLE IF NOT EXISTS ctx_proposal_said(
  id   INTEGER NOT NULL REFERENCES ctx_rule_proposal(id) ON DELETE CASCADE,
  turn TEXT NOT NULL,                  -- transcript uuid of the repeat
  at   TEXT,
  PRIMARY KEY (id, turn)
) STRICT, WITHOUT ROWID;
-- The time of the person's newest turn when a proposal was last checked for repeats, so
-- it is checked again only once newer turns exist.
CREATE TABLE IF NOT EXISTS ctx_proposal_checked(
  id   INTEGER PRIMARY KEY REFERENCES ctx_rule_proposal(id) ON DELETE CASCADE,
  upto TEXT NOT NULL
) STRICT;

-- Attempt order is separate from completion: an omitted answer stays retryable without
-- keeping later unchecked proposals outside the bounded queue forever.
CREATE TABLE IF NOT EXISTS ctx_proposal_attempted(
  id   INTEGER PRIMARY KEY REFERENCES ctx_rule_proposal(id) ON DELETE CASCADE,
  upto TEXT NOT NULL,
  seq  INTEGER NOT NULL
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

-- The copy of an artifact page kept in the private repository: one technote per page,
-- whose history holds each kept version.
CREATE TABLE IF NOT EXISTS ctx_artifact_file(
  url      TEXT PRIMARY KEY,
  technote TEXT NOT NULL,
  version  INTEGER NOT NULL,  -- the newest version kept
  title    TEXT,              -- from the page's own <title>
  kept     TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Working directories whose sessions are never archived, with the folder-name form Claude
-- Code gives them, and sessions the person asked to have removed from the index.
CREATE TABLE IF NOT EXISTS ctx_exclude(
  dir  TEXT PRIMARY KEY,
  slug TEXT NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ctx_forgotten(
  session TEXT PRIMARY KEY,
  at      TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Directories of documents indexed where they sit, each with the project its hits are filed under.
CREATE TABLE IF NOT EXISTS ctx_docs_dir(
  dir     TEXT PRIMARY KEY,
  project TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Pairs of document sections a model has screened for conflict, by the hash of each section's
-- text, and the conflicts a judge confirmed with words quoted from both.
CREATE TABLE IF NOT EXISTS ctx_doc_pair(
  a     TEXT NOT NULL,
  b     TEXT NOT NULL,
  times INTEGER NOT NULL,
  PRIMARY KEY (a, b)
) STRICT, WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ctx_doc_conflict(
  a         TEXT NOT NULL,
  b         TEXT NOT NULL,
  project   TEXT NOT NULL,
  a_doc     TEXT NOT NULL,
  a_heading TEXT NOT NULL,
  a_quote   TEXT NOT NULL,
  b_doc     TEXT NOT NULL,
  b_heading TEXT NOT NULL,
  b_quote   TEXT NOT NULL,
  about     TEXT NOT NULL,
  current   TEXT,          -- A, B or unknown: the judge's guess at which side is current
  why       TEXT,
  found     TEXT NOT NULL,
  PRIMARY KEY (a, b)
) STRICT, WITHOUT ROWID;

-- Conflicts the person set aside, by the same pair of text hashes, with their reason. A pair
-- whose text changes has new hashes, so a dismissal ends when either passage is edited.
CREATE TABLE IF NOT EXISTS ctx_doc_dismissed(
  a      TEXT NOT NULL,
  b      TEXT NOT NULL,
  reason TEXT NOT NULL,
  at     TEXT NOT NULL,
  PRIMARY KEY (a, b)
) STRICT, WITHOUT ROWID;

-- One ticket per documentation problem ctx found, keyed by the problem itself so it is
-- never filed twice, even after the ticket is closed. A conflict's key is its 8-hex id;
-- a check finding's key names its project, file, kind and detail.
CREATE TABLE IF NOT EXISTS ctx_docs_ticket(
  key     TEXT PRIMARY KEY,
  ticket  TEXT NOT NULL,
  project TEXT NOT NULL,
  at      TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Which session holds a ticket: recorded from the hook's session id when a `ctx ticket
-- claim|done|drop` command passes through ctx gate. seen_at moves whenever that session
-- runs a hook, so the overview can say how long ago it was last active.
CREATE TABLE IF NOT EXISTS ctx_ticket_claim(
  ticket     TEXT PRIMARY KEY,      -- the full ticket uuid
  session    TEXT NOT NULL,
  claimed_at TEXT NOT NULL,
  seen_at    TEXT NOT NULL,
  closed_at  TEXT,                  -- when the holder finished or dropped it
  outcome    TEXT                   -- done or dropped, once closed
) STRICT, WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ctx_ticket_claim_session ON ctx_ticket_claim(session);

-- Messages from the person to whoever holds a ticket, delivered once by `ctx hook post`
-- in that session's next hook run.
CREATE TABLE IF NOT EXISTS ctx_ticket_prod(
  id           INTEGER PRIMARY KEY,
  ticket       TEXT NOT NULL,
  message      TEXT NOT NULL,
  at           TEXT NOT NULL,
  delivered_at TEXT,
  session      TEXT
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_ticket_prod_open ON ctx_ticket_prod(delivered_at, ticket);

-- What the automatic judge (`ctx rules auto CMD`) decided about a proposal on the person's
-- behalf: serve leaves it open and offers it as a tentative rule; covered, setup and not
-- reject it. undone = 1 once the person reversed it with `ctx rules undo N`; an undone
-- proposal is never judged again. Paid judgements, so state: a rebuild keeps them.
CREATE TABLE IF NOT EXISTS ctx_proposal_judged(
  id      INTEGER PRIMARY KEY REFERENCES ctx_rule_proposal(id) ON DELETE CASCADE,
  verdict TEXT NOT NULL CHECK (verdict IN ('serve', 'covered', 'setup', 'not')),
  why     TEXT,
  quote   TEXT,               -- for covered: the words of a rule or the global instructions
  model   TEXT,               -- the command that answered
  at      TEXT NOT NULL,
  undone  INTEGER NOT NULL DEFAULT 0
) STRICT;
