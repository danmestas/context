-- Checks that the index schema behaves. Run after index.sql in one sqlite3 session:
--   sqlite3 :memory: -bail -cmd '.read schema/index.sql' '.read schema/check.sql'
-- A failed check stops the run with an integer overflow error.

PRAGMA foreign_keys = ON;

CREATE TEMP VIEW fail(x) AS SELECT abs(-9223372036854775808);

INSERT INTO ctx_repo(id, project, name, path, scope)
VALUES (1, 'zit', 'sources', '/r/zit/sources.fossil', 'shared');

INSERT INTO ctx_doc(id, project, repo_id, kind, name, hash, size, mtime) VALUES
  (1, 'zit', 1, 'source', '_sources/spec.md', 'aaa', 10, 1),
  (2, 'zit', 1, 'wiki', 'concepts/Cache', 'bbb', 10, 1);

INSERT INTO ctx_chunk(id, doc_id, seq, heading, body) VALUES
  (1, 1, 0, 'Spec', 'the mmap_cache decision'),
  (2, 2, 0, 'Cache', 'page cache notes');

-- Search finds an inserted chunk, stems, and keeps underscored names whole.
SELECT CASE WHEN (SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH 'decisions') = 1
            THEN 1 ELSE (SELECT x FROM fail) END;
SELECT CASE WHEN (SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH '"mmap_cache"') = 1
            THEN 1 ELSE (SELECT x FROM fail) END;

-- An update replaces the old text in the search index.
UPDATE ctx_chunk SET body = 'rewritten text' WHERE id = 1;
SELECT CASE WHEN (SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH 'decisions') = 0
            AND (SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH 'rewritten') = 1
            THEN 1 ELSE (SELECT x FROM fail) END;

-- A page compiled from the current source version is not stale.
INSERT INTO ctx_link(src_id, kind, dst_kind, dst_name, dst_hash)
VALUES (2, 'compiled_from', 'source', '_sources/spec.md', 'aaa');
SELECT CASE WHEN (SELECT count(*) FROM ctx_stale_wiki) = 0
            THEN 1 ELSE (SELECT x FROM fail) END;

-- A new source version makes it stale.
UPDATE ctx_doc SET hash = 'ccc' WHERE id = 1;
SELECT CASE WHEN (SELECT count(*) FROM ctx_stale_wiki WHERE page = 'concepts/Cache') = 1
            THEN 1 ELSE (SELECT x FROM fail) END;

-- Deleting a document removes its chunks, its search entries and its own links,
-- and leaves links other documents hold pointing at it.
DELETE FROM ctx_doc WHERE id = 1;
SELECT CASE WHEN (SELECT count(*) FROM ctx_chunk WHERE doc_id = 1) = 0
            AND (SELECT count(*) FROM ctx_chunk_fts WHERE ctx_chunk_fts MATCH 'rewritten') = 0
            AND (SELECT count(*) FROM ctx_link WHERE src_id = 2) = 1
            THEN 1 ELSE (SELECT x FROM fail) END;

-- With its source gone, the page is stale.
SELECT CASE WHEN (SELECT count(*) FROM ctx_stale_wiki WHERE current_hash IS NULL) = 1
            THEN 1 ELSE (SELECT x FROM fail) END;

-- A ticket is ready only when it is open and its blockers have finished.
INSERT INTO ctx_doc(id, project, repo_id, kind, name, status, hash, size, mtime) VALUES
  (10, 'zit', 1, 'ticket', 'first', 'Open', 'd1', 1, 1),
  (11, 'zit', 1, 'ticket', 'second', 'Open', 'd2', 1, 1),
  (12, 'zit', 1, 'ticket', 'claimed', 'Claimed', 'd3', 1, 1);
INSERT INTO ctx_link(src_id, kind, dst_kind, dst_name) VALUES (11, 'blocked_by', 'ticket', 'first');
SELECT CASE WHEN (SELECT group_concat(ticket) FROM ctx_ready_ticket) = 'first'
            THEN 1 ELSE (SELECT x FROM fail) END;
UPDATE ctx_doc SET status = 'Done' WHERE id = 10;
SELECT CASE WHEN (SELECT group_concat(ticket) FROM ctx_ready_ticket) = 'second'
            THEN 1 ELSE (SELECT x FROM fail) END;

-- A blocker that has not been indexed still blocks.
INSERT INTO ctx_link(src_id, kind, dst_kind, dst_name) VALUES (11, 'blocked_by', 'ticket', 'missing');
SELECT CASE WHEN (SELECT count(*) FROM ctx_ready_ticket) = 0
            THEN 1 ELSE (SELECT x FROM fail) END;

-- Deleting the repository clears everything indexed from it.
DELETE FROM ctx_repo WHERE id = 1;
SELECT CASE WHEN (SELECT count(*) FROM ctx_doc) = 0 AND (SELECT count(*) FROM ctx_link) = 0
            THEN 1 ELSE (SELECT x FROM fail) END;

SELECT 'schema checks passed';
