# ctx

ctx archives your Claude Code sessions, with secrets redacted, into a private
Fossil repository on this machine, and searches them. It also keeps
tickets, and per project a wiki whose every claim cites an exact source version.

This directory is a Claude Code plugin: `bin/ctx`, the `ctx` and `ctx-wiki` skills,
and hooks that archive each session as it runs.

## Install

```sh
claude plugin marketplace add /path/to/this/directory
claude plugin install ctx@ctx
ln -s /path/to/this/directory/bin/ctx ~/.local/bin/ctx   # for your own shell
ctx init                                                 # creates ~/.ctx/ctx.sqlite
ctx scan                                                 # archives transcripts you already have
```

Inside Claude Code, `ctx` is on the Bash tool's PATH while the plugin is enabled.
Set `CTX_DB` to keep the database somewhere other than `~/.ctx/ctx.sqlite`.

## Use

```sh
ctx search why did the sync test hang     # past sessions, this project first
ctx turn ID 2 5                           # a turn, with 2 before and 5 after
ctx audit                                 # secret-shaped strings left in the archive
ctx project add NAME --clone REPO         # a project, for its sources and wiki
ctx ticket new "Fix the importer"         # then ready, claim, done
ctx sync                                  # repositories that have a remote
```

`ctx` with no arguments lists every command. The full guide, including how to share
the archive between machines, is `docs/howto.md` in the source.

## Remove

```sh
claude plugin uninstall ctx@ctx
```

The archive in `~/.ctx` stays until you delete it.

ctx is under the BSD 2-Clause license in `LICENSE`. `LICENSE.libfossil` covers
the libfossil code built into `bin/ctx`; SQLite is in the public domain.
