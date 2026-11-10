# ctx

ctx keeps the work you do with coding agents. It archives every Claude Code
session, with secrets redacted, into a private Fossil repository on your machine
and makes it searchable, so an agent can find why something was decided or what
already failed. Per project it keeps tickets, version-pinned sources and a wiki
whose every claim quotes an exact source version. Repositories sync between
machines and people.

It is one C binary built from SQLite and libfossil, with everything in one SQLite
file per machine.

## What it does

- **Archives sessions.** Hooks capture each session as it runs; a periodic scan
  catches anything missed. Tool output is kept, trimmed, and known secret shapes
  are replaced with `[REDACTED]` before anything is stored.
- **Searches them.** `ctx search` ranks turns with SQLite's FTS5, this project
  first; `ctx turn` reads around a hit. The `ctx` skill teaches agents to do both.
- **Audits the archive** for secret-shaped strings that redaction missed, and
  for values you already know are secret.
- **Tracks tickets** for each project, offered to agents at the start of a
  session.
- **Keeps sources with provenance.** Each source records where it came from, its
  hash, and how long it can be trusted. Sources are superseded, never edited.
- **Compiles a wiki** that refuses any claim it cannot trace to a literal quote
  in a pinned source version, and retires pages whose sources are gone.
- **Syncs** the private archive and project repositories with Fossil servers.

## Install

From a release archive, which is a Claude Code plugin with the binary, the skills
and the hooks:

```sh
tar xzf ctx-0.0.1-darwin-arm64.tar.gz
claude plugin marketplace add ./ctx-0.0.1-darwin-arm64
claude plugin install ctx@ctx
ln -s "$PWD/ctx-0.0.1-darwin-arm64/bin/ctx" ~/.local/bin/ctx
ctx init
ctx scan
```

Or build from source with a C compiler and zlib: `make`, then see
[docs/howto.md](docs/howto.md#install-from-source) for the hooks.

## Start

```sh
ctx search sync test hangs        # past sessions, this project first
ctx turn 1182 2 5                 # a turn with 2 before and 5 after
ctx audit                         # secret-shaped strings left in the archive
ctx project add myproj --clone ~/fossils/myproj.fossil   # this directory's project
ctx ticket new "Fix the importer"
```

[docs/howto.md](docs/howto.md) covers every task: projects, tickets, sources,
the wiki, syncing machines, rebuilding and measuring the skill.

## How it is stored

Everything lives in `~/.ctx/ctx.sqlite` (or `$CTX_DB`), as SQLite tables and as
Fossil repositories held inside it:

- `repo:me` is your private repository. Each session is a technote, one per
  session per day, tagged with its project.
- Each project has a shared repository: sources are check-ins and the wiki is
  Markdown wiki pages.
- Tickets are in `repo:me` for now, each tagged with its project.
- The search index, citations and links are derived from the repositories.
  `ctx rebuild` drops and rebuilds them.

The schema is in `schema/`: `state.sql` holds what is kept, `index.sql` what is
derived, `ticket-table.sql` the ticket fields and `check.sql` checks for both.

## Building and checks

`make` builds `./ctx` from the SQLite and libfossil sources in `vendor/`, and
`make test` runs the suite. `make check` runs everything CI runs, and needs
python3 and sqlite3 as well:

- the suite, and the suite again under AddressSanitizer and
  UndefinedBehaviorSanitizer;
- a short fuzz of the redactor and the parsers, where a clang with libFuzzer
  exists;
- on Linux, the suite and every saved fuzz input under
  [Fil-C](https://fil-c.org), which makes any memory-safety error a crash
  (`tools/filc.sh` fetches a pinned release);
- the bench and schema checks.

## Releases

`make dist` builds a release archive for this machine in `build/dist/`.
`tools/dist-linux.sh [amd64|arm64]` builds a Linux one inside Ubuntu 22.04 under
docker, so it runs on glibc 2.34 or later; docker on an Apple Silicon Mac builds
both. `plugin/INSTALL.md` becomes the archive's README.

## Measuring

- `eval/` measures the `ctx` skill against questions about past work, so a change
  to the skill is judged by results. See [eval/README.md](eval/README.md).
- `bench/` scores retrieval, grep against BM25, on pinned corpora. `bench/run.sh`
  reads them from `~/projects/ctx-corpora` (or `CTX_CORPORA`) and needs ripgrep
  and a `sqlite3` that can load extensions: on macOS, Homebrew's.

## License

BSD 2-Clause; see [LICENSE](LICENSE). The libfossil code in `vendor/libfossil`
is under its own BSD license, in `vendor/libfossil/LICENSE`. SQLite is in the
public domain.
