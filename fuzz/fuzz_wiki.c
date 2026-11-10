/* Wiki pages: citation and link parsing, the claim checks, sentence extraction and
 * link encoding, on any text. */
#define CTX_NO_MAIN
#include "../src/ctx.c"

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n) {
  static sqlite3 *db;
  if (!db) {
    sqlite3_auto_extension((void (*)(void))fsl_sqlext_init); /* as main does */
    db = db_open(":memory:");
    db_exec(db, ctx_state_schema);
    db_exec(db, ctx_schema);
    index_prepare(db);
  }
  char *t = malloc(n + 1);
  if (!t) return 0;
  memcpy(t, data, n);
  t[n] = 0;
  wiki_parse(db, t);
  body_check(db, t);
  char claim[4096];
  claim_of(t, "a", claim, sizeof claim);
  char *u = url_param(t, "name");
  free(u);
  free(squeeze(t, strlen(t)));
  size_t g = generated_at(t);
  if (g > strlen(t)) __builtin_trap();
  encode_page_links(t);
  char *r = footnote_repin(t, "a", "sources/x.md", "0123456789abcdef");
  free(r);
  free(t);
  return 0;
}
