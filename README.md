# context

ctx keeps agent sessions and knowledge durable, shares them between people and
machines, and makes them cheap to search. It is being built as one C binary on
SQLite and libfossil. So far it creates its database, archives agent
transcripts, redacted, into a private repository, and searches them.

## What is here

- `schema/state.sql`: the tables in the machine's one SQLite file that are kept:
  project mapping, capture positions, audit results and the wiki log.
- `schema/index.sql`: the tables derived from the repositories, such as the search
  index and citations. `ctx rebuild` drops and rebuilds them.
- `schema/ticket-table.sql`: the tickets agents and people work on, for each
  shared Fossil repository.
- `schema/check.sql`: checks for the index schema.
- `bench/`: a retrieval bench that scores grep and BM25, with the metrics in SQL.

Sources live in each project's repository under `sources/`. `ctx source add` keeps
the exact bytes and writes `NAME.origin.json` beside them, saying where the source
came from and how long it can be trusted. `ctx source check` fails if a source has
no origin or has changed since it was recorded, so a repository's CI can run it.

Old information is retired without being erased. `ctx source supersede` records
that a source was replaced, amended or retracted, and search stops serving it unless
asked with `--history` or `--as-of DATE`. `ctx wiki repin` moves each claim whose
quote survives and opens a ticket for each one that does not.

Source documents are check-ins, the compiled wiki is Fossil wiki in Markdown,
work items are tickets, and session transcripts are technotes in a per-person
repository.

## Building

`make` builds `./ctx` from the SQLite and libfossil sources in `vendor/`, and
`make test` checks it. It needs a C compiler and zlib.

`make check` runs everything CI runs: the suite, the suite again under
AddressSanitizer and UndefinedBehaviorSanitizer, a short fuzz of the redactor and
the parsers where a clang with libFuzzer exists, the suite and the saved fuzz
inputs under [Fil-C](https://fil-c.org) on Linux (`tools/filc.sh` fetches a pinned
release), and the bench and schema checks. It also needs python3 and sqlite3.

## Releases

A release archive is a Claude Code plugin: `bin/ctx`, the `ctx` and `ctx-wiki`
skills, and the hooks that archive each session. `make dist` builds one for this
machine in `build/dist/`; `tools/dist-linux.sh [amd64|arm64]` builds a Linux one
in Ubuntu 22.04 under docker, so it runs on glibc 2.34 or later; docker on an Apple
Silicon Mac builds both. `plugin/INSTALL.md` becomes the archive's README and says how to install it.

## The bench

`bench/run.sh` reads pinned corpus copies and their labels from
`~/projects/ctx-corpora` (or `CTX_CORPORA`). It needs ripgrep and a `sqlite3` that
can load extensions, so on macOS use Homebrew's rather than `/usr/bin/sqlite3`.
