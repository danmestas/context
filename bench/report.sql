-- Metrics, per query and summarised. Binary relevance; a query with no results scores zero.

CREATE VIEW score AS
WITH RECURSIVE
  nums(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM nums WHERE i < 10),
  methods AS (SELECT DISTINCT method FROM result),
  n AS (SELECT corpus, qid, count(*) AS n FROM expected GROUP BY corpus, qid),
  ideal AS (
    SELECT n.corpus, n.qid, sum(1.0 / log2(i + 1)) AS idcg
    FROM n JOIN nums ON i <= n.n
    GROUP BY n.corpus, n.qid
  ),
  hit AS (
    SELECT r.method, r.corpus, r.qid, r.rank
    FROM result r JOIN expected e USING (corpus, qid, path)
  ),
  agg AS (
    SELECT method, corpus, qid,
           sum(rank <= 10) AS hits10,
           count(*) AS hits50,
           sum(CASE WHEN rank <= 10 THEN 1.0 / log2(rank + 1) ELSE 0 END) AS dcg,
           min(rank) AS first_rank
    FROM hit GROUP BY method, corpus, qid
  )
SELECT m.method, q.corpus, q.id AS qid, q.kind,
       coalesce(a.hits10, 0) * 1.0 / n.n AS recall10,
       coalesce(a.hits50, 0) * 1.0 / n.n AS recall50,
       coalesce(a.dcg, 0) / i.idcg AS ndcg10,
       CASE WHEN a.first_rank <= 10 THEN 1.0 / a.first_rank ELSE 0 END AS mrr
FROM query q
CROSS JOIN methods m
JOIN n ON n.corpus = q.corpus AND n.qid = q.id
JOIN ideal i ON i.corpus = q.corpus AND i.qid = q.id
LEFT JOIN agg a ON a.method = m.method AND a.corpus = q.corpus AND a.qid = q.id;

.mode column
.headers on

SELECT 'documents' AS item, corpus, count(*) AS n FROM doc GROUP BY corpus
UNION ALL
SELECT 'expected files not indexed', e.corpus, count(*)
FROM expected e LEFT JOIN doc d ON d.corpus = e.corpus AND d.path = e.path
WHERE d.id IS NULL GROUP BY e.corpus;

.print
.print By method
SELECT method, count(*) AS queries,
       round(avg(recall10), 3) AS recall10, round(avg(recall50), 3) AS recall50,
       round(avg(ndcg10), 3) AS ndcg10, round(avg(mrr), 3) AS mrr
FROM score GROUP BY method ORDER BY method;

.print
.print By method and query kind
SELECT kind, method, count(*) AS queries,
       round(avg(recall10), 3) AS recall10, round(avg(recall50), 3) AS recall50,
       round(avg(ndcg10), 3) AS ndcg10, round(avg(mrr), 3) AS mrr
FROM score GROUP BY kind, method ORDER BY kind, method;

.print
.print By corpus and method
SELECT corpus, method,
       round(avg(recall10), 3) AS recall10, round(avg(recall50), 3) AS recall50,
       round(avg(ndcg10), 3) AS ndcg10, round(avg(mrr), 3) AS mrr
FROM score GROUP BY corpus, method ORDER BY corpus, method;
