-- Rank files for the grep baseline, the way an agent reads grep output:
-- filename matches first, then how many query terms hit, then total matches.
-- Only files in the indexed set count.

INSERT INTO result(method, corpus, qid, rank, path)
SELECT 'grep', corpus, qid, rnk, path
FROM (
  SELECT t.corpus, t.qid, g.path,
         row_number() OVER (
           PARTITION BY t.corpus, t.qid
           ORDER BY sum(instr(lower(g.path), t.term) > 0) DESC,
                    count(DISTINCT t.term) DESC,
                    sum(g.n) DESC,
                    g.path
         ) AS rnk
  FROM grep_term t
  JOIN grep_hit g ON g.corpus = t.corpus AND g.term = t.term
  JOIN doc d ON d.corpus = g.corpus AND d.path = g.path
  GROUP BY t.corpus, t.qid, g.path
)
WHERE rnk <= 50;
