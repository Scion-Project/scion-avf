#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the guest images (probe + bench) in a pinned Debian container, for
# hosts without clang/lld. Usage: tools/docker-build.sh
#
# The container is debian:trixie-slim (digest-pinned) plus clang, lld, curl, python3 and
# binutils from Debian's own repositories; the repo is mounted read-write so
# probe/guest/out and bench/out end up on the host.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad}"
docker run --rm -v "$repo:/src" -w /src "$IMAGE" bash -euc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends clang lld curl ca-certificates python3 binutils xz-utils >/dev/null
  git_safe=1
  probe/guest/build.sh
  if [ -x bench/build.sh ]; then bench/build.sh; fi
  chown -R '"$(id -u):$(id -g)"' probe/guest/out bench/out
'
