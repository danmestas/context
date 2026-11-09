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
	$(CC) $(CFLAGS) -DHAVE_LIBFOSSIL_CONFIG_H -w -I$(VENDOR) -c -o $@ $<

test: ctx
	sh test/run.sh

clean:
	rm -rf build ctx

.PHONY: test clean
