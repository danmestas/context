/* Transcript lines: any bytes, any JSON shape. */
#define CTX_NO_MAIN
#include "../src/ctx.c"

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n) {
  static extractor e;
  static int ready;
  if (!ready) {
    ex_open(&e);
    ready = 1;
  }
  turn_t t = {0};
  if (ex_line(&e, (const char *)data, n, &t) && t.body && t.body_n != strlen(t.body)) __builtin_trap(); /* no NUL kept */
  turn_free(&t);
  return 0;
}
