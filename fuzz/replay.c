/* Runs a fuzz target over saved inputs without libFuzzer, so compilers that lack it,
 * such as Fil-C, can check every seed and corpus file. Arguments are files or
 * directories; directories are read one level deep. */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t n);

static long runs;

static void one(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  size_t cap = 1 << 16, n = 0, got;
  unsigned char *buf = malloc(cap);
  while ((got = fread(buf + n, 1, cap - n, f)) > 0) {
    n += got;
    if (n == cap) buf = realloc(buf, cap *= 2);
  }
  fclose(f);
  LLVMFuzzerTestOneInput(buf, n);
  free(buf);
  runs++;
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    struct stat st;
    if (stat(argv[i], &st) != 0) continue; /* an empty corpus glob */
    if (!S_ISDIR(st.st_mode)) { one(argv[i]); continue; }
    DIR *d = opendir(argv[i]);
    struct dirent *e;
    while (d && (e = readdir(d))) {
      if (e->d_name[0] == '.') continue;
      char p[4096];
      snprintf(p, sizeof p, "%s/%s", argv[i], e->d_name);
      if (stat(p, &st) == 0 && S_ISREG(st.st_mode)) one(p);
    }
    if (d) closedir(d);
  }
  printf("%ld inputs\n", runs);
  return 0;
}
