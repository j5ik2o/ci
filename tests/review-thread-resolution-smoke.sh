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
    if [[ "${GH_FAIL_COMMENTS:-0}" == "1" ]]; then
      echo "comments query failed" >&2
      exit 1
    fi
    if [[ "${GH_LARGE_COMMENTS:-0}" == "1" ]]; then
      # Two pages of large human comments; the accumulated list exceeds the
      # execve argument limits.
      jq -n -c --arg second "$([[ "$args" == *"cursor=page-2"* ]] && echo 1 || echo 0)" '
        ("y" * 7000) as $pad
        | ($second == "1") as $is_second
        | {data: {repository: {pullRequest: {comments: {
            pageInfo: {hasNextPage: ($is_second | not), endCursor: (if $is_second then null else "page-2" end)},
            nodes: [range(150) as $i | {
              url: "https://github.com/j5ik2o/g2g/pull/27#issuecomment-\(if $is_second then 1000 + $i else $i end)",
              body: "Please fix \($i). \($pad)",
              createdAt: "2026-06-02T00:00:00Z",
              updatedAt: "2026-06-02T00:00:00Z",
              authorAssociation: "CONTRIBUTOR",
              author: {login: "human-reviewer"}
            }]
          }}}}}'
      exit 0
    fi
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
  head_calls=0
  if [[ -f "$GH_HEAD_CALLS" ]]; then
    head_calls="$(cat "$GH_HEAD_CALLS")"
  fi
  head_calls=$((head_calls + 1))
  printf '%s' "$head_calls" > "$GH_HEAD_CALLS"
  if [[ "${GH_HEAD_CHANGES:-0}" == "1" && "$head_calls" -gt 1 ]]; then
    printf '%s\n' 'head-sha-2'
  else
    printf '%s\n' 'head-sha'
  fi
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha"*"/check-runs"* ]]; then
  if [[ "${GH_FAIL_CHECK_RUNS:-0}" == "1" ]]; then
    echo "check-runs endpoint should not be called" >&2
    exit 1
  fi
  if [[ "${GH_LARGE_CHECK_RUNS:-0}" == "1" ]]; then
    # Three pages of 100 check runs with large output text, well above the
    # per-argument (Linux) and total-argument (macOS) execve limits.
    jq -n -c '
      ("x" * 7000) as $pad
      | [range(3) as $page | {check_runs: [range(100) as $i | {
          name: "History \($page)-\($i)",
          status: (if $page == 2 and $i == 99 then "in_progress" else "completed" end),
          details_url: "https://github.com/j5ik2o/g2g/actions/runs/\(1000 + $page * 100 + $i)/job/1",
          output: {summary: $pad}
        }]}]'
    exit 0
  fi
  if [[ "${GH_PENDING_CHECK:-0}" == "1" ]]; then
    printf '%s\n' '[{"check_runs":[{"name":"Build","status":"queued","details_url":"https://github.com/j5ik2o/g2g/actions/runs/200/job/1"}]}]'
    exit 0
  fi
  printf '%s\n' '[{"check_runs":[{"name":"refresh / Refresh review-thread state","status":"in_progress","details_url":"https://github.com/j5ik2o/g2g/actions/runs/125/job/456"},{"name":"ci-gate / CI Review Thread Gate","status":"in_progress","details_url":"https://github.com/j5ik2o/g2g/actions/runs/126/job/458"},{"name":"Unit Test","status":"completed","details_url":"https://github.com/j5ik2o/g2g/actions/runs/124/job/457"}]}]'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha"*"/status"* ]]; then
  printf '%s\n' '{"statuses":[{"context":"Check unresolved comments","state":"pending","updated_at":"2026-06-02T00:00:00Z"},{"context":"CI Success","state":"success","updated_at":"2026-06-02T00:00:00Z"}]}'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/statuses/head-sha"* ]]; then
  printf '%s ' "${args##*statuses/}" | cut -d' ' -f1 | tr -d '\n' >> "$GH_STATUS_PAYLOAD_LOG"
  printf ' ' >> "$GH_STATUS_PAYLOAD_LOG"
  jq -c '.' >> "$GH_STATUS_PAYLOAD_LOG"
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

reset_logs() {
  : > "$tmpdir/calls.log"
  : > "$tmpdir/sleeps.log"
  : > "$tmpdir/status-payloads.log"
  rm -f "$tmpdir/head-calls"
}

total_sleep_seconds() {
  awk '{ total += $1 } END { print total + 0 }' "$tmpdir/sleeps.log"
}

run_script() {
  local human_generic_review="${3:-0}"

  export GH_HUMAN_GENERIC_REVIEW="$human_generic_review"
  GH_CALL_LOG="$tmpdir/calls.log" \
  GH_SLEEP_LOG="$tmpdir/sleeps.log" \
  GH_STATUS_PAYLOAD_LOG="$tmpdir/status-payloads.log" \
  GH_HEAD_CALLS="$tmpdir/head-calls" \
  PATH="$tmpdir/bin:$PATH" \
  REPOSITORY="j5ik2o/g2g" \
  BASE_BRANCH="main" \
  REQUIRED_CONTEXT="Check unresolved comments" \
  PUBLISH_STATUS="true" \
  SKIP_STATUS_FOR_DEPENDABOT="false" \
  EXTRA_IGNORED_AUTO_REPORT_PATTERNS="<!-- another-review-bot-summary -->" \
  EVENT_NAME="$1" \
  WAIT_FOR_OTHER_CHECKS="$2" \
  PR_NUMBER="${TEST_PR_NUMBER-27}" \
  GITHUB_EVENT_PATH="${TEST_EVENT_PATH:-}" \
  WAIT_TIMEOUT_SECONDS="${TEST_WAIT_TIMEOUT_SECONDS:-}" \
  GITHUB_RUN_ID="123" \
    bash "$root/scripts/review-thread-resolution.sh"
}

reset_logs
run_script "workflow_dispatch" "true"
if grep -q '^pr view' "$tmpdir/calls.log"; then
  echo "gh pr view must not be used for check waiting." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "excluded review-thread checks must not trigger waiting." >&2
  exit 1
fi
if ! grep -q '"state":"success"' "$tmpdir/status-payloads.log"; then
  echo "ignored bot summaries must keep the synthetic status successful." >&2
  exit 1
fi

reset_logs
run_script "workflow_dispatch" "true" "1"
if ! grep -q '"state":"failure"' "$tmpdir/status-payloads.log"; then
  echo "human comments with generic report headings must not be ignored." >&2
  exit 1
fi

reset_logs
GH_FAIL_CHECK_RUNS=1 run_script "workflow_dispatch" "false"
if grep -q 'check-runs' "$tmpdir/calls.log"; then
  echo "wait_for_other_checks=false must not fetch check-runs." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "wait_for_other_checks=false must not wait." >&2
  exit 1
fi

# check-runs responses larger than the execve argument limits (#17).
reset_logs
GH_LARGE_CHECK_RUNS=1 run_script "workflow_dispatch" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "a large check-runs response must not break the other-check wait." >&2
  exit 1
}
if ! grep -q 'check: History 2-99 \[in_progress\]' "$tmpdir/out.log"; then
  cat "$tmpdir/out.log" >&2
  echo "the pending check on the last check-runs page must be reported." >&2
  exit 1
fi

# Top-level comment lists larger than the execve argument limits.
reset_logs
GH_LARGE_COMMENTS=1 run_script "workflow_dispatch" "false" > "$tmpdir/out.log" 2>&1 && status=0 || status=$?
if [[ "$status" -ne 1 ]] || ! grep -q '300 unacknowledged top-level PR comment' "$tmpdir/out.log"; then
  cat "$tmpdir/out.log" >&2
  echo "large comment pages must all be counted (exit $status)." >&2
  exit 1
fi

# Event-driven waits are bounded, publish pending while waiting, and still
# publish a final conclusion when other checks never finish.
reset_logs
GH_PENDING_CHECK=1 TEST_WAIT_TIMEOUT_SECONDS=60 run_script "pull_request_review" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "a wait that runs out of budget must not fail the refresh." >&2
  exit 1
}
if [[ "$(total_sleep_seconds)" -gt 60 ]]; then
  echo "the wait slept $(total_sleep_seconds)s, beyond the 60s budget." >&2
  exit 1
fi
if [[ "$(head -n 1 "$tmpdir/status-payloads.log")" != *'"state":"pending"'* ]] \
  || [[ "$(tail -n 1 "$tmpdir/status-payloads.log")" != *'"state":"success"'* ]] \
  || [[ "$(wc -l < "$tmpdir/status-payloads.log")" -ne 2 ]]; then
  cat "$tmpdir/status-payloads.log" >&2
  echo "the wait must publish pending once, then the final conclusion." >&2
  exit 1
fi

# A failed evaluation after the wait replaces the pending status with an error.
reset_logs
GH_FAIL_COMMENTS=1 GH_PENDING_CHECK=1 TEST_WAIT_TIMEOUT_SECONDS=10 run_script "issue_comment" "true" > "$tmpdir/out.log" 2>&1 && status=0 || status=$?
if [[ "$status" -ne 1 ]] \
  || [[ "$(head -n 1 "$tmpdir/status-payloads.log")" != *'"state":"pending"'* ]] \
  || [[ "$(tail -n 1 "$tmpdir/status-payloads.log")" != 'head-sha '*'"state":"error"'* ]]; then
  cat "$tmpdir/out.log" "$tmpdir/status-payloads.log" >&2
  echo "a failed evaluation must fail the run and replace pending with error (exit $status)." >&2
  exit 1
fi

# The default event budget stays short (10 minutes of sleeping).
reset_logs
GH_PENDING_CHECK=1 run_script "issue_comment" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "the default event wait must end with a published conclusion." >&2
  exit 1
}
if [[ "$(total_sleep_seconds)" -gt 600 ]]; then
  echo "the default event wait slept $(total_sleep_seconds)s, beyond 600s." >&2
  exit 1
fi

# A head change during an event-driven wait moves the evaluation to the new head.
reset_logs
GH_HEAD_CHANGES=1 GH_PENDING_CHECK=1 TEST_WAIT_TIMEOUT_SECONDS=30 run_script "pull_request_review_comment" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "a head change during the wait must not fail the refresh." >&2
  exit 1
}
if [[ "$(tail -n 1 "$tmpdir/status-payloads.log")" != 'head-sha-2 '*'"state":"success"'* ]]; then
  cat "$tmpdir/status-payloads.log" >&2
  echo "the final conclusion must be published on the latest head." >&2
  exit 1
fi

# workflow_run events resolve the PR from the event, and skip runs without a PR.
reset_logs
printf '%s\n' '{"workflow_run":{"pull_requests":[{"number":27}]}}' > "$tmpdir/workflow-run-pr.json"
TEST_PR_NUMBER="" TEST_EVENT_PATH="$tmpdir/workflow-run-pr.json" run_script "workflow_run" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "workflow_run events must resolve the PR number." >&2
  exit 1
}
if ! grep -q '"state":"success"' "$tmpdir/status-payloads.log"; then
  echo "workflow_run events must publish the conclusion." >&2
  exit 1
fi
reset_logs
printf '%s\n' '{"workflow_run":{"pull_requests":[]}}' > "$tmpdir/workflow-run-push.json"
TEST_PR_NUMBER="" TEST_EVENT_PATH="$tmpdir/workflow-run-push.json" run_script "workflow_run" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "workflow_run events without a PR must be skipped." >&2
  exit 1
}
if [[ -s "$tmpdir/calls.log" ]]; then
  echo "workflow_run events without a PR must not call the API." >&2
  exit 1
fi

echo "review-thread-resolution smoke tests passed."
