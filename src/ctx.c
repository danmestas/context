/* ctx: durable, shared, searchable agent sessions and knowledge.
 *
 * One binary on SQLite and libfossil. All state lives in one SQLite file:
 * the ctx tables (schema/index.sql) beside libfossil host repositories.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "sqlite3.h"
#include "schema.h"

#define CTX_VERSION "0.0.1"

/* A tool's output is kept up to this size at each end; the middle is cut. */
#define TOOL_KEEP (16 * 1024)

int fsl_sqlext_init(sqlite3 *db, char **err, const void *api);

static void die(const char *fmt, ...) {
  va_list ap;
  fputs("ctx: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(1);
}

static void db_exec(sqlite3 *db, const char *sql) {
  char *err = NULL;
  if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) die("%s", err);
}

static sqlite3 *db_open(const char *path) {
  sqlite3 *db = NULL;
  if (sqlite3_open(path, &db) != SQLITE_OK) die("cannot open %s: %s", path, sqlite3_errmsg(db));
  sqlite3_busy_timeout(db, 30000);
  return db;
}

static sqlite3_stmt *db_prepare(sqlite3 *db, const char *sql) {
  sqlite3_stmt *q = NULL;
  if (sqlite3_prepare_v2(db, sql, -1, &q, NULL) != SQLITE_OK) die("%s", sqlite3_errmsg(db));
  return q;
}

static int db_int(sqlite3 *db, const char *sql) {
  sqlite3_stmt *q = db_prepare(db, sql);
  int v = sqlite3_step(q) == SQLITE_ROW ? sqlite3_column_int(q, 0) : 0;
  sqlite3_finalize(q);
  return v;
}

/* ~/.ctx/ctx.sqlite, or $CTX_DB. The caller frees the result. */
static char *db_path(void) {
  const char *env = getenv("CTX_DB");
  if (env && *env) return strdup(env);
  const char *home = getenv("HOME");
  if (!home || !*home) die("HOME is not set; set CTX_DB");
  size_t n = strlen(home) + sizeof "/.ctx/ctx.sqlite";
  char *p = malloc(n);
  if (!p) die("out of memory");
  snprintf(p, n, "%s/.ctx", home);
  if (mkdir(p, 0700) != 0 && errno != EEXIST) die("cannot create %s: %s", p, strerror(errno));
  snprintf(p, n, "%s/.ctx/ctx.sqlite", home);
  return p;
}

static int cmd_version(void) {
  sqlite3 *db = db_open(":memory:");
  int fossil = db_int(db, "SELECT count(*) FROM pragma_function_list WHERE name='fsl_open'");
  int fts5 = sqlite3_compileoption_used("ENABLE_FTS5");
  sqlite3_close(db);
  if (!fossil) die("libfossil is not registered");
  if (!fts5) die("this SQLite has no FTS5");
  printf("ctx %s\nsqlite %s\n", CTX_VERSION, sqlite3_libversion());
  return 0;
}

static int cmd_init(void) {
  char *path = db_path();
  sqlite3 *db = db_open(path);
  db_exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;");
  if (db_int(db, "PRAGMA user_version") == 0) {
    db_exec(db, "BEGIN IMMEDIATE");
    db_exec(db, ctx_schema);
    db_exec(db, "COMMIT");
  }
  printf("%s\n", path);
  sqlite3_close(db);
  free(path);
  return 0;
}

/* A growable byte buffer. */
typedef struct {
  char *p;
  size_t n, cap;
} buf;

static void buf_add(buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t want = b->cap ? b->cap : 4096;
    while (want < b->n + n + 1) want *= 2;
    char *np = realloc(b->p, want);
    if (!np) die("out of memory");
    b->p = np;
    b->cap = want;
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = 0;
}

static void buf_str(buf *b, const char *s) { buf_add(b, s, strlen(s)); }

static int is_utf8_cont(char c) { return ((unsigned char)c & 0xC0) == 0x80; }

/* Appends tool output, cutting the middle of anything too long at character
 * boundaries so the result stays valid UTF-8. */
static void add_tool_text(buf *b, const char *s, size_t n) {
  if (n <= 2 * TOOL_KEEP) {
    buf_add(b, s, n);
    return;
  }
  size_t head = TOOL_KEEP;
  while (head > 0 && is_utf8_cont(s[head])) head--;
  size_t tail = n - TOOL_KEEP;
  while (tail < n && is_utf8_cont(s[tail])) tail++;
  char note[64];
  snprintf(note, sizeof note, "\n[... %zu bytes cut ...]\n", tail - head);
  buf_add(b, s, head);
  buf_str(b, note);
  buf_add(b, s + tail, n - tail);
}

/* Harness text injected into turns, which is not part of the conversation. */
static int is_noise(const char *s) {
  static const char *const prefixes[] = {
      "<system-reminder",  "<command-",        "<local-command", "<task-notification",
      "<teammate-message", "<cross-session",   NULL};
  while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
  for (int i = 0; prefixes[i]; i++)
    if (strncmp(s, prefixes[i], strlen(prefixes[i])) == 0) return 1;
  return 0;
}

static int is_blank(const char *s, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r') return 0;
  return 1;
}

/* The part of a path between its last '/' and its first following '.'. */
static void session_id(const char *path, char out[9]) {
  const char *base = strrchr(path, '/');
  base = base ? base + 1 : path;
  size_t n = strcspn(base, ".");
  if (n > 8) n = 8;
  memcpy(out, base, n);
  out[n] = 0;
}

static const char sql_meta[] =
    "SELECT json_extract(?1,'$.message.role'), json_extract(?1,'$.isSidechain'),"
    "       json_extract(?1,'$.timestamp'), json_extract(?1,'$.uuid')"
    " WHERE json_valid(?1)";

/* One row per part of a message, in order: its kind and its text. */
static const char sql_parts[] =
    "SELECT 'text', json_extract(?1,'$.message.content')"
    " WHERE json_type(?1,'$.message.content')='text'"
    " UNION ALL "
    "SELECT type, part FROM ("
    "  SELECT e.key AS k, json_extract(e.value,'$.type') AS type,"
    "    CASE json_extract(e.value,'$.type')"
    "      WHEN 'text' THEN json_extract(e.value,'$.text')"
    "      WHEN 'tool_use' THEN json_extract(e.value,'$.name')"
    "                           || ' ' || coalesce(json_extract(e.value,'$.input'),'')"
    "      WHEN 'tool_result' THEN CASE json_type(e.value,'$.content')"
    "        WHEN 'text' THEN json_extract(e.value,'$.content')"
    "        WHEN 'array' THEN (SELECT group_concat(json_extract(x.value,'$.text'), char(10))"
    "                           FROM json_each(e.value,'$.content') x"
    "                           WHERE json_extract(x.value,'$.text') IS NOT NULL)"
    "      END"
    "    END AS part"
    "  FROM json_each(?1,'$.message.content') e"
    "  WHERE json_type(?1,'$.message.content')='array'"
    "    AND json_type(e.value)='object'"
    "  ORDER BY k)";

/* Writes one numbered, conversation-only record per user or assistant turn. */
static int cmd_extract(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) die("cannot open %s: %s", path, strerror(errno));
  sqlite3 *db = db_open(":memory:");
  sqlite3_stmt *meta = db_prepare(db, sql_meta);
  sqlite3_stmt *parts = db_prepare(db, sql_parts);
  char sid[9];
  session_id(path, sid);

  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  long turn = 0;
  buf body = {0};
  while ((len = getline(&line, &cap, f)) != -1) {
    sqlite3_bind_text(meta, 1, line, (int)len, SQLITE_STATIC);
    if (sqlite3_step(meta) == SQLITE_ROW) {
      const char *role = (const char *)sqlite3_column_text(meta, 0);
      if (role && (!strcmp(role, "user") || !strcmp(role, "assistant")) &&
          sqlite3_column_int(meta, 1) == 0) {
        body.n = 0;
        int first = 1;
        sqlite3_bind_text(parts, 1, line, (int)len, SQLITE_STATIC);
        while (sqlite3_step(parts) == SQLITE_ROW) {
          const char *kind = (const char *)sqlite3_column_text(parts, 0);
          const char *text = (const char *)sqlite3_column_text(parts, 1);
          size_t n = (size_t)sqlite3_column_bytes(parts, 1);
          if (!kind || !text) continue;
          int is_text = !strcmp(kind, "text");
          if (!is_text && strcmp(kind, "tool_use") && strcmp(kind, "tool_result")) continue;
          if (is_text && is_noise(text)) continue;
          if (!first) buf_str(&body, "\n");
          first = 0;
          if (is_text) buf_add(&body, text, n);
          else add_tool_text(&body, text, n);
        }
        sqlite3_reset(parts);
        if (body.n && !is_blank(body.p, body.n)) {
          const char *ts = (const char *)sqlite3_column_text(meta, 2);
          const char *uuid = (const char *)sqlite3_column_text(meta, 3);
          printf("--- %s turn %ld %s %s %s\n", sid, ++turn, role, ts ? ts : "", uuid ? uuid : "");
          fwrite(body.p, 1, body.n, stdout);
          fputs("\n\n", stdout);
        }
      }
    }
    sqlite3_reset(meta);
  }
  free(line);
  free(body.p);
  sqlite3_finalize(meta);
  sqlite3_finalize(parts);
  sqlite3_close(db);
  fclose(f);
  return 0;
}

static int usage(void) {
  fputs("usage: ctx version\n"
        "       ctx init\n"
        "       ctx extract TRANSCRIPT\n",
        stderr);
  return 2;
}

int main(int argc, char **argv) {
  if (sqlite3_auto_extension((void (*)(void))fsl_sqlext_init) != SQLITE_OK)
    die("cannot register libfossil");
  if (argc == 2 && !strcmp(argv[1], "version")) return cmd_version();
  if (argc == 2 && !strcmp(argv[1], "init")) return cmd_init();
  if (argc == 3 && !strcmp(argv[1], "extract")) return cmd_extract(argv[2]);
  return usage();
}
