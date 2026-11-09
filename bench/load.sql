-- Load one corpus and its labels. Parameters: @corpus, @root, @labels.
-- The corpora are pinned, clean copies, so what is on disk is what is tracked.

INSERT INTO doc(corpus, path, body)
SELECT @corpus, path, CAST(data AS TEXT)
FROM (SELECT substr(name, length(@root) + 2) AS path, data
      FROM fsdir(@root)
      WHERE mode & 61440 = 32768)
WHERE EXISTS (SELECT 1 FROM corpus_rule r
              WHERE r.corpus = @corpus AND r.keep = 1 AND path GLOB r.glob)
  AND NOT EXISTS (SELECT 1 FROM corpus_rule r
                  WHERE r.corpus = @corpus AND r.keep = 0 AND path GLOB r.glob)
  AND length(data) <= 2000000
  AND instr(substr(data, 1, 8000), x'00') = 0;  -- binary test, as git does it

INSERT INTO query(corpus, id, kind, question)
SELECT @corpus,
       json_extract(value, '$.id'),
       json_extract(value, '$.kind'),
       json_extract(value, '$.question')
FROM json_each(readfile(@labels), '$.queries');

INSERT INTO expected(corpus, qid, path)
SELECT @corpus, json_extract(q.value, '$.id'), e.value
FROM json_each(readfile(@labels), '$.queries') AS q,
     json_each(q.value, '$.expected_ids') AS e;
