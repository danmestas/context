-- Rank files with FTS5 BM25. The run script fills in __FTS__, __METHOD__ and __CORPUS__.
-- Terms are OR-ed so that a long question is not required to match in full.

WITH q AS (
  SELECT corpus, qid, group_concat('"' || term || '"', ' OR ') AS expr
  FROM term
  WHERE corpus = '__CORPUS__'
  GROUP BY corpus, qid
)
INSERT INTO result(method, corpus, qid, rank, path)
SELECT '__METHOD__', corpus, qid, rnk, path
FROM (
  SELECT q.corpus, q.qid, d.path,
         row_number() OVER (PARTITION BY q.qid ORDER BY __FTS__.rank, d.path) AS rnk
  FROM q
  JOIN __FTS__ ON __FTS__ MATCH q.expr
  JOIN doc d ON d.id = __FTS__.rowid AND d.corpus = q.corpus
)
WHERE rnk <= 50;
