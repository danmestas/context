# context

ctx keeps agent sessions and knowledge durable, shares them between people and
machines, and makes them cheap to search. It is being built as one C binary on
SQLite and libfossil. So far it creates its database, archives agent
transcripts, redacted, into a private repository, and searches them.

## What is here

- `schema/index.sql`: ctx's tables in the machine's one SQLite file: the search
  index, project mapping and capture positions.
- `schema/ticket-table.sql`: the tickets agents and people work on, for each
  shared Fossil repository.
- `schema/check.sql`: checks for the index schema.
- `bench/`: a retrieval bench that scores grep and BM25, with the metrics in SQL.

Sources live in each project's repository under `sources/`. `ctx source add` keeps
the exact bytes and writes `NAME.origin.json` beside them, saying where the source
came from and how long it can be trusted. `ctx source check` fails if a source has
no origin or has changed since it was recorded, so a repository's CI can run it.

Source documents are check-ins, the compiled wiki is Fossil wiki in Markdown,
work items are tickets, and session transcripts are technotes in a per-person
repository.

## Building

`make` builds `./ctx` from the SQLite and libfossil sources in `vendor/`, and
`make test` checks it. It needs a C compiler and zlib.

## The bench

`bench/run.sh` reads pinned corpus copies and their labels from
`~/projects/ctx-corpora` (or `CTX_CORPORA`). It needs ripgrep and a `sqlite3` that
can load extensions, so on macOS use Homebrew's rather than `/usr/bin/sqlite3`.
