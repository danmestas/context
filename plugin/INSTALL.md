# ctx

ctx archives your Claude Code sessions, with secrets redacted, into a private
Fossil repository on this machine, and searches them. Per project it also keeps
tickets and a wiki whose every claim cites an exact source version.

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
ctx turn ID                               # one turn in full, with its neighbours
ctx audit                                 # secret-shaped strings left in the archive
ctx project add NAME --root DIR           # a shared repository for tickets, sources, wiki
ctx ticket new "Fix the importer"         # then ready, claim, done
ctx remote me URL && ctx sync             # share the archive with another machine
```

`ctx` with no arguments lists every command.

## Remove

```sh
claude plugin uninstall ctx@ctx
```

The archive in `~/.ctx` stays until you delete it.

ctx is under the BSD 2-Clause license in `LICENSE`. `LICENSE.libfossil` covers
the libfossil code built into `bin/ctx`; SQLite is in the public domain.
