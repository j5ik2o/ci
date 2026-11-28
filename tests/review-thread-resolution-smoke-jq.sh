#!/usr/bin/env bash
# Runs tests/review-thread-resolution-smoke.sh in docker with a given jq
# version, to check the judge on the jq versions the runners may have
# (takt-dash docs/design/issue-134.md, "jq の版と、位置に頼らない判定").
#
#   bash tests/review-thread-resolution-smoke-jq.sh 1.6    # ubuntu:22.04 apt (must be refused)
#   bash tests/review-thread-resolution-smoke-jq.sh 1.7    # ubuntu:24.04 apt
#   bash tests/review-thread-resolution-smoke-jq.sh 1.8.1  # ubuntu:24.04 + the release binary
#
# The judge refuses jq older than 1.7, so on 1.6 the smoke stops at its first
# case. There the check is that it stops with the version check's error and the
# error status, not with a jq compile error or a judgement.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?usage: $0 1.6|1.7|1.8.1}"

case "$version" in
  1.6) image=ubuntu:22.04 install='apt-get install -y -qq jq' ;;
  1.7) image=ubuntu:24.04 install='apt-get install -y -qq jq' ;;
  1.8.1)
    image=ubuntu:24.04
    install='apt-get install -y -qq curl ca-certificates \
      && arch="$(uname -m | sed "s/x86_64/amd64/; s/aarch64/arm64/")" \
      && base=https://github.com/jqlang/jq/releases/download/jq-1.8.1 \
      && curl -fsSL -o /usr/local/bin/jq "$base/jq-linux-$arch" \
      && curl -fsSL "$base/sha256sum.txt" | grep " jq-linux-$arch\$" | sed "s| jq-linux-$arch\$| /usr/local/bin/jq|" | sha256sum -c - \
      && chmod +x /usr/local/bin/jq'
    ;;
  *) echo "unknown jq version: $version" >&2; exit 2 ;;
esac

docker run --rm -v "$root:/repo:ro" -e JQ_EXPECT_REFUSED="$([[ "$version" == "1.6" ]] && echo 1 || echo 0)" "$image" bash -c "
  set -euo pipefail
  apt-get update -qq >/dev/null
  { $install; } >/dev/null 2>&1
  jq --version
  if [[ \"\$JQ_EXPECT_REFUSED\" != 1 ]]; then
    exec bash /repo/tests/review-thread-resolution-smoke.sh
  fi
  status=0
  bash /repo/tests/review-thread-resolution-smoke.sh > /tmp/smoke.log 2>&1 || status=\$?
  cat /tmp/smoke.log
  if [[ \"\$status\" -ne 0 ]] \
    && grep -q '^::error::jq 1.6 ' /tmp/smoke.log \
    && grep -q 'Published commit status .error.' /tmp/smoke.log \
    && ! grep -q '^jq: error' /tmp/smoke.log; then
    echo 'jq 1.6 is refused by the version check, as designed.'
  else
    echo 'jq 1.6 must be refused by the version check (::error::jq 1.6 ... and an error status).' >&2
    exit 1
  fi
"
