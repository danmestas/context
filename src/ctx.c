/* ctx: durable, shared, searchable agent sessions and knowledge.
 *
 * One binary on SQLite and libfossil. All state lives in one SQLite file:
 * the ctx tables (schema/index.sql) beside libfossil host repositories.
 */
#define _GNU_SOURCE /* memmem */
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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
  db_exec(db, "PRAGMA journal_mode=WAL;");
  if (db_int(db, "PRAGMA user_version") == 0) {
    db_exec(db, "BEGIN IMMEDIATE");
    db_exec(db, ctx_schema);
    db_exec(db, "COMMIT");
  }
  if (!db_int(db, "SELECT count(*) FROM sqlite_master WHERE name='fslrepo_me_config'")) {
    sqlite3_stmt *q = db_prepare(db, "SELECT fsl_open('repo:me', ?1, '{\"create\":true}')");
    sqlite3_bind_text(q, 1, getenv("USER") && *getenv("USER") ? getenv("USER") : "ctx", -1, SQLITE_STATIC);
    if (sqlite3_step(q) != SQLITE_ROW) die("cannot create the private repository: %s", sqlite3_errmsg(db));
    sqlite3_finalize(q);
  }
  db_exec(db, "INSERT OR IGNORE INTO ctx_repo(name, scope) VALUES ('me', 'private')");
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
    "       json_extract(?1,'$.timestamp'), json_extract(?1,'$.uuid'),"
    "       json_extract(?1,'$.cwd')"
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

/* One user or assistant turn, heap-allocated. */
typedef struct {
  char *role, *ts, *uuid, *cwd, *body;
  size_t body_n;
} turn_t;

static void turn_free(turn_t *t) {
  free(t->role);
  free(t->ts);
  free(t->uuid);
  free(t->cwd);
  free(t->body);
  memset(t, 0, sizeof *t);
}

typedef struct {
  sqlite3 *db;
  sqlite3_stmt *meta, *parts, *cwd;
  buf body, clean;
} extractor;

static void ex_open(extractor *e) {
  memset(e, 0, sizeof *e);
  e->db = db_open(":memory:");
  e->meta = db_prepare(e->db, sql_meta);
  e->parts = db_prepare(e->db, sql_parts);
  e->cwd = db_prepare(e->db, "SELECT json_extract(?1,'$.cwd') WHERE json_valid(?1)");
}

static void ex_close(extractor *e) {
  sqlite3_finalize(e->meta);
  sqlite3_finalize(e->parts);
  sqlite3_finalize(e->cwd);
  sqlite3_close(e->db);
  free(e->body.p);
  free(e->clean.p);
}

static char *dup_text(const unsigned char *s) {
  char *p = strdup(s ? (const char *)s : "");
  if (!p) die("out of memory");
  return p;
}

/* The working directory recorded on a transcript line, or NULL. Caller frees. */
static char *ex_cwd(extractor *e, const char *line, size_t len) {
  char *out = NULL;
  sqlite3_bind_text(e->cwd, 1, line, (int)len, SQLITE_STATIC);
  if (sqlite3_step(e->cwd) == SQLITE_ROW && sqlite3_column_text(e->cwd, 0))
    out = dup_text(sqlite3_column_text(e->cwd, 0));
  sqlite3_reset(e->cwd);
  return out;
}

/* Parses one transcript line. Returns 1 and fills t if it holds a turn to keep. */
static int ex_line(extractor *e, const char *line, size_t len, turn_t *t) {
  int kept = 0;
  sqlite3_bind_text(e->meta, 1, line, (int)len, SQLITE_STATIC);
  if (sqlite3_step(e->meta) == SQLITE_ROW) {
    const char *role = (const char *)sqlite3_column_text(e->meta, 0);
    if (role && (!strcmp(role, "user") || !strcmp(role, "assistant")) &&
        sqlite3_column_int(e->meta, 1) == 0) {
      e->body.n = 0;
      int first = 1;
      sqlite3_bind_text(e->parts, 1, line, (int)len, SQLITE_STATIC);
      while (sqlite3_step(e->parts) == SQLITE_ROW) {
        const char *kind = (const char *)sqlite3_column_text(e->parts, 0);
        const char *text = (const char *)sqlite3_column_text(e->parts, 1);
        size_t n = (size_t)sqlite3_column_bytes(e->parts, 1);
        if (!kind || !text) continue;
        int is_text = !strcmp(kind, "text");
        if (!is_text && strcmp(kind, "tool_use") && strcmp(kind, "tool_result")) continue;
        if (is_text && is_noise(text)) continue;
        if (!first) buf_str(&e->body, "\n");
        first = 0;
        e->clean.n = 0;
        add_redacted(&e->clean, text, n);
        if (is_text) buf_add(&e->body, e->clean.p, e->clean.n);
        else add_tool_text(&e->body, e->clean.p, e->clean.n);
      }
      sqlite3_reset(e->parts);
      if (e->body.n && !is_blank(e->body.p, e->body.n)) {
        t->role = dup_text((const unsigned char *)role);
        t->ts = dup_text(sqlite3_column_text(e->meta, 2));
        t->uuid = dup_text(sqlite3_column_text(e->meta, 3));
        t->cwd = dup_text(sqlite3_column_text(e->meta, 4));
        t->body = malloc(e->body.n + 1);
        if (!t->body) die("out of memory");
        memcpy(t->body, e->body.p, e->body.n + 1);
        t->body_n = e->body.n;
        kept = 1;
      }
    }
  }
  sqlite3_reset(e->meta);
  return kept;
}

/* Writes one numbered record per user or assistant turn. */
static int cmd_extract(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) die("cannot open %s: %s", path, strerror(errno));
  extractor e;
  ex_open(&e);
  char sid[9];
  session_id(path, sid);
  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  long n = 0;
  while ((len = getline(&line, &cap, f)) != -1) {
    turn_t t = {0};
    if (ex_line(&e, line, (size_t)len, &t)) {
      printf("--- %s turn %ld %s %s %s\n", sid, ++n, t.role, t.ts, t.uuid);
      fwrite(t.body, 1, t.body_n, stdout);
      fputs("\n\n", stdout);
      turn_free(&t);
    }
  }
  free(line);
  ex_close(&e);
  fclose(f);
  return 0;
}

/* A file is read again from the start if its first bytes change. */
#define HEAD_BYTES (64 * 1024)
/* Each committed batch covers about this much of a transcript. */
#define BATCH_BYTES (8 * 1024 * 1024)

/* FNV-1a over the first min(HEAD_BYTES, upto) bytes, as hex. */
static void head_hash(const char *path, long long upto, char out[17]) {
  unsigned long long h = 14695981039346656037ULL;
  FILE *f = fopen(path, "rb");
  if (!f) die("cannot open %s: %s", path, strerror(errno));
  long long left = upto < HEAD_BYTES ? upto : HEAD_BYTES;
  int c;
  while (left-- > 0 && (c = getc(f)) != EOF) {
    h ^= (unsigned char)c;
    h *= 1099511628211ULL;
  }
  fclose(f);
  snprintf(out, 17, "%016llx", h);
}

/* libfossil refuses connections with foreign keys on, so this one leaves them off.
 * Work that relies on cascades, such as a rebuild, uses its own connection. */
static sqlite3 *ctx_open(void) {
  char *path = db_path();
  sqlite3 *db = db_open(path);
  free(path);
  if (db_int(db, "PRAGMA user_version") == 0) die("no ctx database here; run: ctx init");
  return db;
}

static const char *person(void) {
  const char *u = getenv("USER");
  return u && *u ? u : "ctx";
}

static void open_private(sqlite3 *db) {
  sqlite3_stmt *q = db_prepare(db, "SELECT fsl_open('repo:me', ?1)");
  sqlite3_bind_text(q, 1, person(), -1, SQLITE_STATIC);
  if (sqlite3_step(q) != SQLITE_ROW) die("cannot open the private repository: %s", sqlite3_errmsg(db));
  sqlite3_finalize(q);
}

static int is_repo_root(const char *dir) {
  static const char *const markers[] = {".git", ".fslckout", ".zit-checkout", "_FOSSIL_", NULL};
  char p[4200];
  struct stat st;
  for (int i = 0; markers[i]; i++) {
    snprintf(p, sizeof p, "%s/%s", dir, markers[i]);
    if (stat(p, &st) == 0) return 1;
  }
  return 0;
}

/* The project for a working directory: the longest mapped root, else the name of
 * the repository containing it, else its last path segment. Caller frees. */
static char *project_for(sqlite3 *db, const char *cwd) {
  if (!cwd || !*cwd) return dup_text((const unsigned char *)"unknown");
  sqlite3_stmt *q = db_prepare(db,
      "SELECT project FROM ctx_project"
      " WHERE ?1 = root OR substr(?1, 1, length(root) + 1) = root || '/'"
      " ORDER BY length(root) DESC LIMIT 1");
  sqlite3_bind_text(q, 1, cwd, -1, SQLITE_STATIC);
  char *out = NULL;
  if (sqlite3_step(q) == SQLITE_ROW) out = dup_text(sqlite3_column_text(q, 0));
  sqlite3_finalize(q);
  if (out) return out;

  char dir[4200];
  snprintf(dir, sizeof dir, "%s", cwd);
  char *wt = strstr(dir, "/.claude/worktrees/"); /* an agent worktree belongs to its parent */
  if (wt) *wt = 0;
  const char *home = getenv("HOME");
  char walk[4200];
  snprintf(walk, sizeof walk, "%s", dir);
  for (;;) {
    if (is_repo_root(walk)) {
      snprintf(dir, sizeof dir, "%s", walk);
      break;
    }
    char *slash = strrchr(walk, '/');
    if (!slash || slash == walk || (home && !strcmp(walk, home))) break;
    *slash = 0;
  }
  const char *base = strrchr(dir, '/');
  return dup_text((const unsigned char *)(base && base[1] ? base + 1 : dir));
}

static void turn_day(const turn_t *t, char out[11], const char *fallback) {
  const char *s = strlen(t->ts) >= 10 && t->ts[4] == '-' && t->ts[7] == '-' ? t->ts : fallback;
  memcpy(out, s, 10);
  out[10] = 0;
}

/* Stores one batch of turns and advances the read position, in one transaction. */
static long archive_batch(sqlite3 *db, const char *session, const char *path, const char *project,
                          long long repo_id, turn_t *turns, size_t n, long long offset) {
  long stored = 0;
  char sid[9], today[32];
  session_id(path, sid);
  time_t now = time(NULL);
  strftime(today, sizeof today, "%Y-%m-%d", gmtime(&now));
  db_exec(db, "BEGIN IMMEDIATE");

  sqlite3_stmt *up = db_prepare(db,
      "INSERT INTO ctx_capture(session, path, project) VALUES (?1, ?2, ?3)"
      " ON CONFLICT(session) DO UPDATE SET path = excluded.path");
  sqlite3_bind_text(up, 1, session, -1, SQLITE_STATIC);
  sqlite3_bind_text(up, 2, path, -1, SQLITE_STATIC);
  sqlite3_bind_text(up, 3, project, -1, SQLITE_STATIC);
  if (sqlite3_step(up) != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
  sqlite3_finalize(up);

  sqlite3_stmt *seen = db_prepare(db, "SELECT 1 FROM ctx_chunk WHERE turn = ?1");
  char *done = calloc(n ? n : 1, 1);
  if (!done) die("out of memory");
  for (size_t i = 0; i < n; i++) {
    if (!*turns[i].uuid) continue;
    sqlite3_bind_text(seen, 1, turns[i].uuid, -1, SQLITE_STATIC);
    if (sqlite3_step(seen) == SQLITE_ROW) done[i] = 1;
    sqlite3_reset(seen);
  }
  sqlite3_finalize(seen);

  sqlite3_stmt *find = db_prepare(db, "SELECT technote FROM ctx_capture_day WHERE session=?1 AND day=?2");
  sqlite3_stmt *read = db_prepare(db, "SELECT fsl_technote(?1)");
  sqlite3_stmt *save_new = db_prepare(db,
      "SELECT fsl_technote_save(?1, json_object('comment', ?2, 'time', ?3 || ' 00:00:00',"
      " 'mimetype', 'text/x-markdown', 'tags', json_array('session', ?4)))");
  sqlite3_stmt *save_old = db_prepare(db, "SELECT fsl_technote_save(?1, json_object('id', ?2))");
  sqlite3_stmt *day_in = db_prepare(db, "INSERT OR IGNORE INTO ctx_capture_day(session, day, technote) VALUES (?1,?2,?3)");
  sqlite3_stmt *doc = db_prepare(db,
      "INSERT INTO ctx_doc(project, repo_id, kind, name, title, hash, size, mtime)"
      " VALUES (?1, ?2, 'session', ?3, ?4, ?3, ?5, unixepoch())"
      " ON CONFLICT(project, kind, name) DO UPDATE SET size = excluded.size, mtime = excluded.mtime"
      " RETURNING id, (SELECT coalesce(max(seq), -1) FROM ctx_chunk WHERE doc_id = ctx_doc.id)");
  sqlite3_stmt *chunk = db_prepare(db, "INSERT INTO ctx_chunk(doc_id, seq, heading, at, turn, body, project) VALUES (?1,?2,?3,?4,?5,?6,?7)");
  char *last_cwd = NULL, *last_proj = NULL; /* most turns repeat the previous directory */

  buf text = {0};
  for (size_t i = 0; i < n; i++) {
    if (done[i]) continue;
    char day[11], other[11];
    turn_day(&turns[i], day, today);

    text.n = 0;
    char *id = NULL;
    sqlite3_bind_text(find, 1, session, -1, SQLITE_STATIC);
    sqlite3_bind_text(find, 2, day, -1, SQLITE_STATIC);
    if (sqlite3_step(find) == SQLITE_ROW) id = dup_text(sqlite3_column_text(find, 0));
    sqlite3_reset(find);
    if (id) {
      sqlite3_bind_text(read, 1, id, -1, SQLITE_STATIC);
      if (sqlite3_step(read) == SQLITE_ROW && sqlite3_column_text(read, 0))
        buf_add(&text, (const char *)sqlite3_column_text(read, 0), (size_t)sqlite3_column_bytes(read, 0));
      sqlite3_reset(read);
    }

    size_t first = i;
    for (size_t j = i; j < n; j++) {
      if (done[j]) continue;
      turn_day(&turns[j], other, today);
      if (strcmp(day, other)) continue;
      buf_str(&text, "## ");
      buf_str(&text, turns[j].role);
      buf_str(&text, " ");
      buf_str(&text, turns[j].ts);
      buf_str(&text, "\n\n");
      buf_add(&text, turns[j].body, turns[j].body_n);
      buf_str(&text, "\n\n");
    }

    sqlite3_stmt *save = id ? save_old : save_new;
    char comment[96], tag[32];
    snprintf(comment, sizeof comment, "Session %s %s", sid, day);
    snprintf(tag, sizeof tag, "project-sessions");
    sqlite3_bind_text(save, 1, text.p, (int)text.n, SQLITE_STATIC);
    if (id) {
      sqlite3_bind_text(save, 2, id, -1, SQLITE_STATIC);
    } else {
      sqlite3_bind_text(save, 2, comment, -1, SQLITE_STATIC);
      sqlite3_bind_text(save, 3, day, -1, SQLITE_STATIC);
      sqlite3_bind_text(save, 4, project, -1, SQLITE_STATIC);
    }
    if (sqlite3_step(save) != SQLITE_ROW) die("cannot save the technote: %s", sqlite3_errmsg(db));
    if (!id) id = dup_text(sqlite3_column_text(save, 0));
    sqlite3_reset(save);

    sqlite3_bind_text(day_in, 1, session, -1, SQLITE_STATIC);
    sqlite3_bind_text(day_in, 2, day, -1, SQLITE_STATIC);
    sqlite3_bind_text(day_in, 3, id, -1, SQLITE_STATIC);
    if (sqlite3_step(day_in) != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
    sqlite3_reset(day_in);

    sqlite3_bind_text(doc, 1, project, -1, SQLITE_STATIC);
    sqlite3_bind_int64(doc, 2, repo_id);
    sqlite3_bind_text(doc, 3, id, -1, SQLITE_STATIC);
    sqlite3_bind_text(doc, 4, comment, -1, SQLITE_STATIC);
    sqlite3_bind_int64(doc, 5, (sqlite3_int64)text.n);
    if (sqlite3_step(doc) != SQLITE_ROW) die("%s", sqlite3_errmsg(db));
    sqlite3_int64 doc_id = sqlite3_column_int64(doc, 0);
    sqlite3_int64 seq = sqlite3_column_int64(doc, 1);
    while (sqlite3_step(doc) == SQLITE_ROW) {}
    sqlite3_reset(doc);

    for (size_t j = first; j < n; j++) {
      if (done[j]) continue;
      turn_day(&turns[j], other, today);
      if (strcmp(day, other)) continue;
      sqlite3_bind_int64(chunk, 1, doc_id);
      sqlite3_bind_int64(chunk, 2, ++seq);
      sqlite3_bind_text(chunk, 3, turns[j].role, -1, SQLITE_STATIC);
      sqlite3_bind_text(chunk, 4, turns[j].ts, -1, SQLITE_STATIC);
      if (*turns[j].uuid) sqlite3_bind_text(chunk, 5, turns[j].uuid, -1, SQLITE_STATIC);
      else sqlite3_bind_null(chunk, 5);
      sqlite3_bind_text(chunk, 6, turns[j].body, (int)turns[j].body_n, SQLITE_STATIC);
      if (*turns[j].cwd && (!last_cwd || strcmp(last_cwd, turns[j].cwd))) {
        free(last_cwd);
        free(last_proj);
        last_cwd = dup_text((const unsigned char *)turns[j].cwd);
        last_proj = project_for(db, turns[j].cwd);
      }
      sqlite3_bind_text(chunk, 7, last_proj ? last_proj : project, -1, SQLITE_STATIC);
      if (sqlite3_step(chunk) != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
      sqlite3_reset(chunk);
      done[j] = 1;
      stored++;
    }
    free(id);
  }
  free(text.p);
  free(done);
  free(last_cwd);
  free(last_proj);
  sqlite3_finalize(find);
  sqlite3_finalize(read);
  sqlite3_finalize(save_new);
  sqlite3_finalize(save_old);
  sqlite3_finalize(day_in);
  sqlite3_finalize(doc);
  sqlite3_finalize(chunk);

  char hash[17];
  head_hash(path, offset, hash);
  sqlite3_stmt *pos = db_prepare(db, "UPDATE ctx_capture SET offset=?2, head_hash=?3 WHERE session=?1");
  sqlite3_bind_text(pos, 1, session, -1, SQLITE_STATIC);
  sqlite3_bind_int64(pos, 2, offset);
  sqlite3_bind_text(pos, 3, hash, -1, SQLITE_STATIC);
  if (sqlite3_step(pos) != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
  sqlite3_finalize(pos);
  db_exec(db, "COMMIT");
  return stored;
}

/* Saves what is new in a transcript to the private repository and the index. */
static int cmd_archive(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) die("cannot read %s: %s", path, strerror(errno));
  sqlite3 *db = ctx_open();
  open_private(db);

  const char *base = strrchr(path, '/');
  base = base ? base + 1 : path;
  char session[128];
  snprintf(session, sizeof session, "%.*s", (int)strcspn(base, "."), base);

  sqlite3_int64 repo_id = 0;
  {
    sqlite3_stmt *q = db_prepare(db, "SELECT id FROM ctx_repo WHERE name='me'");
    if (sqlite3_step(q) == SQLITE_ROW) repo_id = sqlite3_column_int64(q, 0);
    sqlite3_finalize(q);
  }
  if (!repo_id) die("no private repository; run: ctx init");

  long long offset = 0;
  char *project = NULL;
  {
    sqlite3_stmt *q = db_prepare(db, "SELECT offset, head_hash, project FROM ctx_capture WHERE session=?1");
    sqlite3_bind_text(q, 1, session, -1, SQLITE_STATIC);
    if (sqlite3_step(q) == SQLITE_ROW) {
      char hash[17];
      offset = sqlite3_column_int64(q, 0);
      project = dup_text(sqlite3_column_text(q, 2));
      head_hash(path, offset, hash);
      const char *old = (const char *)sqlite3_column_text(q, 1);
      if ((long long)st.st_size < offset || !old || strcmp(old, hash)) offset = 0;
    }
    sqlite3_finalize(q);
  }

  FILE *f = fopen(path, "r");
  if (!f) die("cannot open %s: %s", path, strerror(errno));
  if (fseeko(f, (off_t)offset, SEEK_SET) != 0) die("cannot seek %s", path);

  extractor e;
  ex_open(&e);
  char *line = NULL;
  size_t cap = 0, nturns = 0, capturns = 0;
  ssize_t len = 0;
  turn_t *turns = NULL;
  long stored = 0;
  long long pos = offset, batch_start = offset;
  int more = 1;
  while (more) {
    len = getline(&line, &cap, f);
    int whole = len > 0 && line[len - 1] == '\n';
    if (whole) {
      pos += len;
      if (!project) {
        char *cwd = ex_cwd(&e, line, (size_t)len);
        if (cwd) {
          project = project_for(db, cwd);
          free(cwd);
        }
      }
      turn_t t = {0};
      if (ex_line(&e, line, (size_t)len, &t)) {
        if (nturns == capturns) {
          capturns = capturns ? capturns * 2 : 256;
          turns = realloc(turns, capturns * sizeof *turns);
          if (!turns) die("out of memory");
        }
        turns[nturns++] = t;
      }
    } else {
      more = 0; /* end of file, or a line still being written */
    }
    if (pos > batch_start && (!more || pos - batch_start >= BATCH_BYTES)) {
      if (!project) project = dup_text((const unsigned char *)"unknown");
      stored += archive_batch(db, session, path, project, repo_id, turns, nturns, pos);
      for (size_t i = 0; i < nturns; i++) turn_free(&turns[i]);
      nturns = 0;
      batch_start = pos;
    }
  }
  free(line);
  free(turns);
  free(project);
  ex_close(&e);
  fclose(f);
  sqlite3_close(db);
  printf("%ld turns archived\n", stored);
  return 0;
}

/* Words too common to help a search. */
static int is_stopword(const char *w) {
  static const char *const words[] = {
      "about", "after", "all", "also", "and", "any", "are", "because", "been", "before",
      "between", "both", "but", "can", "could", "did", "does", "each", "for", "from", "has",
      "have", "how", "into", "its", "like", "may", "more", "most", "must", "not", "one",
      "only", "other", "out", "over", "should", "some", "such", "than", "that", "the",
      "their", "them", "then", "there", "these", "they", "this", "those", "through", "under",
      "use", "was", "were", "what", "when", "where", "which", "while", "who", "why", "will",
      "with", "would", "you", "your", NULL};
  for (int i = 0; words[i]; i++)
    if (!strcmp(w, words[i])) return 1;
  return 0;
}

/* Builds an FTS5 OR query from free text. Returns 0 if no usable word is left. */
static int fts_query(int argc, char **argv, buf *q) {
  int terms = 0;
  char w[64];
  for (int a = 0; a < argc; a++) {
    const char *p = argv[a];
    size_t n = 0;
    for (;; p++) {
      unsigned char c = (unsigned char)*p;
      if (c_word(c)) {
        if (n < sizeof w - 1) w[n++] = (char)((c >= 'A' && c <= 'Z') ? c + 32 : c);
        continue;
      }
      w[n] = 0;
      if (n >= 3 && !is_stopword(w)) {
        if (terms++) buf_str(q, " OR ");
        buf_str(q, "\"");
        buf_str(q, w);
        buf_str(q, "\"");
      }
      n = 0;
      if (!c) break;
    }
  }
  return terms;
}

static char *current_project(sqlite3 *db) {
  char cwd[4096];
  return project_for(db, getcwd(cwd, sizeof cwd));
}

/* Runs the search; prints hits and returns how many there were. */
static int search_run(sqlite3 *db, const char *match, const char *project, int limit) {
  sqlite3_stmt *q = db_prepare(db,
      "SELECT c.id, coalesce(c.project, d.project), d.kind, coalesce(c.heading,''), substr(coalesce(c.at,''),1,10),"
      "       snippet(ctx_chunk_fts, 1, '[', ']', ' ... ', 40)"
      " FROM ctx_chunk_fts"
      " JOIN ctx_chunk c ON c.id = ctx_chunk_fts.rowid"
      " JOIN ctx_doc d ON d.id = c.doc_id"
      " WHERE ctx_chunk_fts MATCH ?1 AND (?2 IS NULL OR coalesce(c.project, d.project) = ?2)"
      " ORDER BY ctx_chunk_fts.rank LIMIT ?3");
  sqlite3_bind_text(q, 1, match, -1, SQLITE_STATIC);
  if (project) sqlite3_bind_text(q, 2, project, -1, SQLITE_STATIC);
  sqlite3_bind_int(q, 3, limit);
  int hits = 0, rc;
  while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
    hits++;
    printf("#%lld %s %s %s %s\n", sqlite3_column_int64(q, 0), sqlite3_column_text(q, 1),
           sqlite3_column_text(q, 2), sqlite3_column_text(q, 3), sqlite3_column_text(q, 4));
    const char *snip = (const char *)sqlite3_column_text(q, 5);
    fputs("    ", stdout);
    int space = 0; /* collapse runs of whitespace so each hit stays on one line */
    for (; snip && *snip; snip++) {
      if (c_space((unsigned char)*snip)) {
        space = 1;
        continue;
      }
      if (space) putchar(' ');
      space = 0;
      putchar(*snip);
    }
    putchar('\n');
  }
  if (rc != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
  sqlite3_finalize(q);
  return hits;
}

/* ctx search [--all] [--limit N] WORDS... */
static int cmd_search(int argc, char **argv) {
  int all = 0, limit = 12, nwords = 0;
  char **words = calloc((size_t)argc + 1, sizeof *words);
  if (!words) die("out of memory");
  for (int i = 0; i < argc; i++) {
    if (!strcmp(argv[i], "--all")) all = 1;
    else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atoi(argv[++i]);
    else if (!strncmp(argv[i], "--", 2)) die("unknown option %s", argv[i]);
    else words[nwords++] = argv[i];
  }
  if (limit < 1) die("--limit must be at least 1");
  buf q = {0};
  if (!fts_query(nwords, words, &q)) die("no search words");
  free(words);
  sqlite3 *db = ctx_open();
  char *project = all ? NULL : current_project(db);
  int hits = search_run(db, q.p, project, limit);
  if (!hits && project) {
    fprintf(stderr, "ctx: nothing in project %s; searching everything\n", project);
    hits = search_run(db, q.p, NULL, limit);
  }
  if (!hits) fprintf(stderr, "ctx: no matches\n");
  free(project);
  free(q.p);
  sqlite3_close(db);
  return 0;
}

/* How much of one turn is printed unless --full is given. */
#define TURN_SHOW 8000

/* ctx turn ID [BEFORE [AFTER]] [--full] */
static int cmd_turn(int argc, char **argv) {
  int full = 0, nums[3] = {0, 0, 0}, have = 0;
  for (int i = 0; i < argc; i++) {
    if (!strcmp(argv[i], "--full")) full = 1;
    else if (have < 3) nums[have++] = atoi(argv[i]);
    else return 2;
  }
  if (have < 1 || nums[0] <= 0) die("usage: ctx turn ID [BEFORE [AFTER]] [--full]");
  sqlite3 *db = ctx_open();
  sqlite3_stmt *q = db_prepare(db,
      "SELECT n.id, n.heading, coalesce(n.at,''), n.body"
      " FROM ctx_chunk c JOIN ctx_chunk n ON n.doc_id = c.doc_id"
      " WHERE c.id = ?1 AND n.seq BETWEEN c.seq - ?2 AND c.seq + ?3 ORDER BY n.seq");
  sqlite3_bind_int(q, 1, nums[0]);
  sqlite3_bind_int(q, 2, nums[1]);
  sqlite3_bind_int(q, 3, nums[2]);
  int found = 0, rc;
  while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
    found = 1;
    const char *body = (const char *)sqlite3_column_text(q, 3);
    size_t n = (size_t)sqlite3_column_bytes(q, 3), show = n;
    if (!full && n > TURN_SHOW) {
      show = TURN_SHOW;
      while (show > 0 && is_utf8_cont(body[show])) show--;
    }
    printf("--- #%lld %s %s\n", sqlite3_column_int64(q, 0), sqlite3_column_text(q, 1),
           sqlite3_column_text(q, 2));
    fwrite(body, 1, show, stdout);
    if (show < n) printf("\n[... %zu more bytes; use --full]", n - show);
    fputs("\n\n", stdout);
  }
  if (rc != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
  sqlite3_finalize(q);
  sqlite3_close(db);
  if (!found) die("no turn #%d", nums[0]);
  return 0;
}

/* Runs one SQL statement with libfossil ready, printing rows tab-separated. */
static int cmd_sql(const char *sql) {
  sqlite3 *db = ctx_open();
  open_private(db);
  sqlite3_stmt *q = db_prepare(db, sql);
  int rc;
  while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
    for (int i = 0; i < sqlite3_column_count(q); i++) {
      const unsigned char *v = sqlite3_column_text(q, i);
      printf("%s%s", i ? "\t" : "", v ? (const char *)v : "");
    }
    putchar('\n');
  }
  if (rc != SQLITE_DONE) die("%s", sqlite3_errmsg(db));
  sqlite3_finalize(q);
  sqlite3_close(db);
  return 0;
}

static int usage(void) {
  fputs("usage: ctx version\n"
        "       ctx init\n"
        "       ctx extract TRANSCRIPT\n"
        "       ctx archive TRANSCRIPT\n"
        "       ctx search [--all] [--limit N] WORDS...\n"
        "       ctx turn ID [BEFORE [AFTER]] [--full]\n"
        "       ctx sql STATEMENT\n",
        stderr);
  return 2;
}

int main(int argc, char **argv) {
  if (sqlite3_auto_extension((void (*)(void))fsl_sqlext_init) != SQLITE_OK)
    die("cannot register libfossil");
  if (argc == 2 && !strcmp(argv[1], "version")) return cmd_version();
  if (argc == 2 && !strcmp(argv[1], "init")) return cmd_init();
  if (argc == 3 && !strcmp(argv[1], "extract")) return cmd_extract(argv[2]);
  if (argc == 3 && !strcmp(argv[1], "archive")) return cmd_archive(argv[2]);
  if (argc == 3 && !strcmp(argv[1], "sql")) return cmd_sql(argv[2]);
  if (argc >= 3 && !strcmp(argv[1], "search")) return cmd_search(argc - 2, argv + 2);
  if (argc >= 3 && !strcmp(argv[1], "turn")) return cmd_turn(argc - 2, argv + 2);
  return usage();
}
