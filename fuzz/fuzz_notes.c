/* Technotes from another machine: every byte of text ends up in exactly one turn
 * or in a heading, never read past the end. */
#define CTX_NO_MAIN
#include "../src/ctx.c"

static void count(void *ctx, const char *role, const char *at, const char *body, size_t n) {
  size_t *total = ctx;
  if (!role || !at || (n && !body)) __builtin_trap();
  *total += n;
}

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n) {
  char *t = malloc(n + 1);
  if (!t) return 0;
  memcpy(t, data, n);
  t[n] = 0;
  size_t total = 0;
  note_turns(t, count, &total);
  if (total > strlen(t)) __builtin_trap();
  free(t);
  return 0;
}
