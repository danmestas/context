Amalgamations from libfossil check-in 7d9634ac5c (branch `onefile`), with the
SQLite 3.55.0 they are built against. Replace these files to update; do not edit
them. libfossil is BSD-2-Clause (see LICENSE); SQLite is public domain.

Since e84af25d79 this adds: backlinks (the repository's backlink table is written
when check-ins, wiki pages, forum posts and tickets are crosslinked or rebuilt),
the SHA-1 alignment fix (fsl_sha1_update no longer does misaligned 32-bit loads),
and the rest of trunk up to f2983dcd78. No public API, SQL function or schema
change.
