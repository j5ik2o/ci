#!/usr/bin/env bash
# Runs tests/review-thread-resolution-smoke.sh in docker with a given jq
# version, to check the judge on the jq versions the runners may have
# (takt-dash docs/design/issue-134.md, "jq の版と、位置に頼らない判定").
#
#   bash tests/review-thread-resolution-smoke-jq.sh 1.6    # ubuntu:22.04 apt
#   bash tests/review-thread-resolution-smoke-jq.sh 1.7    # ubuntu:24.04 apt (the runner's)
#   bash tests/review-thread-resolution-smoke-jq.sh 1.8.1  # ubuntu:24.04 + the release binary
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

docker run --rm -v "$root:/repo:ro" "$image" bash -c "
  set -euo pipefail
  apt-get update -qq >/dev/null
  { $install; } >/dev/null 2>&1
  jq --version
  bash /repo/tests/review-thread-resolution-smoke.sh
"
