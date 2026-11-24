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
    second_page=0
    [[ "$args" == *"cursor=threads-2"* ]] && second_page=1
    case "${GH_THREADS:-none}" in
      unresolved)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"path":"a.sh","line":1,"comments":{"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#discussion_r1","author":{"login":"human-reviewer"}}]}}]}}}}}'
        ;;
      paged|page2-error)
        if [[ "$second_page" -eq 0 ]]; then
          printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"threads-2"},"nodes":[{"isResolved":true,"path":"a.sh","line":1,"comments":{"nodes":[]}}]}}}}}'
        elif [[ "$GH_THREADS" == "paged" ]]; then
          printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"path":"b.sh","line":2,"comments":{"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#discussion_r2","author":{"login":"human-reviewer"}}]}}]}}}}}'
        else
          printf '%s\n' '{"errors":[{"message":"Something went wrong on page 2"}]}'
        fi
        ;;
      no-has-next)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"endCursor":"threads-2"},"nodes":[]}}}}}'
        ;;
      no-end-cursor)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}}'
        ;;
      null-pr)
        printf '%s\n' '{"data":{"repository":{"pullRequest":null}}}'
        ;;
      not-json)
        printf '%s\n' '<html>502 Bad Gateway</html>'
        ;;
      *)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        ;;
    esac
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
  printf '%s\n' 'head-sha'
  exit 0
fi

if [[ "$args" == *"repos/j5ik2o/g2g/commits/head-sha"*"/check-runs"* ]]; then
  if [[ "${GH_FAIL_CHECK_RUNS:-0}" == "1" ]]; then
    echo "check-runs endpoint should not be called" >&2
    exit 1
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
  : > "$tmpdir/summary.md"
}

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
  EVENT_NAME="$1" \
  WAIT_FOR_OTHER_CHECKS="$2" \
  PR_NUMBER="${TEST_PR_NUMBER-27}" \
  GITHUB_EVENT_PATH="${TEST_EVENT_PATH:-}" \
  GITHUB_RUN_ID="123" \
  GITHUB_STEP_SUMMARY="$tmpdir/summary.md" \
    bash "$root/scripts/review-thread-resolution.sh"
}

reset_logs
run_script "workflow_dispatch" "true"
if grep -q '^pr view' "$tmpdir/calls.log"; then
  echo "gh pr view must not be used for check waiting." >&2
  exit 1
fi
if [[ -s "$tmpdir/sleeps.log" ]]; then
  echo "a refresh must not wait." >&2
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

# Top-level comment lists larger than the execve argument limits.
reset_logs
GH_LARGE_COMMENTS=1 run_script "workflow_dispatch" "false" > "$tmpdir/out.log" 2>&1 && status=0 || status=$?
if [[ "$status" -ne 1 ]] || ! grep -q '300 unacknowledged top-level PR comment' "$tmpdir/out.log"; then
  cat "$tmpdir/out.log" >&2
  echo "large comment pages must all be counted (exit $status)." >&2
  exit 1
fi

# Event-driven refreshes never wait or poll, even while other checks are pending.
reset_logs
GH_PENDING_CHECK=1 run_script "pull_request_review" "true" > "$tmpdir/out.log" 2>&1 || {
  cat "$tmpdir/out.log" >&2
  echo "an event refresh with pending checks must still succeed." >&2
  exit 1
}
if [[ -s "$tmpdir/sleeps.log" ]] || grep -q 'check-runs' "$tmpdir/calls.log"; then
  echo "an event refresh must not wait for or inspect other checks." >&2
  exit 1
fi
if [[ "$(wc -l < "$tmpdir/status-payloads.log")" -ne 1 ]] \
  || ! grep -q '"state":"success"' "$tmpdir/status-payloads.log"; then
  cat "$tmpdir/status-payloads.log" >&2
  echo "an event refresh must publish exactly one conclusion." >&2
  exit 1
fi

# A failed or malformed fetch after the head is known fails the run and
# publishes error, so an earlier success on the same head does not stay.
expect_error_status() {
  local label="$1"
  shift
  reset_logs
  (export "$@"; run_script issue_comment true) > "$tmpdir/out.log" 2>&1 && status=0 || status=$?
  if [[ "$status" -ne 1 ]] \
    || [[ "$(wc -l < "$tmpdir/status-payloads.log")" -ne 1 ]] \
    || ! grep -q '"state":"error"' "$tmpdir/status-payloads.log"; then
    cat "$tmpdir/out.log" "$tmpdir/status-payloads.log" >&2
    echo "$label must fail the run and publish only error (exit $status)." >&2
    exit 1
  fi
}
expect_error_status "a failed comment fetch" GH_FAIL_COMMENTS=1
expect_error_status "an error on a later thread page" GH_THREADS=page2-error
expect_error_status "a page without hasNextPage" GH_THREADS=no-has-next
expect_error_status "a page with hasNextPage but no endCursor" GH_THREADS=no-end-cursor
expect_error_status "a response with a null pullRequest" GH_THREADS=null-pr
expect_error_status "a response that is not JSON" GH_THREADS=not-json

# Unresolved threads, including one on a later page, publish failure.
for mode in unresolved paged; do
  reset_logs
  GH_THREADS="$mode" run_script "issue_comment" "true" > "$tmpdir/out.log" 2>&1 || {
    cat "$tmpdir/out.log" >&2
    echo "an event refresh with unresolved threads ($mode) must keep the job successful." >&2
    exit 1
  }
  if ! grep -q '"state":"failure"' "$tmpdir/status-payloads.log" \
    || ! grep -q '^1 unresolved PR review thread' "$tmpdir/summary.md"; then
    cat "$tmpdir/out.log" "$tmpdir/summary.md" "$tmpdir/status-payloads.log" >&2
    echo "unresolved threads ($mode) must be counted and publish failure." >&2
    exit 1
  fi
done
reset_logs
GH_THREADS=unresolved run_script "issue_comment" "false" > "$tmpdir/out.log" 2>&1 && status=0 || status=$?
if [[ "$status" -ne 1 ]]; then
  echo "the CI gate mode must fail the job on unresolved threads (exit $status)." >&2
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
