Amalgamations from libfossil check-in 8aa1823ae1 (branch `sql-ext-int`; full hash in CHECKIN),
with the SQLite 3.55.0 they are built against. Replace these files to update; do not edit
them. libfossil is BSD-2-Clause (see LICENSE); SQLite is public domain.

`sql-ext-int` is trunk through b5a08d2b94 with the `onefile` and `cowoco` branches (which ctx
used before, from 7d9634ac5c) and the `anypipe` sync-channel branch merged on top. Since
7d9634ac5c this adds: the autosync fixes (global `pullonly`/`dont-push` honoured; with no
autosync setting the pulls before commit, update and merge no longer push), the onefile
write-lock fix (SQLite's busy handler now waits for another connection's lock instead of
failing at once with "database is locked"), namespacing, push-unclustered, sync reply limits,
an ssh exit-127 hint, and caller-supplied sync channels (`fsl_xfer_config::channel`), which ctx
does not use. sqlite3.c and sqlite3.h are unchanged.
