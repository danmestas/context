-- Split each question into search terms: runs of letters, digits and underscores,
-- at least three characters long, without stopwords.

WITH RECURSIVE walk(corpus, qid, q, i, cur, done) AS (
  SELECT corpus, id, lower(question) || ' ', 1, '', NULL FROM query
  UNION ALL
  SELECT corpus, qid, q, i + 1,
         CASE WHEN substr(q, i, 1) GLOB '[a-z0-9_]' THEN cur || substr(q, i, 1) ELSE '' END,
         CASE WHEN substr(q, i, 1) GLOB '[a-z0-9_]' THEN NULL ELSE cur END
  FROM walk WHERE i <= length(q)
)
INSERT OR IGNORE INTO term(corpus, qid, term)
SELECT corpus, qid, done FROM walk
WHERE length(done) >= 3 AND done NOT IN (SELECT word FROM stopword);

-- The grep baseline searches the way an agent would. Literals are recognised from
-- the form of the question alone, never from its kind or its answer.
INSERT OR IGNORE INTO grep_term(corpus, qid, term)
SELECT corpus, id,
       lower(substr(question, instr(question, '"') + 1,
                    instr(substr(question, instr(question, '"') + 1), '"') - 1))
FROM query
WHERE instr(substr(question, instr(question, '"') + 1), '"') > 1;

WITH RECURSIVE walk(corpus, qid, q, i, cur, done) AS (
  SELECT corpus, id, question || ' ', 1, '', NULL FROM query
  WHERE NOT EXISTS (SELECT 1 FROM grep_term g WHERE g.corpus = query.corpus AND g.qid = query.id)
  UNION ALL
  SELECT corpus, qid, q, i + 1,
         CASE WHEN substr(q, i, 1) GLOB '[A-Za-z0-9_-]' THEN cur || substr(q, i, 1) ELSE '' END,
         CASE WHEN substr(q, i, 1) GLOB '[A-Za-z0-9_-]' THEN NULL ELSE cur END
  FROM walk WHERE i <= length(q)
)
INSERT OR IGNORE INTO grep_term(corpus, qid, term)
SELECT corpus, qid, lower(trim(done, '-')) FROM walk
WHERE length(trim(done, '-')) >= 3
  AND (trim(done, '-') GLOB '*[0-9_-]*' OR substr(done, 2) GLOB '*[A-Z]*');

INSERT OR IGNORE INTO grep_term(corpus, qid, term)
SELECT t.corpus, t.qid, t.term FROM term t
WHERE NOT EXISTS (SELECT 1 FROM grep_term g WHERE g.corpus = t.corpus AND g.qid = t.qid);
