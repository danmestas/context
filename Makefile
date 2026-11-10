CC     ?= cc
CFLAGS ?= -O2

VENDOR  = vendor/libfossil
SQLITE  = -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_THREADSAFE=1
LDLIBS  = -lz -lpthread -lm
ifeq ($(shell uname -s),Darwin)
LDLIBS += -liconv
else
LDLIBS += -ldl
endif

ctx: build/ctx.o build/libfossil.o build/sqlite3.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

build:
	mkdir -p build

# The schema is compiled into the binary, one C string literal per line.
build/schema.h: schema/index.sql | build
	awk 'BEGIN { print "static const char ctx_schema[] =" } \
	     { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print "\"" $$0 "\\n\"" } \
	     END { print ";" }' $< > $@

build/ticket_schema.h: schema/ticket-table.sql | build
	awk 'BEGIN { print "static const char ctx_ticket_schema[] =" } \
	     { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print "\"" $$0 "\\n\"" } \
	     END { print ";" }' $< > $@

build/ctx.o: src/ctx.c build/schema.h build/ticket_schema.h | build
	$(CC) $(CFLAGS) -Wall -Wextra -I$(VENDOR) -Ibuild -c -o $@ $<

build/sqlite3.o: $(VENDOR)/sqlite3.c | build
	$(CC) $(CFLAGS) $(SQLITE) -w -c -o $@ $<

build/libfossil.o: $(VENDOR)/libfossil.c | build
	$(CC) $(CFLAGS) $(SQLITE) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<

test: ctx
	sh test/run.sh

# The whole suite under AddressSanitizer and UndefinedBehaviorSanitizer.
SANFLAGS = -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined
build/san/%.o: | build
	mkdir -p build/san
build/san/ctx.o: src/ctx.c build/schema.h build/ticket_schema.h
	mkdir -p build/san
	$(CC) $(SANFLAGS) -Wall -Wextra -I$(VENDOR) -Ibuild -c -o $@ $<
build/san/sqlite3.o: $(VENDOR)/sqlite3.c
	mkdir -p build/san
	$(CC) $(SANFLAGS) $(SQLITE) -w -c -o $@ $<
# libfossil's SHA-1 reads uint32 words from unaligned buffers during sync. Reported
# to libfossil on 2026-11-10; until a build fixes it, only that check is off, only here.
build/san/libfossil.o: $(VENDOR)/libfossil.c
	mkdir -p build/san
	$(CC) $(SANFLAGS) -fno-sanitize=alignment $(SQLITE) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<
ctx-san: build/san/ctx.o build/san/libfossil.o build/san/sqlite3.o
	$(CC) $(SANFLAGS) -o $@ $^ $(LDLIBS)
sanitize: ctx-san
	ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=print_stacktrace=1 CTX=$(PWD)/ctx-san sh test/run.sh

# Fuzzing needs a clang with libFuzzer. FUZZ_SECONDS each, seeded from fuzz/seed.
FUZZCC ?= $(shell for c in /opt/homebrew/opt/llvm/bin/clang clang; do echo 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){return 0;}' | $$c -fsanitize=fuzzer -x c - -o /dev/null 2>/dev/null && { echo $$c; break; }; done)
FUZZ_SECONDS ?= 60
FUZZERS = redact extract wiki notes
# Objects for the fuzzers are built by the fuzzing compiler; its sanitizer runtime differs.
build/fuzz/libfossil.o: $(VENDOR)/libfossil.c
	@test -n "$(FUZZCC)" || { echo "no clang with libFuzzer; set FUZZCC" >&2; exit 1; }
	mkdir -p build/fuzz
	$(FUZZCC) $(SANFLAGS) -fno-sanitize=alignment $(SQLITE) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<
# libfossil defines fsl_sqlext_init with a void pointer where SQLite passes its API
# struct, so SQLite's call through the extension pointer trips -fsanitize=function.
# Reported to libfossil on 2026-11-10; only that check is off, only for this object.
build/fuzz/sqlite3.o: $(VENDOR)/sqlite3.c
	@test -n "$(FUZZCC)" || { echo "no clang with libFuzzer; set FUZZCC" >&2; exit 1; }
	mkdir -p build/fuzz
	$(FUZZCC) $(SANFLAGS) -fno-sanitize=function $(SQLITE) -w -c -o $@ $<
build/fuzz/%: fuzz/fuzz_%.c src/ctx.c build/fuzz/libfossil.o build/fuzz/sqlite3.o build/schema.h build/ticket_schema.h
	$(FUZZCC) $(SANFLAGS) -fsanitize=fuzzer -w -I$(VENDOR) -Ibuild -o $@ $< build/fuzz/libfossil.o build/fuzz/sqlite3.o $(LDLIBS)
# CI fuzzes briefly where a fuzzing clang exists, and says so where it does not.
fuzz-ci:
	@if [ -n "$(FUZZCC)" ]; then $(MAKE) fuzz FUZZ_SECONDS=20; else echo "fuzz-ci: no clang with libFuzzer on this runner; fuzzing skipped"; fi
fuzz: $(FUZZERS:%=build/fuzz/%)
	for f in $(FUZZERS); do mkdir -p build/fuzz/corpus-$$f; \
	  ASAN_OPTIONS=detect_leaks=0 build/fuzz/$$f -max_total_time=$(FUZZ_SECONDS) -max_len=65536 -print_final_stats=1 build/fuzz/corpus-$$f fuzz/seed/$$f 2>&1 | tail -4 || exit 1; done

clean:
	rm -rf build ctx ctx-san

.PHONY: test clean sanitize fuzz fuzz-ci
