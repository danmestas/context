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
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

build:
	mkdir -p build

# The schema is compiled into the binary, one C string literal per line.
build/schema.h: schema/index.sql | build
	awk 'BEGIN { print "static const char ctx_schema[] =" } \
	     { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print "\"" $$0 "\\n\"" } \
	     END { print ";" }' $< > $@

build/state_schema.h: schema/state.sql | build
	awk 'BEGIN { print "static const char ctx_state_schema[] =" } \
	     { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print "\"" $$0 "\\n\"" } \
	     END { print ";" }' $< > $@

build/ticket_schema.h: schema/ticket-table.sql | build
	awk 'BEGIN { print "static const char ctx_ticket_schema[] =" } \
	     { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print "\"" $$0 "\\n\"" } \
	     END { print ";" }' $< > $@

build/ctx.o: src/ctx.c build/schema.h build/state_schema.h build/ticket_schema.h | build
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
build/san/ctx.o: src/ctx.c build/schema.h build/state_schema.h build/ticket_schema.h
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
FUZZERS = redact extract wiki notes stats
# Objects for the fuzzers are built by the fuzzing compiler; its sanitizer runtime differs.
build/fuzz/libfossil.o: $(VENDOR)/libfossil.c
	@test -n "$(FUZZCC)" || { echo "no clang with libFuzzer; set FUZZCC" >&2; exit 1; }
	mkdir -p build/fuzz
	$(FUZZCC) $(SANFLAGS) -fno-sanitize=alignment $(SQLITE) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<
build/fuzz/sqlite3.o: $(VENDOR)/sqlite3.c
	@test -n "$(FUZZCC)" || { echo "no clang with libFuzzer; set FUZZCC" >&2; exit 1; }
	mkdir -p build/fuzz
	$(FUZZCC) $(SANFLAGS) $(SQLITE) -w -c -o $@ $<
build/fuzz/%: fuzz/fuzz_%.c src/ctx.c build/fuzz/libfossil.o build/fuzz/sqlite3.o build/schema.h build/state_schema.h build/ticket_schema.h
	$(FUZZCC) $(SANFLAGS) -fsanitize=fuzzer -w -I$(VENDOR) -Ibuild -o $@ $< build/fuzz/libfossil.o build/fuzz/sqlite3.o $(LDLIBS)
# CI fuzzes briefly where a fuzzing clang exists, and says so where it does not.
fuzz-ci:
	@if [ -n "$(FUZZCC)" ]; then $(MAKE) fuzz FUZZ_SECONDS=20; else echo "fuzz-ci: no clang with libFuzzer on this runner; fuzzing skipped"; fi
fuzz: $(FUZZERS:%=build/fuzz/%)
	for f in $(FUZZERS); do mkdir -p build/fuzz/corpus-$$f; \
	  ASAN_OPTIONS=detect_leaks=0 build/fuzz/$$f -max_total_time=$(FUZZ_SECONDS) -max_len=65536 -print_final_stats=1 build/fuzz/corpus-$$f fuzz/seed/$$f > build/fuzz/$$f.log 2>&1; \
	  s=$$?; tail -4 build/fuzz/$$f.log; [ $$s = 0 ] || { echo "fuzz: $$f failed; see build/fuzz/$$f.log" >&2; exit 1; }; done

# Fil-C (fil-c.org, Linux only) makes every out-of-bounds access, use after free and
# bad cast a crash. The suite and every saved fuzz input run under it. Fil-C ships no
# zlib: build one with it and point FILC_LDFLAGS (and FILC_CFLAGS for zlib.h) at it.
FILCC ?= $(shell command -v filcc 2>/dev/null)
FILC_CFLAGS ?=
FILC_LDFLAGS ?=
FILC = $(FILCC) -O2 $(FILC_CFLAGS)
build/filc/libfossil.o: $(VENDOR)/libfossil.c
	@test -n "$(FILCC)" || { echo "no Fil-C compiler; set FILCC" >&2; exit 1; }
	mkdir -p build/filc
	$(FILC) $(SQLITE) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<
build/filc/sqlite3.o: $(VENDOR)/sqlite3.c
	@test -n "$(FILCC)" || { echo "no Fil-C compiler; set FILCC" >&2; exit 1; }
	mkdir -p build/filc
	$(FILC) $(SQLITE) -w -c -o $@ $<
build/filc/ctx.o: src/ctx.c build/schema.h build/state_schema.h build/ticket_schema.h
	mkdir -p build/filc
	$(FILC) -Wall -Wextra -I$(VENDOR) -Ibuild -c -o $@ $<
ctx-filc: build/filc/ctx.o build/filc/libfossil.o build/filc/sqlite3.o
	$(FILC) $(FILC_LDFLAGS) -o $@ $^ $(LDLIBS)
build/filc/replay-%: fuzz/fuzz_%.c fuzz/replay.c src/ctx.c build/filc/libfossil.o build/filc/sqlite3.o build/schema.h build/state_schema.h build/ticket_schema.h
	$(FILC) -w -I$(VENDOR) -Ibuild $(FILC_LDFLAGS) -o $@ $< fuzz/replay.c build/filc/libfossil.o build/filc/sqlite3.o $(LDLIBS)
filc: ctx-filc $(FUZZERS:%=build/filc/replay-%)
	CTX=$(PWD)/ctx-filc sh test/run.sh
	for f in $(FUZZERS); do printf '%s: ' $$f; build/filc/replay-$$f fuzz/seed/$$f build/fuzz/corpus-$$f || exit 1; done
filc-ci:
	@if [ -n "$(FILCC)" ]; then $(MAKE) filc; else echo "filc-ci: no Fil-C compiler on this runner; Fil-C run skipped"; fi

# A release archive is a Claude Code plugin: bin/ctx, the skills and the hooks.
# On Linux zlib is linked statically, so the binary needs only the C library.
VERSION := $(shell sed -n 's/^\#define CTX_VERSION "\(.*\)"/\1/p' src/ctx.c)
OS      := $(shell uname -s | tr A-Z a-z)
ARCH    := $(shell uname -m | sed 's/aarch64/arm64/')
DIST     = ctx-$(VERSION)-$(OS)-$(ARCH)
ifeq ($(OS),linux)
DIST_LDLIBS = -l:libz.a -lpthread -lm -ldl
else
DIST_LDLIBS = $(LDLIBS)
endif
dist: build/ctx.o build/libfossil.o build/sqlite3.o
	rm -rf build/dist/$(DIST) && mkdir -p build/dist/$(DIST)/bin build/dist/$(DIST)/skills
	$(CC) $(CFLAGS) $(LDFLAGS) -o build/dist/$(DIST)/bin/ctx $^ $(DIST_LDLIBS)
	strip build/dist/$(DIST)/bin/ctx
	cp -R plugin/.claude-plugin plugin/hooks build/dist/$(DIST)/
	sed -i.bak 's/@VERSION@/$(VERSION)/' build/dist/$(DIST)/.claude-plugin/plugin.json && rm build/dist/$(DIST)/.claude-plugin/plugin.json.bak
	cp -R skill/ctx skill/ctx-wiki build/dist/$(DIST)/skills/
	cp plugin/INSTALL.md build/dist/$(DIST)/README.md
	cp LICENSE build/dist/$(DIST)/LICENSE
	cp $(VENDOR)/LICENSE build/dist/$(DIST)/LICENSE.libfossil
	build/dist/$(DIST)/bin/ctx version
	cd build/dist && tar czf $(DIST).tar.gz $(DIST) && \
	  { command -v sha256sum >/dev/null && sha256sum $(DIST).tar.gz || shasum -a 256 $(DIST).tar.gz; } > $(DIST).tar.gz.sha256
	@cat build/dist/$(DIST).tar.gz.sha256

# Everything CI runs, from a fresh clone: make check.
SQLITE3 ?= $(firstword $(wildcard /opt/homebrew/opt/sqlite/bin/sqlite3 /usr/local/opt/sqlite/bin/sqlite3) sqlite3)
check:
	python3 tools/bench_page.py --check
	python3 tools/test_bench_page.py
	$(MAKE) test sanitize fuzz-ci
	sh tools/filc.sh
	python3 bench/check_corpus.py
	bash -n bench/run.sh
	python3 -c "import sqlite3; sqlite3.connect(':memory:').executescript(open('bench/schema.sql').read())"
	$(SQLITE3) :memory: -bail -cmd '.read schema/state.sql' -cmd '.read schema/index.sql' '.read schema/check.sql'
	@echo "check: everything passed"

# docs/benchmarks.md is generated from bench/results/*.json.
bench-page:
	python3 tools/bench_page.py

clean:
	rm -rf build ctx ctx-san ctx-filc

.PHONY: check bench-page test clean sanitize fuzz fuzz-ci filc filc-ci dist
