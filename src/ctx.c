/* ctx: durable, shared, searchable agent sessions and knowledge.
 *
 * One binary on SQLite and libfossil. All state lives in one SQLite file:
 * the ctx tables (schema/index.sql) beside libfossil host repositories.
 */
#define _GNU_SOURCE /* memmem */
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

/* Secret removal. Fossil history is hard to purge, so this runs before anything
 * is stored. It is a single left-to-right pass with no regular expressions. */
#define REDACTED "[REDACTED]"

static int c_alnum(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}
static int c_word(unsigned char c) { return c_alnum(c) || c == '_'; }
static int c_b64(unsigned char c) { return c_word(c) || c == '-'; }
static int c_bearer(unsigned char c) { return c_b64(c) || c == '.'; }
static int c_slack(unsigned char c) { return c_alnum(c) || c == '-'; }
static int c_upnum(unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z'); }
static int c_hex(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static int c_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
static int c_value(unsigned char c) {
  return !c_space(c) && c != '"' && c != '\'' && c != ',' && c != ';' && c != ')' && c != '}';
}

static size_t span(const char *s, size_t n, size_t i, int (*ok)(unsigned char)) {
  size_t j = i;
  while (j < n && ok((unsigned char)s[j])) j++;
  return j;
}

static int at(const char *s, size_t n, size_t i, const char *lit) {
  size_t m = strlen(lit);
  return i + m <= n && memcmp(s + i, lit, m) == 0;
}

static int at_ci(const char *s, size_t n, size_t i, const char *lit) {
  size_t m = strlen(lit);
  if (i + m > n) return 0;
  for (size_t k = 0; k < m; k++) {
    char a = s[i + k], b = lit[k];
    if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
    if (a != b) return 0;
  }
  return 1;
}

/* The end of a prefixed token starting at i, or 0. */
static size_t token_end(const char *s, size_t n, size_t i) {
  static const char *const gh[] = {"ghp_", "gho_", "ghu_", "ghs_", "ghr_", NULL};
  for (int k = 0; gh[k]; k++)
    if (at(s, n, i, gh[k])) {
      size_t e = span(s, n, i + 4, c_alnum);
      return e - (i + 4) >= 20 ? e : 0;
    }
  size_t e;
  if (at(s, n, i, "github_pat_")) {
    e = span(s, n, i + 11, c_word);
    return e - (i + 11) >= 30 ? e : 0;
  }
  if (at(s, n, i, "sk-")) {
    e = span(s, n, i + 3, c_b64);
    return e - (i + 3) >= 20 ? e : 0;
  }
  if (at(s, n, i, "AKIA")) {
    e = span(s, n, i + 4, c_upnum);
    return e - (i + 4) >= 16 ? e : 0;
  }
  if (at(s, n, i, "xox") && i + 4 < n && s[i + 4] == '-' && strchr("abprs", s[i + 3])) {
    e = span(s, n, i + 5, c_slack);
    return e - (i + 5) >= 20 ? e : 0;
  }
  if (at(s, n, i, "dp.") && i + 5 < n && s[i + 5] == '.') {
    e = span(s, n, i + 6, c_alnum);
    return e - (i + 6) >= 20 ? e : 0;
  }
  if (at(s, n, i, "eyJ")) { /* JWT: three base64url parts */
    size_t a = span(s, n, i, c_b64);
    if (a - i < 15 || a >= n || s[a] != '.') return 0;
    size_t b = span(s, n, a + 1, c_b64);
    if (b - (a + 1) < 15 || b >= n || s[b] != '.') return 0;
    size_t c = span(s, n, b + 1, c_b64);
    return c - (b + 1) >= 10 ? c : 0;
  }
  return 0;
}

/* After a keyword: optional quotes and spaces around a required ':' or '='.
 * Returns the index of the value, or 0 if this is not an assignment. */
static size_t assignment_value(const char *s, size_t n, size_t i) {
  size_t j = i;
  int sep = 0;
  while (j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '"' || s[j] == '\'' || s[j] == ':' ||
                   s[j] == '=')) {
    if (s[j] == ':' || s[j] == '=') sep = 1;
    j++;
  }
  return sep ? j : 0;
}

/* Appends s with secrets replaced. */
static void add_redacted(buf *out, const char *s, size_t n) {
  static const char *const words[] = {"password", "passwd", "token",  "secret",
                                      "api_key",  "api-key", "apikey", NULL};
  static const char *const hexwords[] = {"key", "auth", "credential", NULL};
  size_t i = 0, done = 0;
  while (i < n) {
    size_t end = 0, from = i;
    int prev_ok = i == 0 || !c_word((unsigned char)s[i - 1]);
    if (s[i] == '-' && at(s, n, i, "-----BEGIN ")) {
      size_t line = i;
      while (line < n && s[line] != '\n') line++;
      if (memmem(s + i, line - i, "PRIVATE KEY-----", 16)) {
        const char *close = memmem(s + line, n - line, "PRIVATE KEY-----", 16);
        end = close ? (size_t)(close - s) + 16 : n;
      }
    } else if (prev_ok) {
      end = token_end(s, n, i);
      if (!end && at_ci(s, n, i, "bearer")) {
        size_t v = span(s, n, i + 6, c_space);
        size_t e = span(s, n, v, c_bearer);
        if (v > i + 6 && e - v >= 24) {
          from = v;
          end = e;
        }
      }
    }
    if (!end && s[i] == ':' && at(s, n, i, "://")) {
      size_t a = i + 3, j = a, colon = 0;
      while (j < n && s[j] != '/' && s[j] != '@' && !c_space((unsigned char)s[j])) {
        if (s[j] == ':' && !colon) colon = j;
        j++;
      }
      if (j < n && s[j] == '@' && colon && j - colon - 1 >= 6) {
        from = a;
        end = j;
      }
    }
    if (!end) {
      for (int k = 0; !end && words[k]; k++)
        if (at_ci(s, n, i, words[k])) {
          size_t v = assignment_value(s, n, i + strlen(words[k]));
          size_t e = v ? span(s, n, v, c_value) : 0;
          if (v && e - v >= 8 && !strchr("$<{[", s[v])) {
            from = v;
            end = e;
          }
        }
      for (int k = 0; !end && hexwords[k]; k++)
        if (at_ci(s, n, i, hexwords[k])) {
          size_t w = span(s, n, i, c_word);
          size_t v = assignment_value(s, n, w);
          size_t e = v ? span(s, n, v, c_hex) : 0;
          if (v && e - v >= 32) {
            from = v;
            end = e;
          }
        }
    }
    if (end) {
      buf_add(out, s + done, from - done);
      buf_str(out, REDACTED);
      done = i = end;
    } else {
      i++;
    }
  }
  buf_add(out, s + done, n - done);
}

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
  buf body = {0}, clean = {0};
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
          clean.n = 0;
          add_redacted(&clean, text, n);
          if (is_text) buf_add(&body, clean.p, clean.n);
          else add_tool_text(&body, clean.p, clean.n);
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
  free(clean.p);
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
