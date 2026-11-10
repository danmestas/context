#!/bin/sh
# Builds ctx with Fil-C and runs the suite and every saved fuzz input under it.
# Fil-C runs on Linux x86_64 and aarch64 only; elsewhere this says so and exits 0.
# Downloads are pinned by SHA-256 and kept in FILC_HOME (default ~/.cache/ctx-filc).
set -eu

VER=0.687
ZLIB=1.3.1
ZLIB_SHA=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ARCH=x86_64 SHA=aab538401f78a47ab261ee79afed8c6b99e1d4848e263ae159a75b03c1288da1 ;;
  Linux-aarch64) ARCH=aarch64 SHA=f1337799051664f93c7712141deaebe78571ae96ffcf05563d517b89440bcbc0 ;;
  *) echo "filc: Fil-C does not run on $(uname -s) $(uname -m); skipped"; exit 0 ;;
esac

H=${FILC_HOME:-$HOME/.cache/ctx-filc}
F=$H/filc-$VER-linux-$ARCH
Z=$H/zlib-$ZLIB-filc
mkdir -p "$H"

fetch() { # url sha file
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet 2>/dev/null && return 0
  curl -fsSL "$1" -o "$3.part"
  echo "$2  $3.part" | sha256sum -c --quiet || { rm -f "$3.part"; echo "filc: checksum mismatch for $1" >&2; exit 1; }
  mv "$3.part" "$3"
}

if [ ! -x "$F/build/bin/clang" ]; then
  fetch "https://github.com/pizlonator/fil-c/releases/download/v$VER/filc-$VER-linux-$ARCH.tar.xz" "$SHA" "$H/filc.tar.xz"
  rm -rf "$F" && tar xJf "$H/filc.tar.xz" -C "$H"
  (cd "$F" && ./setup.sh >/dev/null)
fi

if [ ! -f "$Z/lib/libz.a" ]; then
  fetch "https://zlib.net/fossils/zlib-$ZLIB.tar.gz" "$ZLIB_SHA" "$H/zlib.tar.gz"
  rm -rf "$H/zlib-$ZLIB" && tar xzf "$H/zlib.tar.gz" -C "$H"
  (cd "$H/zlib-$ZLIB" && CC="$F/build/bin/clang" CFLAGS=-O2 ./configure --static --prefix="$Z" >/dev/null &&
    make -j"$(nproc)" >/dev/null && make install >/dev/null)
fi

exec make -j"$(nproc)" filc FILCC="$F/build/bin/clang" FILC_CFLAGS="-I$Z/include" FILC_LDFLAGS="-L$Z/lib"
