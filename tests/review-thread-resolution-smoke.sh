set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$GH_CALL_LOG"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  echo "GraphQL: Resource not accessible by integration (...checkSuite.workflowRun)" >&2
  exit 1
fi

if [[ "${1:-}" != "api" ]]; then
  echo "unexpected gh command: $*" >&2
  exit 1
fi

args="$*"

if [[ "$args" == *"graphql"* ]]; then
  if [[ "$args" == *"reviewThreads"* ]]; then
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  elif [[ "$args" == *"comments(first: 100"* ]]; then
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  elif [[ "$args" == *"reviews(first: 100"* ]]; then
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  else
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"__typename":"User","login":"alice"},"baseRefName":"main","headRepository":{"nameWithOwner":"j5ik2o/g2g"},"headRefOid":"head-sha","url":"https://github.com/j5ik2o/g2g/pull/27"}}}}'
  fi
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/pulls/27"* ]]; then
  printf '%s\n' 'head-sha'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha/check-runs"* ]]; then
  if [[ "${GH_FAIL_CHECK_RUNS:-0}" == "1" ]]; then
    echo "check-runs endpoint should not be called" >&2
    exit 1
  fi
  printf '%s\n' '[{"check_runs":[{"name":"refresh / Refresh review-thread state","status":"in_progress","details_url":"https://github.com/j5ik2o/g2g/actions/runs/125/job/456"},{"name":"ci-gate / CI Review Thread Gate","status":"in_progress","details_url":"https://github.com/j5ik2o/g2g/actions/runs/126/job/458"},{"name":"Unit Test","status":"completed","details_url":"https://github.com/j5ik2o/g2g/actions/runs/124/job/457"}]}]'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha/status"* ]]; then
  printf '%s\n' '{"statuses":[{"context":"Check unresolved comments","state":"pending","updated_at":"2026-06-02T00:00:00Z"},{"context":"CI Success","state":"success","updated_at":"2026-06-02T00:00:00Z"}]}'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/statuses/head-sha"* ]]; then
  cat >/dev/null
  printf '%s\n' '{"state":"success"}'
  exit 0
fi

echo "unexpected gh api call: $*" >&2
exit 1
EOF
chmod +x "$tmpdir/bin/gh"

cat > "$tmpdir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SLEEP_LOG"
EOF
chmod +x "$tmpdir/bin/sleep"

run_script() {
  GH_CALL_LOG="$tmpdir/calls.log" \
  GH_SLEEP_LOG="$tmpdir/sleeps.log" \
  PATH="$tmpdir/bin:$PATH" \
  REPOSITORY="j5ik2o/g2g" \
  BASE_BRANCH="main" \
  REQUIRED_CONTEXT="Check unresolved comments" \
  PUBLISH_STATUS="true" \
  SKIP_STATUS_FOR_DEPENDABOT="false" \
  EVENT_NAME="$1" \
  WAIT_FOR_OTHER_CHECKS="$2" \
  PR_NUMBER="27" \
  GITHUB_RUN_ID="123" \
    bash "$root/scripts/review-thread-resolution.sh"
}

: > "$tmpdir/calls.log"
: > "$tmpdir/sleeps.log"
run_script "workflow_dispatch" "true"
if grep -q '^pr view' "$tmpdir/calls.log"; then
  echo "gh pr view must not be used for check waiting." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "excluded review-thread checks must not trigger waiting." >&2
  exit 1
fi

: > "$tmpdir/calls.log"
: > "$tmpdir/sleeps.log"
GH_FAIL_CHECK_RUNS=1 run_script "workflow_dispatch" "false"
if grep -q 'check-runs' "$tmpdir/calls.log"; then
  echo "wait_for_other_checks=false must not fetch check-runs." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "wait_for_other_checks=false must not wait." >&2
  exit 1
fi

echo "review-thread-resolution smoke tests passed."
