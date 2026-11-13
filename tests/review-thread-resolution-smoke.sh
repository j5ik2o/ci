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
    if [[ "${GH_HUMAN_GENERIC_REVIEW:-0}" == "1" ]]; then
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-3","body":"## Walkthrough\n\nThis is a human review note.","state":"COMMENTED","submittedAt":"2026-06-02T00:00:02Z","updatedAt":"2026-06-02T00:00:02Z","authorAssociation":"CONTRIBUTOR","author":{"login":"human-reviewer"}}]}}}}}'
    else
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-1","body":"**Devin Review** found 1 potential issue.\n\n<!-- devin-review-badge-begin -->","state":"COMMENTED","submittedAt":"2026-06-02T00:00:00Z","updatedAt":"2026-06-02T00:00:00Z","authorAssociation":"NONE","author":{"login":"devin-ai-integration"}},{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-2","body":"Another Review Bot found 1 potential issue.\n\n<!-- another-review-bot-summary -->","state":"COMMENTED","submittedAt":"2026-06-02T00:00:01Z","updatedAt":"2026-06-02T00:00:01Z","authorAssociation":"NONE","author":{"login":"another-review-bot"}},{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-4","body":"## Walkthrough\n\nAutomated summary.","state":"COMMENTED","submittedAt":"2026-06-02T00:00:03Z","updatedAt":"2026-06-02T00:00:03Z","authorAssociation":"NONE","author":{"login":"coderabbitai"}}]}}}}}'
    fi
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
  case "${GH_OTHER_CHECK:-success}" in
    pending) unit_test='"status":"in_progress","conclusion":null' ;;
    *) unit_test="\"status\":\"completed\",\"conclusion\":\"${GH_OTHER_CHECK:-success}\"" ;;
  esac
  printf '%s\n' '[{"check_runs":[{"name":"refresh / Refresh review-thread state","status":"in_progress","conclusion":null,"details_url":"https://github.com/j5ik2o/g2g/actions/runs/125/job/456"},{"name":"ci-gate / CI Review Thread Gate","status":"completed","conclusion":"failure","details_url":"https://github.com/j5ik2o/g2g/actions/runs/126/job/458"},{"name":"Current run job","status":"in_progress","conclusion":null,"details_url":"https://github.com/j5ik2o/g2g/actions/runs/123/job/459"},{"name":"ci / Build","status":"completed","conclusion":"success","details_url":"https://github.com/j5ik2o/g2g/actions/runs/124/job/461"},{"name":"Lint","status":"completed","conclusion":"skipped","details_url":"https://github.com/j5ik2o/g2g/actions/runs/124/job/460"},{"name":"Unit Test",'"$unit_test"',"details_url":"https://github.com/j5ik2o/g2g/actions/runs/124/job/457"}]}]'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha/status"* ]]; then
  if [[ "${GH_FAIL_STATUS_INACCESSIBLE:-0}" == "1" ]]; then
    echo "HTTP 403: Resource not accessible by integration" >&2
    exit 1
  fi
  printf '%s\n' '[{"statuses":[{"context":"Check unresolved comments","state":"failure","updated_at":"2026-06-02T00:00:00Z"},{"context":"CI Success","state":"pending","updated_at":"2026-06-01T00:00:00Z"},{"context":"CI Success","state":"'"${GH_OTHER_STATUS:-success}"'","updated_at":"2026-06-02T00:00:00Z"},{"context":"Aggregate CI","state":"failure","updated_at":"2026-06-02T00:00:00Z"}]}]'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/statuses/head-sha"* ]]; then
  cat >> "$GH_STATUS_PAYLOAD_LOG"
  printf '\n' >> "$GH_STATUS_PAYLOAD_LOG"
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
  local human_generic_review="${3:-0}"

  export GH_HUMAN_GENERIC_REVIEW="$human_generic_review"
  GH_CALL_LOG="$tmpdir/calls.log" \
  GH_SLEEP_LOG="$tmpdir/sleeps.log" \
  GH_STATUS_PAYLOAD_LOG="$tmpdir/status-payloads.log" \
  PATH="$tmpdir/bin:$PATH" \
  REPOSITORY="j5ik2o/g2g" \
  BASE_BRANCH="main" \
  REQUIRED_CONTEXT="Check unresolved comments" \
  PUBLISH_STATUS="true" \
  SKIP_STATUS_FOR_DEPENDABOT="false" \
  EXTRA_IGNORED_AUTO_REPORT_PATTERNS="<!-- another-review-bot-summary -->" \
  EXTRA_EXCLUDED_CHECK_NAMES="${SMOKE_EXCLUDED-Aggregate CI}" \
  EVENT_NAME="$1" \
  WAIT_FOR_OTHER_CHECKS="$2" \
  PR_NUMBER="${SMOKE_PR_NUMBER-27}" \
  GITHUB_RUN_ID="123" \
    bash "$root/scripts/review-thread-resolution.sh"
}

: > "$tmpdir/calls.log"
: > "$tmpdir/sleeps.log"
: > "$tmpdir/status-payloads.log"
run_script "workflow_dispatch" "true"
if grep -q '^pr view' "$tmpdir/calls.log"; then
  echo "gh pr view must not be used for check waiting." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "excluded review-thread checks must not trigger waiting." >&2
  exit 1
fi
if ! grep -q '"state": "success"' "$tmpdir/status-payloads.log"; then
  echo "ignored bot summaries must keep the synthetic status successful." >&2
  exit 1
fi

: > "$tmpdir/calls.log"
: > "$tmpdir/sleeps.log"
: > "$tmpdir/status-payloads.log"
run_script "workflow_dispatch" "true" "1"
if ! grep -q '"state": "failure"' "$tmpdir/status-payloads.log"; then
  echo "human comments with generic report headings must not be ignored." >&2
  exit 1
fi

reset_logs() {
  : > "$tmpdir/calls.log"
  : > "$tmpdir/sleeps.log"
  : > "$tmpdir/status-payloads.log"
}

expect_state() {
  local expected="$1"
  local message="$2"
  local actual

  actual="$(jq -r '.state' "$tmpdir/status-payloads.log" | tail -n 1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "$message (expected $expected, got ${actual:-none})" >&2
    exit 1
  fi
}

reset_logs
run_script "workflow_dispatch" "false"
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "wait_for_other_checks=false must not wait." >&2
  exit 1
fi
if ! grep -q 'check-runs' "$tmpdir/calls.log"; then
  echo "the gate must read other checks even when it does not wait for them." >&2
  exit 1
fi
expect_state success "green other checks and no review state must publish success."

for conclusion in failure cancelled timed_out action_required; do
  reset_logs
  GH_OTHER_CHECK="$conclusion" run_script "pull_request" "true"
  expect_state failure "an other check concluding $conclusion must publish failure."
done

reset_logs
GH_OTHER_CHECK=neutral run_script "pull_request" "true"
expect_state success "a neutral other check must count as passing."

reset_logs
GH_OTHER_STATUS=error run_script "pull_request" "true"
expect_state failure "a failing commit status from another context must publish failure."

reset_logs
GH_OTHER_CHECK=failure run_script "workflow_dispatch" "false"
expect_state failure "wait_for_other_checks=false must still publish failure for a failing other check."

reset_logs
GH_OTHER_CHECK=pending run_script "workflow_dispatch" "true"
expect_state pending "an other check still running after the wait must publish pending."
if [[ "$(wc -l < "$tmpdir/sleeps.log")" -ne 2 ]]; then
  echo "workflow_dispatch must wait three attempts before publishing pending." >&2
  exit 1
fi

reset_logs
GH_OTHER_CHECK=failure run_script "workflow_dispatch" "true" "1"
expect_state failure "review state and a failing other check must publish failure."

reset_logs
SMOKE_EXCLUDED="" run_script "pull_request" "true"
expect_state failure "a failing status that is not excluded must publish failure."

reset_logs
run_script "pull_request" "false"
expect_state pending "CI gate mode cannot see its own run and must not publish success."

reset_logs
EXPECTED_CHECK_NAMES=$'Build\n  CI Success  ' run_script "pull_request" "true"
expect_state success "expected checks that reported, matched by job name or status context, must not block."

reset_logs
EXPECTED_CHECK_NAMES="Integration Test" run_script "pull_request" "true"
expect_state pending "an expected check that has not reported yet must publish pending."

reset_logs
GH_FAIL_STATUS_INACCESSIBLE=1 run_script "pull_request" "true"
expect_state pending "unreadable other checks must publish pending."

printf '%s\n' '{"check_suite":{"pull_requests":[{"number":27}]}}' > "$tmpdir/check-suite-event.json"
reset_logs
SMOKE_PR_NUMBER="" GITHUB_EVENT_PATH="$tmpdir/check-suite-event.json" run_script "check_suite" "true"
expect_state success "a check_suite event must re-evaluate its pull request."

printf '%s\n' '{"workflow_run":{"pull_requests":[{"number":27}]}}' > "$tmpdir/workflow-run-event.json"
reset_logs
SMOKE_PR_NUMBER="" GITHUB_EVENT_PATH="$tmpdir/workflow-run-event.json" run_script "workflow_run" "true"
expect_state success "a workflow_run event must re-evaluate its pull request."

printf '%s\n' '{"workflow_run":{"pull_requests":[]}}' > "$tmpdir/workflow-run-fork-event.json"
reset_logs
SMOKE_PR_NUMBER="" GITHUB_EVENT_PATH="$tmpdir/workflow-run-fork-event.json" run_script "workflow_run" "true"
if [[ -s "$tmpdir/status-payloads.log" ]]; then
  echo "a workflow_run event without a pull request must not publish a status." >&2
  exit 1
fi

echo "review-thread-resolution smoke tests passed."
