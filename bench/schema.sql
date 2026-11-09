-- Tables, corpus definitions and stopwords for the retrieval bench.

CREATE TABLE corpus(
  name   TEXT PRIMARY KEY,
  labels TEXT NOT NULL  -- file name under the labels directory
);
INSERT INTO corpus VALUES
  ('dagnats',           'dagnats.json'),
  ('libfossil',         'libfossil.json'),
  ('e',                 'e.json'),
  ('flight-planner-kb', 'flight-planner.json'),
  ('karpathy-llm-wiki', 'karpathy-wiki.json');

-- A path is indexed if it matches a keep=1 glob and no keep=0 glob.
CREATE TABLE corpus_rule(corpus TEXT, glob TEXT, keep INTEGER);
INSERT INTO corpus_rule VALUES
  ('dagnats', '*', 1), ('dagnats', '.git/*', 0), ('dagnats', '.claude/*', 0),
  ('dagnats', '.agents/*', 0), ('dagnats', 'go.sum', 0), ('dagnats', '*/go.sum', 0),
  ('dagnats', '*.lock', 0), ('dagnats', '*package-lock.json', 0),
  ('libfossil', '*', 1), ('libfossil', '.fslckout', 0), ('libfossil', 'extsrc/*', 0),
  ('libfossil', '.claude/*', 0), ('libfossil', '.agents/*', 0),
  ('e', '*', 1), ('e', '.git/*', 0), ('e', '.claude/*', 0), ('e', '.agents/*', 0),
  ('e', '*.lock', 0), ('e', '*package-lock.json', 0), ('e', '*.woff2', 0),
  ('flight-planner-kb', 'wiki/*.md', 1), ('flight-planner-kb', '_sources/*.md', 1),
  ('karpathy-llm-wiki', 'wiki/*.md', 1), ('karpathy-llm-wiki', 'raw/*.md', 1);

CREATE TABLE doc(
  id     INTEGER PRIMARY KEY,
  corpus TEXT NOT NULL,
  path   TEXT NOT NULL,
  body   TEXT NOT NULL,
  UNIQUE(corpus, path)
);

CREATE TABLE query(
  corpus   TEXT NOT NULL,
  id       TEXT NOT NULL,
  kind     TEXT NOT NULL,
  question TEXT NOT NULL,
  PRIMARY KEY(corpus, id)
);
CREATE TABLE expected(
  corpus TEXT NOT NULL,
  qid    TEXT NOT NULL,
  path   TEXT NOT NULL,
  PRIMARY KEY(corpus, qid, path)
);

CREATE TABLE stopword(word TEXT PRIMARY KEY) WITHOUT ROWID;
INSERT INTO stopword VALUES
  ('about'),('after'),('all'),('also'),('and'),('any'),('are'),('around'),('because'),
  ('been'),('before'),('being'),('besides'),('between'),('both'),('but'),('can'),
  ('changed'),('code'),('could'),('did'),('does'),('each'),('else'),('file'),('files'),
  ('for'),('from'),('get'),('gets'),('had'),('has'),('have'),('how'),('into'),('its'),
  ('just'),('like'),('make'),('may'),('might'),('more'),('most'),('must'),('non'),
  ('not'),('one'),('only'),('other'),('our'),('out'),('over'),('page'),('pages'),
  ('should'),('some'),('such'),('than'),('that'),('the'),('their'),('them'),('then'),
  ('there'),('these'),('they'),('this'),('those'),('through'),('too'),('under'),('use'),
  ('used'),('uses'),('using'),('was'),('were'),('what'),('when'),('where'),('which'),
  ('while'),('who'),('why'),('will'),('wiki'),('with'),('would'),('you'),('your');

-- Search terms for a query: lower-cased words, used by BM25 and as grep's fallback.
CREATE TABLE term(
  corpus TEXT NOT NULL,
  qid    TEXT NOT NULL,
  term   TEXT NOT NULL,
  PRIMARY KEY(corpus, qid, term)
);

-- What the grep baseline searches for: a quoted string if the question has one,
-- else any identifiers in it, else the plain terms.
CREATE TABLE grep_term(
  corpus TEXT NOT NULL,
  qid    TEXT NOT NULL,
  term   TEXT NOT NULL,
  PRIMARY KEY(corpus, qid, term)
);

-- One row per file per term, from ripgrep.
CREATE TABLE grep_hit(corpus TEXT, term TEXT, path TEXT, n INTEGER);

CREATE TABLE result(
  method TEXT NOT NULL,
  corpus TEXT NOT NULL,
  qid    TEXT NOT NULL,
  rank   INTEGER NOT NULL,
  path   TEXT NOT NULL,
  PRIMARY KEY(method, corpus, qid, rank)
);
