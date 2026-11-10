/* Redaction: no input crashes it, redacting twice changes nothing, and no secret a
 * rule recognizes survives. */
#define CTX_NO_MAIN
#include "../src/ctx.c"

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n) {
  buf once = {0}, twice = {0};
  add_redacted(&once, (const char *)data, n);
  add_redacted(&twice, once.p ? once.p : "", once.n);
  if (once.n != twice.n || (once.n && memcmp(once.p, twice.p, once.n))) __builtin_trap();
  for (size_t i = 0; i < once.n; i++) {
    size_t from;
    const char *name = NULL;
    size_t e = secret_at(once.p, once.n, i, &from, &name, 0);
    if (e && !(e - from == strlen(REDACTED) && !memcmp(once.p + from, REDACTED, e - from))) __builtin_trap();
  }
  for (size_t i = 0; i < n;) { /* the audit's candidate scan must stay in bounds */
    size_t from;
    const char *name;
    size_t e = candidate_at((const char *)data, n, i, &from, &name);
    if (e && (e > n || from > e)) __builtin_trap();
    i = e ? e : i + 1;
  }
  free(once.p);
  free(twice.p);
  return 0;
}
