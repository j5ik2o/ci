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
  # An empty or whitespace-only body from a successful gh call.
  if [[ -n "${GH_EMPTY_FETCH:-}" && "$args" == *"${GH_EMPTY_FETCH}(first: 100"* ]]; then
    [[ "${GH_EMPTY_BODY:-empty}" == "blank" ]] && printf '  \n\n'
    exit 0
  fi
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
    # A fixed comment list from a fixture file (author, body, createdAt,
    # updatedAt). The fixture is a JSON array of GraphQL comment nodes.
    if [[ -n "${GH_COMMENTS_FILE:-}" ]]; then
      jq -n --slurpfile nodes "$GH_COMMENTS_FILE" '
        {data: {repository: {pullRequest: {comments: {
          pageInfo: {hasNextPage: false, endCursor: null},
          nodes: $nodes[0]
        }}}}}'
      exit 0
    fi
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
    # A fixed review list from a fixture file. The runner applies the same
    # state/body filter it applies to live responses.
    if [[ -n "${GH_REVIEWS_FILE:-}" ]]; then
      jq -n --slurpfile nodes "$GH_REVIEWS_FILE" '
        {data: {repository: {pullRequest: {reviews: {
          pageInfo: {hasNextPage: false, endCursor: null},
          nodes: $nodes[0]
        }}}}}'
      exit 0
    fi
    if [[ "${GH_HUMAN_GENERIC_REVIEW:-0}" == "1" ]]; then
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-3","body":"## Walkthrough\n\nThis is a human review note.","state":"COMMENTED","submittedAt":"2026-06-02T00:00:02Z","updatedAt":"2026-06-02T00:00:02Z","authorAssociation":"CONTRIBUTOR","author":{"login":"human-reviewer"}}]}}}}}'
    else
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-1","body":"**Devin Review** found 1 potential issue.\n\n<!-- devin-review-badge-begin -->","state":"COMMENTED","submittedAt":"2026-06-02T00:00:00Z","updatedAt":"2026-06-02T00:00:00Z","authorAssociation":"NONE","author":{"login":"devin-ai-integration"}},{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-2","body":"Another Review Bot found 1 potential issue.\n\n<!-- another-review-bot-summary -->","state":"COMMENTED","submittedAt":"2026-06-02T00:00:01Z","updatedAt":"2026-06-02T00:00:01Z","authorAssociation":"NONE","author":{"login":"another-review-bot"}},{"url":"https://github.com/j5ik2o/g2g/pull/27#pullrequestreview-4","body":"## Walkthrough\n\nAutomated summary.","state":"COMMENTED","submittedAt":"2026-06-02T00:00:03Z","updatedAt":"2026-06-02T00:00:03Z","authorAssociation":"NONE","author":{"login":"coderabbitai"}}]}}}}}'
    fi
  else
    jq -n \
      --arg author "${GH_PR_AUTHOR:-alice}" \
      --arg author_type "${GH_PR_AUTHOR_TYPE:-User}" \
      --arg repository "${GH_PR_REPO:-j5ik2o/g2g}" \
      --arg url "${GH_PR_URL:-https://github.com/j5ik2o/g2g/pull/27}" '
      {data: {repository: {pullRequest: {
        author: {__typename: $author_type, login: $author},
        baseRefName: "main",
        headRepository: {nameWithOwner: $repository},
        headRefOid: "head-sha",
        url: $url
      }}}}'
  fi
  exit 0
fi

if [[ "$args" == *"repos/${GH_REPO_PATH:-j5ik2o/g2g}/pulls/${GH_PR_NUMBER:-27}"* ]]; then
  printf '%s\n' 'head-sha'
  exit 0
fi

if [[ "$args" == *"repos/${GH_REPO_PATH:-j5ik2o/g2g}/commits/head-sha"*"/check-runs"* ]]; then
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

if [[ "$args" == *"repos/${GH_REPO_PATH:-j5ik2o/g2g}/commits/head-sha"*"/status"* ]]; then
  printf '%s\n' '{"statuses":[{"context":"Check unresolved comments","state":"pending","updated_at":"2026-06-02T00:00:00Z"},{"context":"CI Success","state":"success","updated_at":"2026-06-02T00:00:00Z"}]}'
  exit 0
fi

if [[ "$args" == *"repos/${GH_REPO_PATH:-j5ik2o/g2g}/statuses/head-sha"* ]]; then
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
  local repository="${TEST_REPOSITORY:-j5ik2o/g2g}"
  local pr_number="${TEST_PR_NUMBER-27}"

  export GH_HUMAN_GENERIC_REVIEW="$human_generic_review"
  GH_CALL_LOG="$tmpdir/calls.log" \
  GH_SLEEP_LOG="$tmpdir/sleeps.log" \
  GH_STATUS_PAYLOAD_LOG="$tmpdir/status-payloads.log" \
  PATH="$tmpdir/bin:$PATH" \
  REPOSITORY="$repository" \
  BASE_BRANCH="main" \
  REQUIRED_CONTEXT="Check unresolved comments" \
  PUBLISH_STATUS="true" \
  SKIP_STATUS_FOR_DEPENDABOT="false" \
  EXTRA_IGNORED_AUTO_REPORT_PATTERNS="<!-- another-review-bot-summary -->" \
  EVENT_NAME="$1" \
  WAIT_FOR_OTHER_CHECKS="$2" \
  PR_NUMBER="$pr_number" \
  GITHUB_EVENT_PATH="${TEST_EVENT_PATH:-}" \
  GITHUB_RUN_ID="123" \
  GITHUB_STEP_SUMMARY="$tmpdir/summary.md" \
  GH_REPO_PATH="$repository" \
  GH_PR_NUMBER="$pr_number" \
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
for fetch in reviewThreads comments reviews; do
  for body in empty blank; do
    expect_error_status "an $body $fetch response" GH_EMPTY_FETCH="$fetch" GH_EMPTY_BODY="$body"
  done
done

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

# ---------------------------------------------------------------------------
# issue #134: the acceptance rule must require both an explicit acknowledgement
# word and a reference to the acknowledged item. These cases are written
# against the proposed rule (docs/design/issue-134.md in takt-dash), so they
# are expected to fail on the current v1 script.
# ---------------------------------------------------------------------------

pr_url="https://github.com/j5ik2o/g2g/pull/27"
item_body="The retry path is still broken. Please fix it."
other_item_body="The queue drains twice on shutdown. Please check it."
item_quote="The retry path is still broken"
limit_body="You have reached your Codex usage limits for code reviews."

fixture_comment() {
  local url="$1"
  local body="$2"
  local created="$3"
  local updated="${4:-$3}"
  local login="${5:-chatgpt-codex-connector}"
  local association="${6:-NONE}"

  jq -cn \
    --arg url "$url" \
    --arg body "$body" \
    --arg created "$created" \
    --arg updated "$updated" \
    --arg login "$login" \
    --arg association "$association" '
    {
      url: $url,
      body: $body,
      createdAt: $created,
      updatedAt: $updated,
      authorAssociation: $association,
      author: {login: $login}
    }'
}

fixture_review() {
  local url="$1"
  local body="$2"
  local created="$3"
  local updated="${4:-$3}"
  local login="${5:-coderabbitai}"
  local association="${6:-NONE}"

  jq -cn \
    --arg url "$url" \
    --arg body "$body" \
    --arg created "$created" \
    --arg updated "$updated" \
    --arg login "$login" \
    --arg association "$association" '
    {
      url: $url,
      body: $body,
      state: "COMMENTED",
      submittedAt: $created,
      updatedAt: $updated,
      authorAssociation: $association,
      author: {login: $login}
    }'
}

write_fixture() {
  local file="$1"
  shift

  if [[ "$#" -eq 0 ]]; then
    printf '[]\n' > "$file"
  else
    printf '%s\n' "$@" | jq -s '.' > "$file"
  fi
}

smoke_failures=0

assert_conclusion() {
  local label="$1"
  local want_items="$2"
  local want_state="$3"
  shift 3

  local status=0
  reset_logs
  ( export "$@"; run_script issue_comment true ) > "$tmpdir/out.log" 2>&1 || status=$?

  local items state
  items="$(sed -n 's/^.* and \([0-9][0-9]*\) unacknowledged.*$/\1/p' "$tmpdir/summary.md" 2>/dev/null | head -1 || true)"
  state="$(grep -o '"state":"[a-z]*"' "$tmpdir/status-payloads.log" 2>/dev/null | tail -1 | sed 's/.*"state":"//; s/"$//' || true)"

  if [[ "$status" -ne 0 || "$items" != "$want_items" || "$state" != "$want_state" ]]; then
    smoke_failures=$((smoke_failures + 1))
    printf 'not ok - %s (want %s item(s) / %s; got %s / %s; exit %s)\n' \
      "$label" "$want_items" "$want_state" "${items:-?}" "${state:-?}" "$status" >&2
    sed 's/^/    /' "$tmpdir/summary.md" >&2 2>/dev/null || true
    sed 's/^/    /' "$tmpdir/out.log" >&2 2>/dev/null || true
  else
    printf 'ok - %s\n' "$label"
  fi
}

# 1. Unrelated author comments do not acknowledge anything (#134 core).
write_fixture "$tmpdir/comments-01.json" \
  "$(fixture_comment "$pr_url#issuecomment-101" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-201" "ありがとう" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-202" "別件です" "2026-06-02T00:20:00Z" "" alice)"
assert_conclusion "1 unrelated author comments stay red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-01.json"

# 2. A failure report whose whole body is a code fence is not an item and not
# an acknowledgement. On its own it leaves the gate green; an unrelated item
# still keeps it red.
write_fixture "$tmpdir/comments-02a.json" \
  "$(fixture_comment "$pr_url#issuecomment-102" $'```\n'"$item_body"$'\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "2a whole-fence failure report is not an item" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-02a.json"
write_fixture "$tmpdir/comments-02b.json" \
  "$(fixture_comment "$pr_url#issuecomment-101" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-102" $'```\n'"$item_body"$'\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "2b whole-fence failure report does not acknowledge" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-02b.json"

# 3. A target URL with an acknowledgement word passes even when the target
# body is shorter than 20 characters (# must survive normalisation).
write_fixture "$tmpdir/comments-03.json" \
  "$(fixture_comment "$pr_url#issuecomment-103" "Fix it." "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-203" "$pr_url#issuecomment-103 確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "3 URL acknowledgement of a short target" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-03.json"

# 4. A target anchor (issue comment and review) with an acknowledgement word.
write_fixture "$tmpdir/comments-04.json" \
  "$(fixture_comment "$pr_url#issuecomment-104" "Fix it." "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-204" "#issuecomment-104 確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "4a issue-comment anchor acknowledgement" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-04.json"
write_fixture "$tmpdir/reviews-04.json" \
  "$(fixture_review "$pr_url#pullrequestreview-704" "Legacy code path needs a guard." "2026-06-02T00:00:00Z" "" reviewer-bot)"
write_fixture "$tmpdir/comments-04b.json" \
  "$(fixture_comment "$pr_url#issuecomment-205" "#pullrequestreview-704 確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "4b review anchor acknowledgement" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-04b.json" GH_REVIEWS_FILE="$tmpdir/reviews-04.json"

# 5. A 20+ character quote with an acknowledgement word passes, including a
# quote wrapped in a code fence (#131's real acknowledgement shape).
write_fixture "$tmpdir/comments-05.json" \
  "$(fixture_comment "$pr_url#issuecomment-105" "Review rate limited / Action not completed. Try again later." "2026-06-02T00:00:00Z" "" coderabbitai)" \
  "$(fixture_comment "$pr_url#issuecomment-205" "「Review rate limited / Action not completed」を確認しました。" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "5a quote acknowledgement" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-05.json"
write_fixture "$tmpdir/comments-05b.json" \
  "$(fixture_comment "$pr_url#issuecomment-105" "Review rate limited / Action not completed. Try again later." "2026-06-02T00:00:00Z" "" coderabbitai)" \
  "$(fixture_comment "$pr_url#issuecomment-206" $'確認しました\n```\nReview rate limited / Action not completed\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "5b fenced-quote acknowledgement" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-05b.json"

# 6. An acknowledgement word alone (no reference) does not pass.
write_fixture "$tmpdir/comments-06.json" \
  "$(fixture_comment "$pr_url#issuecomment-106" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-206" "確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "6 acknowledgement word alone stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-06.json"

# 7. A reference alone (no acknowledgement word) does not pass.
write_fixture "$tmpdir/comments-07.json" \
  "$(fixture_comment "$pr_url#issuecomment-107" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-207" "$pr_url#issuecomment-107" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "7 reference alone stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-07.json"

# 8. A URL of a different comment does not acknowledge the item.
write_fixture "$tmpdir/comments-08.json" \
  "$(fixture_comment "$pr_url#issuecomment-108" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-109" "$other_item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-209" "$pr_url#issuecomment-109 確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "8 another comment's URL does not acknowledge" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-08.json"

# 9. An acknowledgement posted before the item does not count.
write_fixture "$tmpdir/comments-09.json" \
  "$(fixture_comment "$pr_url#issuecomment-109" "$pr_url#issuecomment-110 確認しました" "2026-06-02T00:05:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-110" "$item_body" "2026-06-02T00:10:00Z" "" reviewer-bot)"
assert_conclusion "9 acknowledgement before the item stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-09.json"

# 10. An acknowledgement before the item's last edit does not count; one
# posted after the edit does.
write_fixture "$tmpdir/comments-10.json" \
  "$(fixture_comment "$pr_url#issuecomment-111" "$item_body" "2026-06-02T00:00:00Z" "2026-06-02T00:20:00Z" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-211" "$pr_url#issuecomment-111 確認しました" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "10a acknowledgement before the edit stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-10.json"
write_fixture "$tmpdir/comments-10b.json" \
  "$(fixture_comment "$pr_url#issuecomment-111" "$item_body" "2026-06-02T00:00:00Z" "2026-06-02T00:20:00Z" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-211" "$pr_url#issuecomment-111 確認しました" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-212" "$pr_url#issuecomment-111 確認しました" "2026-06-02T00:30:00Z" "" alice)"
assert_conclusion "10b acknowledgement after the edit passes" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-10b.json"

# 11. Acknowledgement words inside a backtick fence are not counted, and a
# substring such as "unacknowledged" is not a match either.
write_fixture "$tmpdir/comments-11.json" \
  "$(fixture_comment "$pr_url#issuecomment-112" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-212" $'メモ\n```\n確認しました\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "11a backtick-fenced acknowledgement stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-11.json"
write_fixture "$tmpdir/comments-11b.json" \
  "$(fixture_comment "$pr_url#issuecomment-113" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-213" "This is unacknowledged." "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "11b unacknowledged is not a match" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-11b.json"

# 12. Acknowledgement words inside a tilde fence are not counted.
write_fixture "$tmpdir/comments-12.json" \
  "$(fixture_comment "$pr_url#issuecomment-114" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-214" $'メモ\n~~~\n確認しました\n~~~' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "12 tilde-fenced acknowledgement stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-12.json"

# 13. HTML comment removal runs from <!-- to -->, even when the comment
# contains ">", so the quote after it still matches.
write_fixture "$tmpdir/comments-13.json" \
  "$(fixture_comment "$pr_url#issuecomment-115" $'The cache key ignores the tenant.\n<!-- internal > note -->\nPlease fix the cache key.' "2026-06-02T00:00:00Z" "" coderabbitai)" \
  "$(fixture_comment "$pr_url#issuecomment-215" "確認しました。The cache key ignores the tenant." "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "13 HTML comment with > keeps the quote" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-13.json"

# 14. Negated or interrogative acknowledgement words do not pass.
write_fixture "$tmpdir/comments-14.json" \
  "$(fixture_comment "$pr_url#issuecomment-116" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-216" "未確認しました $pr_url#issuecomment-116" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-117" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-217" "未対応済み $pr_url#issuecomment-117" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-118" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-218" "not fixed $pr_url#issuecomment-118" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-119" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-219" "確認しましたか？ $pr_url#issuecomment-119" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "14 negated or interrogative acknowledgement stays red" 4 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-14.json"

# 15. The words v1 accepted remain valid with a reference.
write_fixture "$tmpdir/comments-15.json" \
  "$(fixture_comment "$pr_url#issuecomment-120" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-220" "対処しました $pr_url#issuecomment-120" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-121" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-221" "直しました $pr_url#issuecomment-121" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-122" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-222" "対応いたしました $pr_url#issuecomment-122" "2026-06-02T00:10:00Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-123" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-223" "確認いたしました $pr_url#issuecomment-123" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "15 v1 words with a reference pass" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-15.json"

# 16a. An author report with the marker outside a fence is an auto report:
# not an item and not an acknowledgement.
write_fixture "$tmpdir/comments-16a.json" \
  "$(fixture_comment "$pr_url#issuecomment-124" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-224" $'<!-- takt:auto-report -->\n対応しました\n'"$item_body" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "16a author marker report does not acknowledge" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-16a.json"
# 16b. A marker added by a third party is neither an auto report nor an
# acknowledgement, so it stays an unacknowledged item.
write_fixture "$tmpdir/comments-16b.json" \
  "$(fixture_comment "$pr_url#issuecomment-125" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-225" $'<!-- takt:auto-report -->\n対応しました\n'"$item_body" "2026-06-02T00:10:00Z" "" reviewer-bot)"
assert_conclusion "16b third-party marker stays an item" 2 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-16b.json"
# 16c. Prose plus a fence is not an auto report; the prose word and the fenced
# quote together acknowledge the item.
write_fixture "$tmpdir/comments-16c.json" \
  "$(fixture_comment "$pr_url#issuecomment-126" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-226" $'対応しました\n```\n'"$item_body"$'\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "16c prose plus fence acknowledges" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-16c.json"
# 16d. Quoting a marker report inside a fence: the marker is inside the fence,
# so the comment is not an auto report and does acknowledge.
write_fixture "$tmpdir/comments-16d.json" \
  "$(fixture_comment "$pr_url#issuecomment-127" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-227" $'確認しました\n```\n<!-- takt:auto-report -->\n'"$item_body"$'\n```' "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "16d marker quoted in a fence acknowledges" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-16d.json"

# 17. Third-party acknowledgements do not count. For a Bot-authored PR, an
# OWNER / MEMBER / COLLABORATOR comment does. The coderabbitai comment below is
# an ignored bot report ("## Walkthrough"), so it is not an item itself and
# only the reviewer-bot item remains.
write_fixture "$tmpdir/comments-17a.json" \
  "$(fixture_comment "$pr_url#issuecomment-128" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-228" $'## Walkthrough\n\n確認しました '"$pr_url#issuecomment-128" "2026-06-02T00:10:00Z" "" coderabbitai NONE)"
assert_conclusion "17a third-party acknowledgement stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-17a.json"
write_fixture "$tmpdir/comments-17b.json" \
  "$(fixture_comment "$pr_url#issuecomment-129" "$item_body" "2026-06-02T00:00:00Z" "" coderabbitai)" \
  "$(fixture_comment "$pr_url#issuecomment-229" "確認しました $pr_url#issuecomment-129" "2026-06-02T00:10:00Z" "" alice OWNER)"
assert_conclusion "17b OWNER acknowledgement on a Bot PR passes" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-17b.json" \
  GH_PR_AUTHOR="takt-bot" GH_PR_AUTHOR_TYPE="Bot"

# 18. #131's real timeline. The failure report alone does not acknowledge;
# the 02:49:20 quote plus 確認しました does.
write_fixture "$tmpdir/comments-18a.json" \
  "$(fixture_comment "$pr_url#issuecomment-301" $'Codex Review Summary\n\nNo findings on this commit.' "2026-11-16T01:28:11Z" "" chatgpt-codex-connector)" \
  "$(fixture_comment "$pr_url#issuecomment-302" "$limit_body" "2026-11-16T01:28:14Z" "" chatgpt-codex-connector)" \
  "$(fixture_comment "$pr_url#issuecomment-303" $'TAKTのCI回復を停止しました。\n\n'"$limit_body" "2026-11-16T02:46:31Z" "" alice)"
assert_conclusion "18a #131 failure report alone stays red" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-18a.json"
write_fixture "$tmpdir/comments-18b.json" \
  "$(fixture_comment "$pr_url#issuecomment-301" $'Codex Review Summary\n\nNo findings on this commit.' "2026-11-16T01:28:11Z" "" chatgpt-codex-connector)" \
  "$(fixture_comment "$pr_url#issuecomment-302" "$limit_body" "2026-11-16T01:28:14Z" "" chatgpt-codex-connector)" \
  "$(fixture_comment "$pr_url#issuecomment-303" $'TAKTのCI回復を停止しました。\n\n'"$limit_body" "2026-11-16T02:46:31Z" "" alice)" \
  "$(fixture_comment "$pr_url#issuecomment-304" "Codex の「$limit_body」を確認しました。次回のレビューを待ちます。" "2026-11-16T02:49:20Z" "" alice)"
assert_conclusion "18b #131 quote acknowledgement passes" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-18b.json"

# 19. event-store-adapter-java#871 is green today and must stay green. The
# fixture keeps the decisive bodies and timestamps from the live PR; the long
# bot summaries are truncated after the markers that make them ignored.
assert_conclusion "19 event-store-adapter-java#871 stays green" 0 success \
  TEST_REPOSITORY="j5ik2o/event-store-adapter-java" \
  TEST_PR_NUMBER="871" \
  GH_PR_AUTHOR="j5ik2o" \
  GH_PR_AUTHOR_TYPE="User" \
  GH_PR_REPO="j5ik2o/event-store-adapter-java" \
  GH_PR_URL="https://github.com/j5ik2o/event-store-adapter-java/pull/871" \
  GH_COMMENTS_FILE="$root/tests/fixtures/review-thread-resolution-871-comments.json" \
  GH_REVIEWS_FILE="$root/tests/fixtures/review-thread-resolution-871-reviews.json"

# 20. ci_ref keeps v1 as the default and only the explicit v2 selects v2.
ci_ref_default="$(awk '
  /^      ci_ref:/ { found = 1; next }
  found && /^      [a-z_]+:/ { exit }
  found && /^        default:/ { print $2; exit }
' "$root/.github/workflows/review-thread-resolution.yml")"
if [[ "$ci_ref_default" == "v1" ]] \
  && grep -q 'ref: \${{ inputs.ci_ref }}' "$root/.github/workflows/review-thread-resolution.yml" \
  && grep -q 'GITHUB_ACTION_PATH/../../scripts/review-thread-resolution.sh' "$root/actions/review-thread-resolution/action.yml"; then
  printf 'ok - 20 ci_ref defaults to v1 and selects the checked-out ref\n'
else
  smoke_failures=$((smoke_failures + 1))
  printf 'not ok - 20 ci_ref defaults to v1 and selects the checked-out ref (default: %s)\n' "${ci_ref_default:-?}" >&2
fi

# 21. A Codex summary that only mentions "fixed" mid-sentence stays an item.
# A leading "Acknowledged." removes that comment from the items but does not
# acknowledge any other item (it has no reference).
write_fixture "$tmpdir/comments-21a.json" \
  "$(fixture_comment "$pr_url#issuecomment-131" "The first point is fixed, but the retry path is still broken." "2026-06-02T00:00:00Z" "" chatgpt-codex-connector)"
assert_conclusion "21a Codex summary with mid-sentence fixed stays an item" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-21a.json"
write_fixture "$tmpdir/comments-21b.json" \
  "$(fixture_comment "$pr_url#issuecomment-132" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-232" "Acknowledged." "2026-06-02T00:10:00Z" "" chatgpt-codex-connector)"
assert_conclusion "21b Codex Acknowledged does not approve other items" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-21b.json"

# 22. A Codex summary that starts with Fixed / 確認済み stays an item (the
# trusted words stay the narrow v1 list). Those words only acknowledge when
# the author writes them.
write_fixture "$tmpdir/comments-22a.json" \
  "$(fixture_comment "$pr_url#issuecomment-133" "Fixed the first point, but the retry path is still broken." "2026-06-02T00:00:00Z" "" chatgpt-codex-connector)"
assert_conclusion "22a Codex summary starting with Fixed stays an item" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-22a.json"
write_fixture "$tmpdir/comments-22b.json" \
  "$(fixture_comment "$pr_url#issuecomment-134" "確認済みです。ただし、再試行の経路はまだ壊れています。" "2026-06-02T00:00:00Z" "" chatgpt-codex-connector)"
assert_conclusion "22b Codex summary starting with 確認済み stays an item" 1 failure \
  GH_COMMENTS_FILE="$tmpdir/comments-22b.json"
write_fixture "$tmpdir/comments-22c.json" \
  "$(fixture_comment "$pr_url#issuecomment-135" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-235" "Fixed. $item_quote" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "22c author Fixed acknowledges" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-22c.json"
write_fixture "$tmpdir/comments-22d.json" \
  "$(fixture_comment "$pr_url#issuecomment-136" "$item_body" "2026-06-02T00:00:00Z" "" reviewer-bot)" \
  "$(fixture_comment "$pr_url#issuecomment-236" "確認済みです。$item_quote" "2026-06-02T00:10:00Z" "" alice)"
assert_conclusion "22d author 確認済み acknowledges" 0 success \
  GH_COMMENTS_FILE="$tmpdir/comments-22d.json"

if [[ "$smoke_failures" -gt 0 ]]; then
  echo "$smoke_failures issue #134 smoke expectation(s) failed." >&2
  exit 1
fi

echo "review-thread-resolution smoke tests passed."
