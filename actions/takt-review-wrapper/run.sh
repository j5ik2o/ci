set -euo pipefail

wrapper_script="${1:-.github/scripts/takt-review-wrapper.mjs}"

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

node "$wrapper_script"
