/* Stats: counting ctx calls in any shell command, and in any turn body through the
 * SQL function, ends and never reads past the end. */
#define CTX_NO_MAIN
#include "../src/ctx.c"

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n) {
  static sqlite3 *db;
  if (!db) {
    db = db_open(":memory:");
    sqlite3_create_function(db, "ctx_calls", 2, SQLITE_UTF8, NULL, sql_ctx_calls, NULL, NULL);
  }
  if (count_ctx_runs((const char *)data, n, "search") < 0) __builtin_trap();
  sqlite3_stmt *q = db_prepare(db, "SELECT ctx_calls(?1, 'turn')");
  sqlite3_bind_text(q, 1, (const char *)data, (int)n, SQLITE_STATIC);
  sqlite3_step(q);
  sqlite3_finalize(q);
  return 0;
}
