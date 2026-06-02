set -euo pipefail

REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
BASE_BRANCH="${BASE_BRANCH:-main}"
REQUIRED_CONTEXT="${REQUIRED_CONTEXT:-Check unresolved comments}"
WAIT_FOR_OTHER_CHECKS="${WAIT_FOR_OTHER_CHECKS:-1}"
PUBLISH_STATUS="${PUBLISH_STATUS:-1}"
SKIP_STATUS_FOR_DEPENDABOT="${SKIP_STATUS_FOR_DEPENDABOT:-1}"
EVENT_NAME="${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
PR_NUMBER="${PR_NUMBER:-}"
RUN_URL="${RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}}"

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

wait_for_checks() {
  local pr_number="$1"
  local head_ref_oid="$2"
  local max_attempts
  local sleep_seconds=5
  local max_sleep_seconds=30
  local attempt=0
  local status_response
  local current_head_ref_oid
  local pending_checks

  if ! bool_is_true "$WAIT_FOR_OTHER_CHECKS"; then
    echo "Skipping other-check wait because wait_for_other_checks=false."
    return 0
  fi

  if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
    max_attempts=3
  else
    max_attempts=60
  fi

  while [[ "$attempt" -lt "$max_attempts" ]]; do
    attempt=$((attempt + 1))
    status_response="$(gh pr view "$pr_number" --repo "$OWNER/$REPO" --json headRefOid,statusCheckRollup)" || {
      if [[ "$attempt" -eq "$max_attempts" ]]; then
        echo "::error::Failed to fetch PR status after $max_attempts attempts."
        return 1
      fi
      echo "::warning::Failed to fetch PR status on attempt $attempt; retrying."
      sleep "$sleep_seconds"
      if [[ "$sleep_seconds" -lt "$max_sleep_seconds" ]]; then
        sleep_seconds=$((sleep_seconds * 2))
        if [[ "$sleep_seconds" -gt "$max_sleep_seconds" ]]; then
          sleep_seconds="$max_sleep_seconds"
        fi
      fi
      continue
    }

    current_head_ref_oid="$(jq -r '.headRefOid' <<< "$status_response")"
    if [[ "$current_head_ref_oid" != "$head_ref_oid" ]]; then
      if [[ "$EVENT_NAME" == "workflow_dispatch" || "$EVENT_NAME" == "schedule" ]]; then
        echo "::notice::PR head changed from $head_ref_oid to $current_head_ref_oid while waiting for checks; continuing on the latest head."
        head_ref_oid="$current_head_ref_oid"
      else
        echo "::error::PR head changed from $head_ref_oid to $current_head_ref_oid while waiting for checks."
        return 1
      fi
    fi

    pending_checks="$(
      jq -r --arg required_context "$REQUIRED_CONTEXT" '
        .statusCheckRollup[]
        | select(
            if .__typename == "CheckRun" then
              (.name != $required_context
                and .workflowName != "Review Thread Resolution"
                and .workflowName != "Review Thread Refresh"
                and .workflowName != "CI Review Thread Gate"
                and (.status != "COMPLETED"))
            elif .__typename == "StatusContext" then
              (.context != $required_context
                and (.state == "PENDING" or .state == "EXPECTED"))
            else
              false
            end
          )
        | if .__typename == "CheckRun" then
            "\(.workflowName // "unknown") / \(.name // "unknown")"
          else
            "\(.context // "unknown")"
          end
      ' <<< "$status_response"
    )"

    if [[ -z "$pending_checks" ]]; then
      echo "All other PR checks have reached a terminal state."
      return 0
    fi

    if [[ "$attempt" -eq "$max_attempts" ]]; then
      if [[ "$EVENT_NAME" == "workflow_dispatch" || "$EVENT_NAME" == "schedule" ]]; then
        echo "::notice::Other PR checks are still pending; refreshing review-thread state without waiting."
        echo "$pending_checks"
        return 0
      fi
      echo "::error::Timed out waiting for other PR checks to finish before evaluating review comments."
      echo "$pending_checks" >&2
      return 1
    fi

    echo "Waiting for other PR checks to finish before evaluating review comments:"
    echo "$pending_checks"
    sleep "$sleep_seconds"
    if [[ "$sleep_seconds" -lt "$max_sleep_seconds" ]]; then
      sleep_seconds=$((sleep_seconds * 2))
      if [[ "$sleep_seconds" -gt "$max_sleep_seconds" ]]; then
        sleep_seconds="$max_sleep_seconds"
      fi
    fi
  done
}

publish_status() {
  local head_ref_oid="$1"
  local state="$2"
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
      --arg description "Review-thread gate ${state}." \
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

fetch_unresolved_threads() {
  local pr_number="$1"
  local unresolved='[]'
  local cursor=''
  local page=1
  local response
  local page_unresolved
  local has_next
  local cursor_args

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
    )"

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching PR review threads on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    page_unresolved="$(
      jq -c '.data.repository.pullRequest.reviewThreads.nodes
        | map(select(.isResolved == false))' <<< "$response"
    )"
    unresolved="$(jq -c -n --argjson current "$unresolved" --argjson page "$page_unresolved" '$current + $page')"

    has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<< "$response")"
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<< "$response")"
    page=$((page + 1))
  done

  printf '%s\n' "$unresolved"
}

fetch_top_level_comments() {
  local pr_number="$1"
  local comments='[]'
  local cursor=''
  local page=1
  local response
  local page_comments
  local has_next
  local cursor_args

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
    )"

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching top-level PR comments on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    page_comments="$(jq -c '.data.repository.pullRequest.comments.nodes' <<< "$response")"
    comments="$(jq -c -n --argjson current "$comments" --argjson page "$page_comments" '$current + $page')"

    has_next="$(jq -r '.data.repository.pullRequest.comments.pageInfo.hasNextPage' <<< "$response")"
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor="$(jq -r '.data.repository.pullRequest.comments.pageInfo.endCursor' <<< "$response")"
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
    )"

    if jq -e '.errors? | length > 0' <<< "$response" >/dev/null; then
      echo "::error::GitHub GraphQL returned errors while fetching PR reviews on page $page."
      jq -r '.errors[]?.message' <<< "$response" >&2
      return 1
    fi

    page_comments="$(
      jq -c '.data.repository.pullRequest.reviews.nodes
        | map(select((.body // "") != "" and (.state == "COMMENTED" or .state == "CHANGES_REQUESTED")))
        | map({
            url,
            body,
            state,
            createdAt: .submittedAt,
            updatedAt: (.updatedAt // .submittedAt),
            authorAssociation,
            author
          })' <<< "$response"
    )"
    comments="$(jq -c -n --argjson current "$comments" --argjson page "$page_comments" '$current + $page')"

    has_next="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' <<< "$response")"
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor="$(jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor' <<< "$response")"
    page=$((page + 1))
  done

  printf '%s\n' "$comments"
}

filter_unacknowledged_comments() {
  local comments="$1"
  local pr_author="$2"
  local pr_author_type="$3"

  jq -c --arg pr_author "$pr_author" --arg pr_author_type "$pr_author_type" '
    def report_author_login:
      (.author.login // "") | sub("\\[bot\\]$"; "");
    def ignored_auto_report:
      report_author_login as $author
      | (.body // "") as $body
      | (
          $author == "coderabbitai"
          and (
            ($body | contains("<!-- This is an auto-generated comment: summarize by coderabbit.ai -->"))
            or ($body | contains("<!-- This is an auto-generated comment by CodeRabbit for review status -->"))
            or ($body | contains("<!-- walkthrough_start -->"))
            or ($body | contains("<!-- pre_merge_checks_walkthrough_start -->"))
            or ($body | contains("## Review limit reached"))
            or ($body | contains("## Walkthrough"))
          )
        )
        or (
          $author == "renovate"
          and (
            ($body | contains("### Edited Notification"))
            or ($body | contains("### Blocked Notification"))
            or ($body | contains("### Edited/Blocked Notification"))
          )
        )
        or (
          $author == "codecov"
          and ($body | startswith("## [Codecov]("))
          and ($body | contains(" Report"))
        )
        or (
          $author == "cursor"
          and ($body | contains("<!-- BUGBOT_REVIEW -->"))
        )
        or (
          $author == "chatgpt-codex-connector"
          and ($body | contains("Codex Review"))
        );
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

check_pr() {
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

  wait_for_checks "$pr_number" "$head_ref_oid" || return 1

  latest_head_ref_oid="$(gh pr view "$pr_number" --repo "$OWNER/$REPO" --json headRefOid --jq '.headRefOid')" || return 1
  if [[ -z "$latest_head_ref_oid" || "$latest_head_ref_oid" == "null" ]]; then
    echo "::error::Failed to refresh PR #$pr_number head SHA before publishing status."
    return 1
  fi
  if [[ "$latest_head_ref_oid" != "$head_ref_oid" ]]; then
    echo "::notice::PR #$pr_number head changed from $head_ref_oid to $latest_head_ref_oid; evaluating latest head."
    head_ref_oid="$latest_head_ref_oid"
  fi

  unresolved="$(fetch_unresolved_threads "$pr_number")" || return 1
  unresolved_count="$(jq 'length' <<< "$unresolved")"
  if [[ "$unresolved_count" -eq 0 ]]; then
    echo "No unresolved PR review threads for PR #$pr_number."
  fi

  top_level_comments="$(fetch_top_level_comments "$pr_number")" || return 1
  unacknowledged="$(filter_unacknowledged_comments "$top_level_comments" "$pr_author" "$pr_author_type")" || return 1
  unacknowledged_count="$(jq 'length' <<< "$unacknowledged")"
  if [[ "$unacknowledged_count" -eq 0 ]]; then
    echo "No unacknowledged top-level PR comments or review summaries for PR #$pr_number."
  fi

  summary="$(build_summary "$unresolved_count" "$unacknowledged_count" "$unresolved" "$unacknowledged" "$pr_url")"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$summary" >> "$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$summary"
  fi

  if [[ "$head_repository" != "$OWNER/$REPO" ]]; then
    echo "::notice::Skipping synthetic commit status for fork PR head ($head_repository)."
    can_publish_status=0
  elif bool_is_true "$SKIP_STATUS_FOR_DEPENDABOT" && [[ "$pr_author" == "dependabot[bot]" || "$pr_author" == "dependabot" ]]; then
    echo "::notice::Skipping synthetic commit status for Dependabot PR author ($pr_author)."
    can_publish_status=0
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
  local original_wait_for_other_checks="$WAIT_FOR_OTHER_CHECKS"

  mapfile -t pr_numbers < <(list_open_prs)
  if [[ "${#pr_numbers[@]}" -eq 0 ]]; then
    echo "No open PRs targeting $BASE_BRANCH."
    return 0
  fi

  WAIT_FOR_OTHER_CHECKS=0
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
  WAIT_FOR_OTHER_CHECKS="$original_wait_for_other_checks"

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
