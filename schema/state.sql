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

-- How far each pic conversation has been archived from pic.sqlite, whose rows are
-- append-only per conversation. id is the id in its header row (seq 0), which names the
-- session pi-<id> as in its file form; slug is its workspace with every character that is
-- not a letter or digit turned into a dash, what ctx exclude matches; seq is the last row
-- read; offset is the byte where the next line would start in the session file the rows
-- stand for, so a line without an entry id is keyed by the same position as in that file.
CREATE TABLE IF NOT EXISTS ctx_pic_cursor(
  conversation TEXT PRIMARY KEY,
  id           TEXT NOT NULL,
  slug         TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  offset       INTEGER NOT NULL
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

-- Identical copies of a rule in one project, found after every rules import: same text once a
-- memory file's frontmatter, case and spacing are set aside. The copy is replaced by the
-- oldest. rule_hash is the copy's compared text; undone = 1 once `ctx rules restore` undid it.
CREATE TABLE IF NOT EXISTS ctx_rule_collapse(
  key       TEXT NOT NULL,
  rule_hash TEXT NOT NULL,
  kept      TEXT NOT NULL,      -- the rule it is a copy of
  project   TEXT NOT NULL,
  at        TEXT NOT NULL,
  undone    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key, rule_hash)
) STRICT, WITHOUT ROWID;

-- The automatic judge's verdict on whether the global instructions already say a project rule,
-- one per rule text and global text, so neither is sent again until one of them changes.
-- covered = 1 only with a quote found word for word in the global text; such a rule is
-- retired. Paid judgements, so state: a rebuild keeps them.
CREATE TABLE IF NOT EXISTS ctx_rule_covered(
  key         TEXT NOT NULL,
  rule_hash   TEXT NOT NULL,
  global_hash TEXT NOT NULL,
  covered     INTEGER NOT NULL,
  quote       TEXT NOT NULL DEFAULT '',
  at          TEXT NOT NULL,
  undone      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key, rule_hash, global_hash)
) STRICT, WITHOUT ROWID;

-- The global files a covered verdict found its quote in, one per agent the rule reaches, in
-- order: kept apart from the retirement's reason, which a path with any character can make
-- ambiguous. Verdicts from before it name their one file in the reason.
CREATE TABLE IF NOT EXISTS ctx_rule_covered_file(
  key         TEXT NOT NULL,
  rule_hash   TEXT NOT NULL,
  global_hash TEXT NOT NULL,
  seq         INTEGER NOT NULL,
  file        TEXT NOT NULL,
  PRIMARY KEY (key, rule_hash, global_hash, seq)
) STRICT, WITHOUT ROWID;

-- Retirements the person undid with `ctx rules restore`, whatever retired the rule. While the
-- rule's text and the global CLAUDE.md are as they were then, neither the collapse of copies
-- nor the covered check retires it again.
CREATE TABLE IF NOT EXISTS ctx_rule_restore(
  id          INTEGER PRIMARY KEY,
  key         TEXT NOT NULL,
  rule_hash   TEXT NOT NULL,
  global_hash TEXT NOT NULL,
  was         TEXT NOT NULL,     -- the status and reason it had
  at          TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_rule_restore_key ON ctx_rule_restore(key, rule_hash);

-- The person's answer to a group of rules from several projects the page offered as one:
-- made into one rule for every project, or not the same. sig hashes the members' keys and
-- texts, so a group whose members change is offered again.
CREATE TABLE IF NOT EXISTS ctx_rule_same(
  sig      TEXT PRIMARY KEY,
  decision TEXT NOT NULL CHECK (decision IN ('global', 'distinct')),
  keys     TEXT NOT NULL,       -- JSON array of the member keys
  made     TEXT,                -- for global: the new rule's key
  at       TEXT NOT NULL
) STRICT, WITHOUT ROWID;

-- Each hook, search and turn call from the call log (ctx.sqlite.calls), taken in by the hourly
-- ctx scan from where the last one stopped (ctx_meta calls_ingested), so a call is counted once
-- whatever the log's rotation does, and kept 30 days. ts is when it started; ms is how long it
-- took, NULL while it has no end: once a minute old, it was cut off. An end older than its start
-- in the log is a row of its own, started ms before it ended. The rest is what the end line says,
-- NULL where it says "-" or is from an older ctx that wrote less; a finished day's Parquet file
-- is written from these rows. Columns added later are added to an older file by ctx itself.
CREATE TABLE IF NOT EXISTS ctx_call(
  ts      INTEGER NOT NULL,         -- unix seconds
  pid     INTEGER NOT NULL,
  name    TEXT NOT NULL,
  ms      INTEGER,                  -- -1 when an old end line gave no time
  exit    INTEGER,
  outcome TEXT,                     -- offered, quiet, denied, nudged, archived, error, told
  bytes   INTEGER,                  -- written to stdout
  harness TEXT,
  session TEXT
) STRICT;
CREATE INDEX IF NOT EXISTS ctx_call_ts ON ctx_call(ts);
CREATE INDEX IF NOT EXISTS ctx_call_open ON ctx_call(pid, name) WHERE ms IS NULL;

-- One row per UTC day and call name, computed from ctx_call by each scan for the last 15 days.
-- Times are milliseconds over the calls that ended; NULL when none did. cut counts calls that
-- started and had not ended a minute later: calls the harness cut off.
CREATE TABLE IF NOT EXISTS ctx_call_day(
  day   TEXT NOT NULL,              -- YYYY-MM-DD, UTC
  name  TEXT NOT NULL,              -- hook or search, as the log names it
  calls INTEGER NOT NULL,           -- ended and cut off
  cut   INTEGER NOT NULL,
  p50   INTEGER,
  p95   INTEGER,
  max   INTEGER,
  PRIMARY KEY (day, name)
) STRICT, WITHOUT ROWID;

-- Problems ctx is fairly sure it has, one row per problem, written by the detectors in ctx scan.
-- watching: seen, below confidence; open: confident; closed: gone three days running. A closed
-- problem that comes back is the same row, opened again.
CREATE TABLE IF NOT EXISTS ctx_finding(
  fingerprint TEXT PRIMARY KEY,     -- kind:name, such as hook-slow:gate or search-slow
  kind        TEXT NOT NULL,        -- hook-slow, search-slow, hook-cut
  state       TEXT NOT NULL CHECK (state IN ('watching', 'open', 'closed')),
  title       TEXT NOT NULL,        -- the finding in words, numbers included
  evidence    TEXT NOT NULL,
  next        TEXT NOT NULL,        -- a suggested next step
  series      TEXT NOT NULL,        -- JSON [[day, value], ...]: the daily figures it rests on
  target      INTEGER,              -- the budget or target the series is held to, ms; NULL for counts
  first_seen  TEXT NOT NULL,
  last_seen   TEXT NOT NULL,        -- the last scan that saw the condition
  changed     TEXT NOT NULL,        -- when state last changed
  opened      TEXT,                 -- when it last became open; NULL if it never was
  reopened    INTEGER NOT NULL DEFAULT 0
) STRICT, WITHOUT ROWID;

-- What the automatic judge (ctx rules auto) decided about a group of the same rule in several
-- projects. id is what ctx rules undo gN names. sig is the group as it was judged, so the judge
-- never takes the same group twice; acted is the signature of the rules it acted on, as in
-- ctx_rule_same. left: the answer could not be acted on, and the group waits for the person.
CREATE TABLE IF NOT EXISTS ctx_same_judged(
  id       INTEGER PRIMARY KEY,
  sig      TEXT NOT NULL UNIQUE,
  decision TEXT NOT NULL CHECK (decision IN ('global', 'distinct', 'left')),
  members  TEXT NOT NULL,         -- JSON [{"k": key, "p": project, "t": title}], all the judge saw
  keys     TEXT NOT NULL,         -- JSON keys acted on; for global the kept one first
  acted    TEXT,                  -- ctx_rule_same.sig of those keys
  made     TEXT,                  -- for global: the new rule's key
  prior    TEXT,                  -- for global: JSON [{"k", "status", "by", "reason"}], each replaced rule as it was
  why      TEXT NOT NULL,
  model    TEXT NOT NULL,
  at       TEXT NOT NULL,
  undone   INTEGER NOT NULL DEFAULT 0
) STRICT;

-- Groups the automatic judge's command failed on (non-zero exit or out of time), by signature. At
-- two, the group is recorded as left for the person, so one group cannot hold up the rest.
CREATE TABLE IF NOT EXISTS ctx_same_fail(
  sig   TEXT PRIMARY KEY,
  fails INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
