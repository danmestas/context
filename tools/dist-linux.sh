#!/bin/sh
# Builds the Linux release archive for this machine's architecture inside Ubuntu 22.04,
# so the binary needs only glibc 2.34 or later. Needs docker. The archive and its
# checksum land in build/dist/.
set -eu
IMAGE=${CTX_DIST_IMAGE:-ubuntu:22.04}
mkdir -p build/dist
docker run --rm -v "$PWD:/src:ro" -v "$PWD/build/dist:/out" "$IMAGE" sh -euc '
  export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq gcc make zlib1g-dev >/dev/null
  cp -R /src /tmp/ctx && cd /tmp/ctx && rm -rf build ctx ctx-san ctx-filc
  make dist >/dev/null
  v=$(objdump -T build/dist/ctx-*/bin/ctx | grep -oE "GLIBC_[0-9.]+" | sort -Vu | tail -1)
  echo "needs $v"
  cp build/dist/*.tar.gz build/dist/*.sha256 /out/
  chown "$(stat -c %u:%g /out)" /out/*
'
cat build/dist/ctx-*-linux-*.sha256
