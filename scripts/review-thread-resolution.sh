set -euo pipefail

REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
BASE_BRANCH="${BASE_BRANCH:-main}"
REQUIRED_CONTEXT="${REQUIRED_CONTEXT:-Check unresolved comments}"
# The refresh never waits for other checks; it evaluates the current state and
# publishes a conclusion. The input name stays for compatibility and now picks
# the mode: true (default) is an event refresh whose job succeeds even with
# unresolved review state, false is a CI gate whose job fails on it.
WAIT_FOR_OTHER_CHECKS="${WAIT_FOR_OTHER_CHECKS:-1}"
PUBLISH_STATUS="${PUBLISH_STATUS:-1}"
SKIP_STATUS_FOR_DEPENDABOT="${SKIP_STATUS_FOR_DEPENDABOT:-1}"
EVENT_NAME="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
PR_NUMBER="${PR_NUMBER:-}"
RUN_URL="${RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}}"
DEFAULT_IGNORED_AUTO_REPORT_PATTERNS=$'<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\n<!-- This is an auto-generated comment by CodeRabbit for review status -->\n<!-- walkthrough_start -->\n<!-- pre_merge_checks_walkthrough_start -->\n<!-- BUGBOT_REVIEW -->\n<!-- devin-review-badge-begin -->'
DEFAULT_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS=$'coderabbitai\t## Review limit reached\ncoderabbitai\t## Walkthrough\nrenovate\t### Edited Notification\nrenovate\t### Blocked Notification\nrenovate\t### Edited/Blocked Notification\ncodecov\t## [Codecov](\nchatgpt-codex-connector\tCodex Review'
IGNORED_AUTO_REPORT_PATTERNS="${IGNORED_AUTO_REPORT_PATTERNS:-$DEFAULT_IGNORED_AUTO_REPORT_PATTERNS}"
EXTRA_IGNORED_AUTO_REPORT_PATTERNS="${EXTRA_IGNORED_AUTO_REPORT_PATTERNS:-}"
if [[ -n "$EXTRA_IGNORED_AUTO_REPORT_PATTERNS" ]]; then
  IGNORED_AUTO_REPORT_PATTERNS="${IGNORED_AUTO_REPORT_PATTERNS}"$'\n'"${EXTRA_IGNORED_AUTO_REPORT_PATTERNS}"
fi
IGNORED_AUTO_REPORT_AUTHOR_PATTERNS="${IGNORED_AUTO_REPORT_AUTHOR_PATTERNS:-$DEFAULT_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS}"
EXTRA_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS="${EXTRA_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS:-}"
if [[ -n "$EXTRA_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS" ]]; then
  IGNORED_AUTO_REPORT_AUTHOR_PATTERNS="${IGNORED_AUTO_REPORT_AUTHOR_PATTERNS}"$'\n'"${EXTRA_IGNORED_AUTO_REPORT_AUTHOR_PATTERNS}"
fi

case "$WAIT_FOR_OTHER_CHECKS" in
  false|False|FALSE) WAIT_FOR_OTHER_CHECKS=0 ;;
  *) WAIT_FOR_OTHER_CHECKS=1 ;;
esac
case "$PUBLISH_STATUS" in
  false|False|FALSE) PUBLISH_STATUS=0 ;;
  *) PUBLISH_STATUS=1 ;;
esac
case "$SKIP_STATUS_FOR_DEPENDABOT" in
  false|False|FALSE) SKIP_STATUS_FOR_DEPENDABOT=0 ;;
  *) SKIP_STATUS_FOR_DEPENDABOT=1 ;;
esac

if [[ -z "$REPOSITORY" || "$REPOSITORY" != */* ]]; then
  echo "::error::REPOSITORY must be in owner/name form."
  exit 1
fi

OWNER="${REPOSITORY%%/*}"
REPO="${REPOSITORY#*/}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "::error::Required command not found: $1"
    exit 1
  fi
}

require_command gh
require_command jq

bool_is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_pr_number() {
  local explicit_pr_number="${PR_NUMBER:-}"

  if [[ -n "$explicit_pr_number" && "$explicit_pr_number" != "null" ]]; then
    printf '%s\n' "$explicit_pr_number"
    return 0
  fi

  if [[ -z "${GITHUB_EVENT_PATH:-}" || ! -f "$GITHUB_EVENT_PATH" ]]; then
    printf '\n'
    return 0
  fi

  jq -r '
    def url_number($url):
      ($url // "" | split("/")[-1]);
    if (.pull_request.number? // null) != null then
      (.pull_request.number | tostring)
    elif (.issue.pull_request? // null) != null and (.issue.number? // null) != null then
      (.issue.number | tostring)
    elif ((.review.pull_request_url? // "") | length) > 0 then
      url_number(.review.pull_request_url)
    elif ((.comment.pull_request_url? // "") | length) > 0 then
      url_number(.comment.pull_request_url)
    elif (.workflow_run.pull_requests[0].number? // null) != null then
      (.workflow_run.pull_requests[0].number | tostring)
    else
      ""
    end
  ' "$GITHUB_EVENT_PATH"
}

event_is_non_pr_issue_comment() {
  [[ "$EVENT_NAME" == "issue_comment" ]] || return 1
  [[ -n "${GITHUB_EVENT_PATH:-}" && -f "$GITHUB_EVENT_PATH" ]] || return 1
  jq -e '(.issue.pull_request? // null) == null' "$GITHUB_EVENT_PATH" >/dev/null
}

fetch_pr_metadata() {
  local pr_number="$1"

  gh api graphql \
    -F owner="$OWNER" \
    -F name="$REPO" \
    -F number="$pr_number" \
    -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            author {
              __typename
              login
            }
            baseRefName
            headRepository {
              nameWithOwner
            }
            headRefOid
            url
          }
        }
      }
    '
}

fetch_pr_head_oid() {
  local pr_number="$1"

  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "repos/$OWNER/$REPO/pulls/$pr_number" \
    --jq '.head.sha // ""'
}

publish_status() {
  local head_ref_oid="$1"
  local state="$2"
  local description="${3:-Review-thread gate ${2}.}"
  local payload
  local response
  local error_file

  if ! bool_is_true "$PUBLISH_STATUS"; then
    return 0
  fi

  payload="$(
    jq -n \
      --arg state "$state" \
      --arg target_url "$RUN_URL" \
      --arg description "$description" \
      --arg context "$REQUIRED_CONTEXT" \
      '{
        state: $state,
        target_url: $target_url,
        description: $description,
        context: $context
      }'
  )"

  error_file="$(mktemp)"
  trap 'rm -f "$error_file"; trap - RETURN' RETURN
  if ! response="$(
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "repos/$OWNER/$REPO/statuses/$head_ref_oid" \
      --input - \
      2> "$error_file" <<< "$payload"
  )"; then
    echo "::error::Failed to publish commit status via GitHub API."
    cat "$error_file" >&2
    return 1
  fi

  if [[ -s "$error_file" ]]; then
    cat "$error_file" >&2
  fi

  if jq -e '(.errors? // []) | length > 0' <<< "$response" >/dev/null; then
    echo "::error::GitHub API returned errors while publishing commit status."
    jq -r '.errors[]?.message // empty' <<< "$response" >&2
    return 1
  fi

  if jq -e '.message? // empty' <<< "$response" >/dev/null; then
    echo "::error::GitHub API returned an error message while publishing commit status."
    jq -r '.message' <<< "$response" >&2
    return 1
  fi

  echo "Published commit status '$state' for $head_ref_oid."
}

# Prints the cursor of the next page of a pullRequest connection, or nothing on
# the last page. Fails when pageInfo is malformed or the response is empty, so
# a truncated response never ends the fetch early.
next_page_cursor() {
  jq -er --arg connection "$2" '
    .data.repository.pullRequest[$connection].pageInfo as $info
    | if ($info.hasNextPage | type) != "boolean" then error("hasNextPage is not a boolean")
      elif $info.hasNextPage then ($info.endCursor | strings | select(length > 0)) // error("endCursor is missing")
      else "" end
  ' <<< "$1"
}

fetch_unresolved_threads() {
  local pr_number="$1"
  local pages_file
  local cursor=''
  local page=1
  local response
  local cursor_args

  pages_file="$(mktemp)"
  trap 'rm -f "$pages_file"; trap - RETURN' RETURN

  while :; do
    cursor_args=()
    if [[ -n "$cursor" ]]; then
      cursor_args=(-F cursor="$cursor")
    fi

    response="$(
      gh api graphql \
        -F owner="$OWNER" \
        -F name="$REPO" \
        -F number="$pr_number" \
        "${cursor_args[@]}" \
        -f query='
          query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
            repository(owner: $owner, name: $name) {
              pullRequest(number: $number) {
                reviewThreads(first: 100, after: $cursor) {
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                  nodes {
                    isResolved
                    path
                    line
                    comments(first: 1) {
                      nodes {
                        url
                        author {
                          login
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        '
    )" || return 1

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching PR review threads on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    if ! jq -ce '(.data.repository.pullRequest.reviewThreads.nodes | arrays)
      // error("response has no reviewThreads.nodes")
      | map(select(.isResolved == false))' <<< "$response" >> "$pages_file"; then
      echo "::error::Unexpected GitHub GraphQL response while fetching PR review threads on page $page."
      return 1
    fi

    if ! cursor="$(next_page_cursor "$response" reviewThreads)"; then
      echo "::error::Unexpected GitHub GraphQL page info while fetching PR review threads on page $page."
      return 1
    fi
    if [[ -z "$cursor" ]]; then
      break
    fi
    page=$((page + 1))
  done

  jq -c -s 'add // []' "$pages_file" || return 1
}

fetch_top_level_comments() {
  local pr_number="$1"
  local pages_file
  local cursor=''
  local page=1
  local response
  local cursor_args

  pages_file="$(mktemp)"
  trap 'rm -f "$pages_file"; trap - RETURN' RETURN

  while :; do
    cursor_args=()
    if [[ -n "$cursor" ]]; then
      cursor_args=(-F cursor="$cursor")
    fi

    response="$(
      gh api graphql \
        -F owner="$OWNER" \
        -F name="$REPO" \
        -F number="$pr_number" \
        "${cursor_args[@]}" \
        -f query='
          query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
            repository(owner: $owner, name: $name) {
              pullRequest(number: $number) {
                comments(first: 100, after: $cursor) {
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                  nodes {
                    url
                    body
                    createdAt
                    updatedAt
                    authorAssociation
                    author {
                      login
                    }
                  }
                }
              }
            }
          }
        '
    )" || return 1

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching top-level PR comments on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    if ! jq -ce '(.data.repository.pullRequest.comments.nodes | arrays)
      // error("response has no comments.nodes")' <<< "$response" >> "$pages_file"; then
      echo "::error::Unexpected GitHub GraphQL response while fetching top-level PR comments on page $page."
      return 1
    fi

    if ! cursor="$(next_page_cursor "$response" comments)"; then
      echo "::error::Unexpected GitHub GraphQL page info while fetching top-level PR comments on page $page."
      return 1
    fi
    if [[ -z "$cursor" ]]; then
      break
    fi
    page=$((page + 1))
  done

  cursor=''
  page=1
  while :; do
    cursor_args=()
    if [[ -n "$cursor" ]]; then
      cursor_args=(-F cursor="$cursor")
    fi

    response="$(
      gh api graphql \
        -F owner="$OWNER" \
        -F name="$REPO" \
        -F number="$pr_number" \
        "${cursor_args[@]}" \
        -f query='
          query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
            repository(owner: $owner, name: $name) {
              pullRequest(number: $number) {
                reviews(first: 100, after: $cursor) {
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                  nodes {
                    url
                    body
                    state
                    submittedAt
                    updatedAt
                    authorAssociation
                    author {
                      login
                    }
                  }
                }
              }
            }
          }
        '
    )" || return 1

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching PR reviews on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    if ! jq -ce '(.data.repository.pullRequest.reviews.nodes | arrays)
        // error("response has no reviews.nodes")
        | map(select((.body // "") != "" and (.state == "COMMENTED" or .state == "CHANGES_REQUESTED")))
        | map({
            url,
            body,
            state,
            createdAt: .submittedAt,
            updatedAt: (.updatedAt // .submittedAt),
            authorAssociation,
            author
          })' <<< "$response" >> "$pages_file"; then
      echo "::error::Unexpected GitHub GraphQL response while fetching PR reviews on page $page."
      return 1
    fi

    if ! cursor="$(next_page_cursor "$response" reviews)"; then
      echo "::error::Unexpected GitHub GraphQL page info while fetching PR reviews on page $page."
      return 1
    fi
    if [[ -z "$cursor" ]]; then
      break
    fi
    page=$((page + 1))
  done

  jq -c -s 'add // []' "$pages_file" || return 1
}

filter_unacknowledged_comments() {
  local comments="$1"
  local pr_author="$2"
  local pr_author_type="$3"

  jq -c \
    --arg pr_author "$pr_author" \
    --arg pr_author_type "$pr_author_type" \
    --arg ignored_auto_report_patterns "$IGNORED_AUTO_REPORT_PATTERNS" \
    --arg ignored_auto_report_author_patterns "$IGNORED_AUTO_REPORT_AUTHOR_PATTERNS" '
    def report_author_login:
      (.author.login // "") | sub("\\[bot\\]$"; "");
    def ignored_auto_report_pattern_list:
      $ignored_auto_report_patterns
      | split("\n")
      | map(select(length > 0));
    def ignored_auto_report_author_pattern_list:
      $ignored_auto_report_author_patterns
      | split("\n")
      | map(select(length > 0))
      | map(split("\t") as $parts | select($parts | length >= 2) | {
          author: $parts[0],
          pattern: ($parts[1:] | join("\t"))
        });
    def body_matches_ignored_auto_report_pattern($body):
      any(ignored_auto_report_pattern_list[]; . as $pattern | $body | contains($pattern));
    def body_matches_ignored_auto_report_author_pattern($author; $body):
      any(ignored_auto_report_author_pattern_list[]; . as $entry | $entry.author == $author and ($body | contains($entry.pattern)));
    def ignored_auto_report:
      report_author_login as $author
      | (.body // "") as $body
      | body_matches_ignored_auto_report_pattern($body)
        or body_matches_ignored_auto_report_author_pattern($author; $body);
    def trusted_acknowledgement:
      (report_author_login == "chatgpt-codex-connector")
      and ((.body // "") | test("(?i)^\\s*(acknowledged|addressed|確認しました|承知しました|了解しました|対応済み|対応しました|対処しました)"));
    . as $comments
    | [
        $comments[]
        | select(
            (ignored_auto_report | not)
            and (trusted_acknowledgement | not)
            and ((.author.login // "") != $pr_author)
            and (
              $pr_author_type != "Bot"
              or (
                .authorAssociation != "OWNER"
                and .authorAssociation != "MEMBER"
                and .authorAssociation != "COLLABORATOR"
              )
            )
          )
        | . as $comment
        | select([
            $comments[]
            | select(
                (.author.login // "") == $pr_author
                or trusted_acknowledgement
                or (
                  $pr_author_type == "Bot"
                  and (
                    .authorAssociation == "OWNER"
                    or .authorAssociation == "MEMBER"
                    or .authorAssociation == "COLLABORATOR"
                  )
                )
              )
            | select(.createdAt > ($comment.updatedAt // $comment.createdAt))
          ] | length == 0)
      ]
  ' <<< "$comments"
}

build_summary() {
  local unresolved_count="$1"
  local unacknowledged_count="$2"
  local unresolved="$3"
  local unacknowledged="$4"
  local pr_url="$5"

  {
    echo "PR: $pr_url"
    echo
    echo "$unresolved_count unresolved PR review thread(s) and $unacknowledged_count unacknowledged top-level PR comment(s) or review summary comment(s) remain."
    echo
    if [[ "$unresolved_count" -gt 0 ]]; then
      echo "### Unresolved PR review threads"
      echo
      jq -r '.[] | "- \(.path):\(.line // "n/a") by \(.comments.nodes[0]?.author.login // "unknown"): \(.comments.nodes[0]?.url // "no comment URL")"' <<< "$unresolved"
      echo
    fi
    if [[ "$unacknowledged_count" -gt 0 ]]; then
      echo "### Unacknowledged top-level PR comments or review summaries"
      echo
      jq -r '.[] | "- by \(.author.login // "unknown") updated at \((.updatedAt // .createdAt)): \(.url // "no comment URL")"' <<< "$unacknowledged"
    fi
  }
}

# Evaluates one PR. When the evaluation fails after the head SHA is known, it
# publishes error so an earlier success on the same head does not stay.
check_pr() {
  local result=0

  ERROR_STATUS_SHA=""
  evaluate_pr "$1" || result=$?
  if [[ "$result" -eq 1 && -n "$ERROR_STATUS_SHA" ]]; then
    publish_status "$ERROR_STATUS_SHA" error "Review-thread evaluation failed; see the workflow run." || true
  fi
  return "$result"
}

evaluate_pr() {
  local pr_number="$1"
  local pr_response
  local pr_author
  local pr_author_type
  local base_ref
  local head_repository
  local head_ref_oid
  local latest_head_ref_oid
  local pr_url
  local unresolved
  local unresolved_count
  local top_level_comments
  local unacknowledged
  local unacknowledged_count
  local summary
  local can_publish_status=1

  if [[ -z "$pr_number" || ! "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "::error::PR number must be numeric: $pr_number"
    return 1
  fi

  pr_response="$(fetch_pr_metadata "$pr_number")" || return 1
  if jq -e '.errors? | length > 0' <<< "$pr_response" >/dev/null; then
    echo "::error::GitHub GraphQL returned errors while fetching PR #$pr_number metadata."
    jq -r '.errors[]?.message' <<< "$pr_response" >&2
    return 1
  fi

  if ! jq -e '.data.repository.pullRequest.author.login
    and .data.repository.pullRequest.baseRefName
    and .data.repository.pullRequest.headRefOid
    and .data.repository.pullRequest.url' <<< "$pr_response" >/dev/null; then
    echo "::error::GitHub GraphQL response did not include PR #$pr_number metadata."
    jq -c '.' <<< "$pr_response" >&2
    return 1
  fi

  pr_author="$(jq -r '.data.repository.pullRequest.author.login' <<< "$pr_response")"
  pr_author_type="$(jq -r '.data.repository.pullRequest.author.__typename' <<< "$pr_response")"
  base_ref="$(jq -r '.data.repository.pullRequest.baseRefName' <<< "$pr_response")"
  head_repository="$(jq -r '.data.repository.pullRequest.headRepository.nameWithOwner // ""' <<< "$pr_response")"
  head_ref_oid="$(jq -r '.data.repository.pullRequest.headRefOid' <<< "$pr_response")"
  pr_url="$(jq -r '.data.repository.pullRequest.url' <<< "$pr_response")"

  if [[ "$base_ref" != "$BASE_BRANCH" ]]; then
    echo "Skipping PR #$pr_number because base branch is $base_ref, not $BASE_BRANCH."
    return 0
  fi

  if [[ "$head_repository" != "$OWNER/$REPO" ]]; then
    echo "::notice::Skipping synthetic commit status for fork PR head ($head_repository)."
    can_publish_status=0
  elif bool_is_true "$SKIP_STATUS_FOR_DEPENDABOT" && [[ "$pr_author" == "dependabot[bot]" || "$pr_author" == "dependabot" ]]; then
    echo "::notice::Skipping synthetic commit status for Dependabot PR author ($pr_author)."
    can_publish_status=0
  fi
  if [[ "$can_publish_status" -eq 1 ]]; then
    ERROR_STATUS_SHA="$head_ref_oid"
  fi

  latest_head_ref_oid="$(fetch_pr_head_oid "$pr_number")" || return 1
  if [[ -z "$latest_head_ref_oid" || "$latest_head_ref_oid" == "null" ]]; then
    echo "::error::Failed to refresh PR #$pr_number head SHA before publishing status."
    return 1
  fi
  if [[ "$latest_head_ref_oid" != "$head_ref_oid" ]]; then
    echo "::notice::PR #$pr_number head changed from $head_ref_oid to $latest_head_ref_oid; evaluating latest head."
    head_ref_oid="$latest_head_ref_oid"
    if [[ "$can_publish_status" -eq 1 ]]; then
      ERROR_STATUS_SHA="$head_ref_oid"
    fi
  fi

  unresolved="$(fetch_unresolved_threads "$pr_number")" || return 1
  unresolved_count="$(jq 'length' <<< "$unresolved")" || return 1
  if [[ "$unresolved_count" -eq 0 ]]; then
    echo "No unresolved PR review threads for PR #$pr_number."
  fi

  top_level_comments="$(fetch_top_level_comments "$pr_number")" || return 1
  unacknowledged="$(filter_unacknowledged_comments "$top_level_comments" "$pr_author" "$pr_author_type")" || return 1
  unacknowledged_count="$(jq 'length' <<< "$unacknowledged")" || return 1
  if [[ ! "$unresolved_count" =~ ^[0-9]+$ || ! "$unacknowledged_count" =~ ^[0-9]+$ ]]; then
    echo "::error::Review-thread counts are not numbers (threads: '$unresolved_count', comments: '$unacknowledged_count')."
    return 1
  fi
  if [[ "$unacknowledged_count" -eq 0 ]]; then
    echo "No unacknowledged top-level PR comments or review summaries for PR #$pr_number."
  fi

  summary="$(build_summary "$unresolved_count" "$unacknowledged_count" "$unresolved" "$unacknowledged" "$pr_url")"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$summary" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$summary"
  fi

  if [[ "$unresolved_count" -eq 0 && "$unacknowledged_count" -eq 0 ]]; then
    if [[ "$can_publish_status" -eq 1 ]]; then
      publish_status "$head_ref_oid" success || return 1
    fi
    return 0
  fi

  if [[ "$can_publish_status" -eq 1 ]]; then
    publish_status "$head_ref_oid" failure || return 1
  fi
  echo "::error::$unresolved_count unresolved PR review thread(s) and $unacknowledged_count unacknowledged top-level PR comment(s) or review summary comment(s) remain on PR #$pr_number."
  return 2
}

run_refresh_all() {
  local pr_number
  local pr_numbers=()
  local overall=0
  local result

  mapfile -t pr_numbers < <(list_open_prs)
  if [[ "${#pr_numbers[@]}" -eq 0 ]]; then
    echo "No open PRs targeting $BASE_BRANCH."
    return 0
  fi

  for pr_number in "${pr_numbers[@]}"; do
    set +e
    check_pr "$pr_number"
    result=$?
    set -e
    if [[ "$result" -eq 1 ]]; then
      overall=1
    elif [[ "$result" -eq 2 ]]; then
      echo "::notice::PR #$pr_number still has unresolved review state; keeping this refresh-all workflow successful."
    elif [[ "$result" -ne 0 ]]; then
      echo "::error::Unexpected result while refreshing PR #$pr_number: $result"
      overall=1
    fi
  done

  return "$overall"
}

run_single_pr() {
  local result

  set +e
  check_pr "$PR_NUMBER"
  result=$?
  set -e

  if [[ "$result" -eq 2 ]]; then
    if bool_is_true "$WAIT_FOR_OTHER_CHECKS"; then
      echo "::notice::PR #$PR_NUMBER still has unresolved review state; published '$REQUIRED_CONTEXT' and keeping this refresh workflow successful."
      return 0
    fi
    return 1
  fi
  return "$result"
}

ERROR_STATUS_SHA=""

main() {
  PR_NUMBER="$(resolve_pr_number)"

  if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
    if [[ "$EVENT_NAME" == "schedule" || "$EVENT_NAME" == "workflow_dispatch" ]]; then
      run_refresh_all
      return $?
    fi
    if event_is_non_pr_issue_comment; then
      echo "Skipping non-PR issue_comment event."
      return 0
    fi
    if [[ "$EVENT_NAME" == "workflow_run" ]]; then
      echo "Skipping workflow_run event without a same-repository PR."
      return 0
    fi
    echo "::error::Unable to resolve PR number from $EVENT_NAME event."
    return 1
  fi

  if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "::error::PR number must be numeric: $PR_NUMBER"
    return 1
  fi

  run_single_pr
}

list_open_prs() {
  gh pr list \
    --repo "$OWNER/$REPO" \
    --base "$BASE_BRANCH" \
    --state open \
    --limit 1000 \
    --json number \
    --jq '.[].number'
}

main "$@"
