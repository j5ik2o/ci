set -euo pipefail

wrapper_script="${1:-.github/scripts/takt-review-wrapper.mjs}"

case "${TAKT_NON_BLOCKING:-true}" in
  false|False|FALSE) non_blocking=0 ;;
  *) non_blocking=1 ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "::error::node is required to run the TAKT wrapper."
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "::error::ANTHROPIC_API_KEY is required."
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "::error::GITHUB_TOKEN is required."
  exit 1
fi

if [[ ! -f "$wrapper_script" ]]; then
  echo "::error::TAKT wrapper script not found: $wrapper_script"
  exit 1
fi

set +e
node "$wrapper_script"
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  if [[ "$non_blocking" -eq 1 ]]; then
    echo "::warning::TAKT review failed with exit code $status. Treating provider/runtime failure as non-blocking."
    exit 0
  fi
  exit "$status"
fi
