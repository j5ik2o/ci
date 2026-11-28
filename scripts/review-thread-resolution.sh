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

require_jq_17() {
  local v
  v="$(jq --version 2>/dev/null || true)"
  if [[ ! "$v" =~ ^jq-([0-9]+)\.([0-9]+) ]]; then
    echo "::error::jq の版を読めません（'${v}'）。jq 1.7 以上が要ります。" >&2
    return 1
  fi
  if (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 7) )); then
    echo "::error::jq ${v#jq-} では判定できません。jq 1.7 以上が要ります。" >&2
    return 1
  fi
}

filter_unacknowledged_comments() {
  local comments="$1"
  local pr_author="$2"
  local pr_author_type="$3"

  require_jq_17 || return 1

  jq -c \
    --arg pr_author "$pr_author" \
    --arg pr_author_type "$pr_author_type" \
    --arg ignored_auto_report_patterns "$IGNORED_AUTO_REPORT_PATTERNS" \
    --arg ignored_auto_report_author_patterns "$IGNORED_AUTO_REPORT_AUTHOR_PATTERNS" 'def ack_words:
  "確認しました|確認いたしました|確認済み|承知しました|了解しました|対応しました|対応いたしました|対応済み|対処しました|修正しました|直しました|\\backnowledged\\b|\\baddressed\\b|\\bfixed\\b";

# Codex の承知の語彙。v1 と同じ狭い一覧だけを使う（条件 4 の ack_words は使わない）。
# `Fixed`・`確認済み`・`修正しました`・`直しました`・`確認いたしました`・`対応いたしました` は
# 著者自身の確認（条件 4）でだけ承認に使う。
def trusted_ack_words:
  "acknowledged|addressed|確認しました|承知しました|了解しました|対応済み|対応しました|対処しました";

# コードフェンスの境界。確認の語・マーカー・フェンスだけの本文の判定が、この 1 つを共有する。
# CommonMark と同じく、行頭（空白 3 つまで）のバッククォートかチルダ 3 つ以上で開き、
# 同じ文字で、開きと同じ長さ以上の行で閉じる。閉じないフェンスは本文の終わりまで続く。
# 4 つのバッククォートで開いたフェンスは、中の 3 つのバッククォートの行では閉じない。
def fence_open($line):
  [ $line | match("^ {0,3}(`{3,}|~{3,})") ]
  | if length > 0 then .[0].captures[0].string else null end;

def fence_closes($line; $open):
  ($open[0:1]) as $c
  | $line | test("^ {0,3}" + (if $c == "`" then "`" else "~" end)
                 + "{" + ($open | length | tostring) + ",}\\s*$");

def fence_split:
  reduce ((.body // "") | split("\n"))[] as $line (
    { open: null, prose: [], fenced: 0 };
    if .open == null then
      fence_open($line) as $o
      | if $o == null then .prose += [$line] else .open = $o | .fenced += 1 end
    elif fence_closes($line; .open) then .open = null
    else . end);

# フェンスの外の散文だけ。
def strip_fences:
  fence_split | .prose | join("\n");

# 文頭一致。v1 の `^\s*(…)` と同じく、フェンスを外す前の本文の先頭で見る。
# 先頭のフェンス（ログなど）を外してから見ると、その後ろの `Acknowledged` が文頭扱いになり、
# 未修正の指摘が続く Codex の要約が項目から消えるため。語彙も v1 と同じ trusted_ack_words だけ。
def ack_at_start:
  (.body // "")
  | ascii_downcase
  | test("^\\s*(" + trusted_ack_words + ")");

# フェンスは残す（フェンス内の引用も照合の対象）。確認の語は norm_text を通さず、
# 単位と節（clauses）の masked で見る。
def norm_text($body):
  $body
  | gsub("(?s)<!--.*?-->"; " ")
  | split("\n")
  | map(gsub("^\\s*>\\s?"; ""))
  | map(gsub("<[^>]+>"; " "))
  | map(gsub("[*_`#>|]+"; " "))
  | map(gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; ""))
  | map(select(length > 0))
  | join("\n")
  | ascii_downcase;

def raw_body:
  (.body // "") | ascii_downcase;

# URL は id の照合にだけ使う。断片の照合の前に両方の本文から外す（ci#44）。
# 外さないと `https://github.com/j` のような URL の共通の頭が 20 文字の窓として当たる。
# scheme の無い `ホスト名/パス` は、最後のラベルがファイルの拡張子（`js`・`ts`・`json` など）なら外さない
# （`node.js/lib` を残す。3 回目の直し）。一覧に無い名前はホスト名として外す（外し過ぎは赤の側）。
# `rs`・`sh`・`md`・`py` は実在の国別ドメイン（`docs.rs`・`lib.rs`・`bun.sh`）、`java` は実在の gTLD なので一覧に入れない。
def file_ext_labels:
  "js|mjs|cjs|jsx|ts|tsx|json|ya?ml|toml|lock|txt|kts?|scala|sbt|qnt|html?|css|go";

def strip_urls($body):
  ($body // "")
  | gsub("(?i)https?://[^\\s)>\\]]+"; " ")
  | gsub("(?i)(?<pre>^|[^a-z0-9_./-])(?:[a-z0-9-]+\\.)+(?!(?:" + file_ext_labels + ")/)[a-z]{2,}/[^\\s)>\\]]*"; "\(.pre) ");

def quote_text($c):
  norm_text(strip_urls($c.body));

def windows($n):
  . as $s | [range(0; (($s | length) - $n + 1)) as $i | $s[$i:$i + $n]];

def anchor($u):
  ($u // "" | split("#") | if length > 1 then "#" + .[-1] else "" end);

# id の完全一致。直後に数字が続く一致は数えない（#issuecomment-10 は #issuecomment-101 に当たらない）。
# 位置（indices）を使わず、正規表現の先読みで決める（3 回目の直し）。jq 1.7 までの indices はバイト位置を返し、
# 日本語の後ろで「直後の 1 文字」を取り違えて偽の緑になる（「jq の版と、位置に頼らない判定」）。
def re_escape:
  gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\])"; "\\\(.c)");

def id_match($raw; $needle):
  $needle != ""
  and ($raw | test(($needle | re_escape) + "(?![0-9])"));

# ---- 確認の語の効く範囲・引用・否定（2026-11-28 の 2 回目の直し。ci#43 の残る穴 4 つ） ----

# 行の種別。フェンスの境界は fence_split と同じ規則（閉じないフェンスは終わりまで）。
# fence: フェンスの中（開き・閉じの行を含む。開きの行に start: true）
# quote: フェンスの外で、行頭（空白 3 つまで）が `>` の行
# blank / heading / item（リストの項目の頭）/ text
def line_kinds:
  reduce ((.body // "") | split("\n"))[] as $line (
    { open: null, out: [] };
    if .open == null then
      fence_open($line) as $o
      | if $o != null then .open = $o | .out += [{k: "fence", t: $line, start: true}]
        elif ($line | test("^\\s*$")) then .out += [{k: "blank", t: $line}]
        elif ($line | test("^ {0,3}>")) then .out += [{k: "quote", t: $line}]
        elif ($line | test("^ {0,3}#{1,6}(\\s|$)")) then .out += [{k: "heading", t: $line}]
        elif ($line | test("^\\s*([-*+]|[0-9]+[.)])\\s+")) then .out += [{k: "item", t: $line}]
        else .out += [{k: "text", t: $line}] end
    elif fence_closes($line; .open) then .open = null | .out += [{k: "fence", t: $line}]
    else .out += [{k: "fence", t: $line}] end)
  | .out;

# 単位の列。散文の単位（para・item・heading）と、引用・フェンスのかたまり（block）。
# gap: 直前に空行があるか。sec: 見出しで区切った節の番号（見出しの行から新しい節）。
def units:
  reduce line_kinds[] as $l (
    { us: [], gap: false, sec: 0 };
    (.us | length) as $n
    | (if $n > 0 then .us[$n - 1] else null end) as $last
    | (if $l.k == "heading" then .sec += 1 else . end)
    | if $l.k == "blank" then .gap = true
      elif $l.k == "text" and $last != null and (.gap | not)
           and ($last.type == "para" or $last.type == "item") then
        .us[$n - 1].text += "\n" + $l.t
      # 空行のあとでも、字下げ（空白 2 つ以上）した文の行はリストの項目の続き（GitHub の表示と同じ）。
      elif $l.k == "text" and $last != null and $last.type == "item" and ($l.t | test("^ {2,}\\S")) then
        .us[$n - 1].text += "\n" + $l.t | .gap = false
      elif $l.k == "quote" and $last != null and (.gap | not) and $last.type == "block" and $last.q then
        .us[$n - 1].text += "\n" + $l.t
      elif $l.k == "fence" and ($l.start | not) and $last != null and $last.type == "block" and ($last.q | not) then
        .us[$n - 1].text += "\n" + $l.t | .gap = false
      else
        .us += [{
          type: (if $l.k == "text" then "para" elif $l.k == "item" then "item"
                 elif $l.k == "heading" then "heading" else "block" end),
          q: ($l.k == "quote"),
          text: $l.t,
          gap: .gap,
          sec: .sec
        }]
        | .gap = false
      end)
  | .us;

# かたまりの付く先（散文の単位の位置）。探すのは同じ見出しの節の中だけ。
# 1. 空行を挟まずすぐ上にある散文の単位（すぐ上がかたまりなら、その付く先）
# 2. なければ、下にある最初の para か item
# 3. なければ、上にある最後の para か item
# 4. どれも無ければ null（どの単位にも付かない）
def attach_targets($us):
  reduce range(0; $us | length) as $j (
    [];
    . as $acc
    | if $us[$j].type != "block" then $acc + [null]
      elif $j > 0 and ($us[$j].gap | not)
           and ($us[$j - 1].type == "para" or $us[$j - 1].type == "item") then $acc + [$j - 1]
      elif $j > 0 and ($us[$j].gap | not) and $us[$j - 1].type == "block" and $acc[$j - 1] != null
           and $acc[$j - 1] < $j then $acc + [$acc[$j - 1]]
      else
        ([range($j + 1; $us | length)
          | select(($us[.].type == "para" or $us[.].type == "item") and $us[.].sec == $us[$j].sec)] | first) as $next
        | ([range(0; $j)
          | select(($us[.].type == "para" or $us[.].type == "item") and $us[.].sec == $us[$j].sec)] | last) as $prev
        | $acc + [($next // $prev)]
      end);

# リストの項目の前置き：項目の並び（間の空行とかたまりは許す）のすぐ上の para。
def lead_of($us; $j):
  [ range($j - 1; -1; -1) as $k | $us[$k] | {k: $k, type} ]
  | (map(select(.type != "item" and .type != "block")) | first) as $p
  | if $p != null and $p.type == "para" then $p.k else null end;

# 節に分ける。句点・感嘆符・疑問符・読点・セミコロン・改行と、空白か終わりが続くピリオドで切る。
# 「」『』“”（）() の中と、インラインのコードの中では切らない。
# raw: 照合に使う元の文字列。masked: 確認の語を探す文字列（「」『』“” の中身、インラインのコード、
# $cover が印を付けた項目の写しを空白にする）。
# インラインのコードは CommonMark と同じく、同じ長さのバッククォートの列で開いて閉じる
# （``fixed`` も 2 つの列で囲んだコード）。閉じる列が無い列は、ただの文字として扱う。
def backtick_runs($cs):
  ($cs | length) as $len
  | [ range(0; $len) as $i
      | select($cs[$i] == 96 and ($i == 0 or $cs[$i - 1] != 96))
      | { start: $i,
          len: (([ range($i; $len) as $k | select($cs[$k] != 96) | $k ] | first // $len) - $i) } ];

def clauses($cover):
  explode as $cs
  | ($cs | length) as $len
  | backtick_runs($cs) as $runs
  | ($runs | map({key: (.start | tostring), value: .len}) | from_entries) as $runat
  | reduce range(0; $len) as $i (
      { out: [], raw: [], masked: [], depth: 0, qdepth: 0, code: null };
      ($cs[$i]) as $c
      | ([$c] | implode) as $ch
      | (if $i + 1 < $len then ([$cs[$i + 1]] | implode) else "" end) as $nx
      | ($runat[$i | tostring]) as $run
      | if $run != null and .code == null
           and any($runs[]; .start > $i and .len == $run) then
          .code = $run | .raw += [$c] | .masked += [32]
        elif $run != null and .code == $run then .code = null | .raw += [$c] | .masked += [32]
        elif .code != null then .raw += [$c] | .masked += [32]
        elif $ch == "`" then .raw += [$c] | .masked += [32]
        else
          (if ($ch | test("^[「『“]$")) then .qdepth += 1 | .depth += 1
           elif ($ch | test("^[」』”]$")) then .qdepth = ([0, .qdepth - 1] | max) | .depth = ([0, .depth - 1] | max)
           elif ($ch | test("^[（(]$")) then .depth += 1
           elif ($ch | test("^[）)]$")) then .depth = ([0, .depth - 1] | max)
           else . end)
          | .raw += [$c]
          | .masked += [(if ($cover[$i] // false) or (.qdepth > 0 and ($ch | test("^[「『“」』”]$") | not)) then 32 else $c end)]
          | if .depth == 0
               and (($ch | test("^[。！？!?；;、，,\n]$"))
                    or ($ch == "." and ($nx == "" or ($nx | test("^\\s$"))))) then
              .out += [{raw: (.raw | implode), masked: (.masked | implode)}] | .raw = [] | .masked = []
            else . end
        end)
  | .out + (if (.raw | length) > 0 then [{raw: (.raw | implode), masked: (.masked | implode)}] else [] end)
  | map(select(.raw | test("\\S")));

def en_ack_words: "\\backnowledged\\b|\\baddressed\\b|\\bfixed\\b";

# 確認の語の打ち消し。$s は節の masked を小文字にしたもの、$m は語の一致。
def negated2($s; $m):
  ($s[0:$m.offset]) as $before
  | ($s[($m.offset + ($m.string | length)):]) as $after
  # 直前の否定（いまの規則のまま）
  | ($s[([0, ($m.offset - 12)] | max):$m.offset]
     | test("(未|まだ|未だに?|\\bnot\\b|\\bnot\\s+yet\\b|\\bun-?)[\\s*_~]*$"))
  # 英語：同じ節の前に否定・条件・未来の語（has not been fixed / hasn'\''t been fixed / once this is fixed）
  or (($m.string | test(en_ack_words))
      and ($before | test("\\b(not|never|cannot|no longer|unless|until|if|once|whether|will|going to)\\b|n['\''’]t\\b|['\''’]ll\\b")))
  # 日本語：後ろに付く否定（確認済みではありません / 対応済みでない / とは言えません）
  or ($after | test("^[\\s*_~]*((では|じゃ|で)は?\\s*(ありません|ない|なく|なかった)|とは(言え|いえ)(ません|ない))"))
  # 疑問（確認しましたか / 確認済みですか / Is it fixed?）
  or ($after | test("^[\\s*_~]*(です|でした|でしょう)?\\s*か(?!ら)"))
  or ($s | test("[?？]\\s*$"));

# まだの表明（確認の語が無くても、その節は「打ち消し」になる）。
def pending_cue:
  "未(対応|確認|修正|対処|解決|反映|着手|完了)|まだ|(て|で)い?(ません|ない|なかった)|でき(ません|ない)|(では|じゃ)(ありません|ない)|\\b(not|never|cannot|pending|todo|tbd)\\b|n['\''’]t\\b|\\bno longer\\b";

# 項目の本文を写した部分の印（$s は単位の本文を小文字にしたもの、$texts は項目の quote_text）。
# 20 文字の窓が項目のどれかの本文にあれば、その 20 文字を作成者の文ではないとみなす。
# 項目の文の `not`・`まだ`・`fixed` を、作成者の打ち消しや確認と読まないため。単位の全体で見てから節に分ける
# （節に分けてから見ると、読点で切れた 20 文字未満の断片を写しと認められない）。
def cover_flags($s; $texts):
  ($s | explode | length) as $len
  | (reduce range(0; ([0, $len - 19] | max)) as $i (
      [range(0; $len) | false];
      if (first($texts[] | select(contains($s[$i:$i + 20])) | 1) // null) != null then reduce range($i; $i + 20) as $k (.; .[$k] = true) else . end));

# まだの表明の一致。直後が `こと`・`の`・`と`・`旨` の一致は数えない（`エラーが出ていないことを確認しました` の
# `ていない` は、確認した内容であって、まだの表明ではない）。
def pending_hits($s):
  [ $s | match(pending_cue; "g")
    | select(($s[(.offset + (.string | length)):] | test("^\\s*(こと|の|と|旨)")) | not) ];

# 節の極性：pos（打ち消されない確認の語があり、打ち消しもまだの表明も無い）/
# neg（打ち消された語かまだの表明がある。打ち消されない語と同じ節にあっても neg）/ none。
# 同じ節に肯定と打ち消しが並ぶとき（`#10 is fixed and #11 is not fixed`）は、どの参照がどちらかを
# 決められないので、節の全体を打ち消しにして赤の側に倒す。
# 語・打ち消し・まだの表明は masked（引用・インラインのコード・項目の写しを空白にしたもの）で見る。
def polarity:
  (.masked | ascii_downcase) as $s
  | [ $s | match("(" + ack_words + ")"; "g") ] as $hits
  | ([ $hits[] | select(negated2($s; .) | not) ] | length) as $pos
  | (($hits | length) - $pos) as $negw
  | (pending_hits($s) | length) as $cue
  | if $negw > 0 or $cue > 0 then "neg"
    elif $pos > 0 then "pos"
    else "none" end;

# 節を切る前に、逆接の接続（`ましたが`・`ですが`・`けど`・`ものの`、英語の `but`・`however`・`although`・
# `whereas`）の位置に改行を入れる。読点の無い `#10 は確認しましたが #11 は未対応です` や
# `#10 is fixed but #11 is not fixed` を 2 つの節に分ける。参照の照合は元の本文で行う。
def split_contrast:
  gsub("(?<a>(ました|です|でした|ません)が|けれども|けれど|けど|ものの)(?![、，,])"; "\(.a)\n")
  | gsub("(?i)(?<a>[ \\t])(?<b>but|however|although|whereas)\\b"; "\(.a)\n\(.b)");

# 文字列 $t が指す項目の位置（$its の key）。id か、その項目だけが持つ 20 文字の断片。
# $excl は既定で外した通知の quote_text。通知は項目にならないが、「ほかの項目」には数える（3 回目の直し）。
# 外した通知と同じ文を持つ項目（通知を引用したレビューなど）を、通知の引用で承認しないため。
# 性能のための等価な書き換え：$texts（項目ごとの quote_text）は acked_keys で 1 回だけ計算して渡し、
# 窓の照合は first で最初に当たったところで打ち切る。
def has_other($texts; $excl; $k; $w):
  (($texts | length) as $n
   | (first(range(0; $n) | select(. != $k and ($texts[.] | contains($w))) | 1) // null) != null)
  or any($excl[]; contains($w));

def refs_in($t; $its; $texts; $excl):
  ($t | ascii_downcase) as $raw
  | (norm_text(strip_urls($t))) as $b
  | ($b | windows(20)) as $ws
  | [ range(0; $its | length) as $k
      | $its[$k] as $it
      | $texts[$k] as $tb
      | select(id_match($raw; (anchor($it.url) | ascii_downcase))
               or ((first($ws[] | . as $w | select(($tb | contains($w)) and (has_other($texts; $excl; $k; $w) | not)) | 1) // null) != null))
      | $k ];

# 打ち消しの節が触れている項目（id か、URL を外した 20 文字の窓が項目の本文にある。一意でなくてよい）。
def mentions_in($t; $its; $texts):
  ($t | ascii_downcase) as $raw
  | (norm_text(strip_urls($t)) | windows(20)) as $ws
  | [ range(0; $its | length) as $k
      | $its[$k] as $it
      | select(id_match($raw; (anchor($it.url) | ascii_downcase))
               or ((first($ws[] | . as $w | select($texts[$k] | contains($w)) | 1) // null) != null))
      | $k ];

# 確認 $a が承認する項目の位置の集合。
def acked_keys($its; $excl):
  . as $a
  | [ $its[] | quote_text(.) ] as $texts
  | units as $us
  | attach_targets($us) as $tg
  | [ range(0; $us | length) as $j
      | select($us[$j].type != "block")
      | ($us[$j].text | split_contrast) as $st
      | ($st | clauses(cover_flags($st | ascii_downcase; $texts)) | map(. + {pol: polarity})) as $cl
      | { j: $j, type: $us[$j].type, cl: $cl,
          pol: (if any($cl[]; .pol == "pos") and any($cl[]; .pol == "neg") then "mixed"
                elif any($cl[]; .pol == "pos") then "pos"
                elif any($cl[]; .pol == "neg") then "neg" else "none" end),
          blocks: [ range(0; $us | length) as $b | select($tg[$b] == $j) | $us[$b].text ] } ] as $segs
  | ($segs | map({key: (.j | tostring), value: .pol}) | from_entries) as $polof
  # 拒否：打ち消しの節が触れた項目と、打ち消しの節を含む単位（neg・mixed）に付いたかたまりが触れた項目。
  | ([ ($segs[] | .cl[] | select(.pol == "neg") | mentions_in(.raw; $its; $texts)[]),
       ($segs[] | select(.pol == "neg" or .pol == "mixed") | .blocks[] | mentions_in(.; $its; $texts)[]) ] | unique) as $veto
  | [ $segs[]
      | if .pol == "pos" then refs_in(([$us[.j].text] + .blocks) | join("\n"); $its; $texts; $excl)[]
        elif .pol == "mixed" then (.cl[] | select(.pol == "pos") | refs_in(.raw; $its; $texts; $excl)[])
        elif .pol == "none" and .type == "item" then
          lead_of($us; .j) as $l
          | if $l != null and $polof[$l | tostring] == "pos"
            then refs_in(([$us[.j].text] + .blocks) | join("\n"); $its; $texts; $excl)[] else empty end
        else empty end ]
  | unique
  | map(select(. as $k | $veto | index($k) | not));

def report_author_login:
  (.author.login // "") | sub("\\[bot\\]$"; "");

def is_author:
  (.author.login // "") == ($pr_author // "");

# 既存の ignored_auto_report（著者＋本文パターン）。v1 のまま使う。
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

def ignored_auto_report:
  report_author_login as $author
  | (.body // "") as $body
  | any(ignored_auto_report_pattern_list[]; . as $p | $body | contains($p))
    or any(ignored_auto_report_author_pattern_list[];
           . as $e | $e.author == $author and ($body | contains($e.pattern)));

# 既定で外す自動の通知（3 回目の直し。元帥の決め 2026-11-28）。作者と本文の頭の両方が一致したときだけ外す。
# 片方だけの一致は外さない（迷う入力は赤に倒す）。一覧は jq に固定し、呼び出し側の入力では足しも外しもできない。
# 頭は、取得した本文そのものの先頭で見る（空白・HTML コメント・`>` を飛ばさず、大小文字も区別する）。
# 既存のパターンの `contains`（本文のどこか）とは当て方が違う。
def default_ignored_notices:
  [ { author: "chatgpt-codex-connector", head: "You have reached your Codex usage limits" } ];

def default_ignored_notice:
  report_author_login as $author
  | (.body // "") as $body
  | any(default_ignored_notices[]; . as $n | $n.author == $author and ($body | startswith($n.head)));

# TAKT の失敗報告の種別。本文の語句ではなく、マーカーと著者・本文の形で決める。
# マーカーはフェンスの外にあるときだけ効く（引用ではフェンスの中に入る）。
def has_takt_marker:
  strip_fences
  | test("<!--\\s*takt:auto-report\\s*-->");

# フェンスが 1 つ以上あり、フェンスの外が空白だけ（散文が無い）。
# フェンスの直前に一文だけ散文がある形は、散文があるので自動報告にしない。
def fenced_report_body:
  fence_split
  | .fenced > 0 and (.prose | join("\n") | test("^\\s*$"));

# マーカーは作成者の投稿に限って効く。第三者が付けたマーカーは無視する。
def takt_report:
  is_author and (has_takt_marker or fenced_report_body);

# 自動報告か。v1 の ignored_auto_report（著者＋本文パターン）に、既定で外す通知と
# TAKT の失敗報告の種別を足す。それ以外の項目の選び方は変えない。
def is_auto_report:
  ignored_auto_report or default_ignored_notice or takt_report;

# Codex の承知。v1 と同じく文頭一致だけを見る。語彙も v1 と同じ trusted_ack_words だけ。
# 本文の途中の `fixed` も、文頭の `Fixed` も承知にしない（Codex の要約を項目から消さない）。
def trusted_acknowledgement:
  report_author_login == "chatgpt-codex-connector" and ack_at_start;

def is_item:
  (trusted_acknowledgement | not)
  and ((.author.login // "") != $pr_author)
  and (
    $pr_author_type != "Bot"
    or (
      .authorAssociation != "OWNER"
      and .authorAssociation != "MEMBER"
      and .authorAssociation != "COLLABORATOR"
    )
  );

def is_acknowledger:
  (.author.login // "") == $pr_author
  or trusted_acknowledgement
  or (
    $pr_author_type == "Bot"
    and (
      .authorAssociation == "OWNER"
      or .authorAssociation == "MEMBER"
      or .authorAssociation == "COLLABORATOR"
    )
  );

# 判定の順序: 先に自動報告を外し、残った候補だけで項目と承認を数える。
# 自動報告は is_item にも is_acknowledger にも入らない（acked_keys より前）。
# 確認ごとに、承認する項目の位置（$its の key）を acked_keys で求め、対象の最終編集より後のものだけを数える。
. as $all
| ($all | map(select(is_auto_report))) as $reports
| ($all - $reports) as $candidates
| ($candidates | map(select(is_item))) as $its
| ($reports | map(select(default_ignored_notice) | quote_text(.))) as $excl
| [ $candidates[] | select(is_acknowledger) | {at: .createdAt, keys: acked_keys($its; $excl)} ] as $acks
| [ range(0; $its | length) as $k
    | $its[$k] as $item
    | select([ $acks[]
               | select(.at > ($item.updatedAt // $item.createdAt))
               | select(.keys | index($k) != null) ] | length == 0)
    | $item
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
      jq -r '.[] | "- by \(.author.login // "unknown") updated at \((.updatedAt // .createdAt)): \(.url // "no comment URL")\n  確認するには、返信にこの URL を含めるか、本文を 20 文字以上引用し、\n  「確認しました」などの語を添えてください（URL は長さを問いません）。\n  引用はコードフェンスで囲んでもかまいません。\n  ほかの項目にもある文（定型文）と、URL の一部は引用として数えません。\n  確認の語は、URL・引用と同じ段落かリストの項目に書いてください。\n  引用（行頭の >、「」）の中の語と、「未対応です」「not been fixed」\n  「確認済みではありません」のような打ち消しは確認として数えません。"' <<< "$unacknowledged"
      echo
      echo "同じ文が並ぶ自動の通知（レート制限の通知が 2 回など）は、引用ではどれも確認になりません。"
      echo "通知ごとに URL（アンカー）を貼り、同じ行に確認の語を添えてください。"
      echo "  例: - https://github.com/o/r/pull/1#issuecomment-1001 を確認しました。"
      echo "      - https://github.com/o/r/pull/1#issuecomment-1002 を確認しました。"
      echo
      echo "自動投稿（TAKT の失敗報告など）は確認として数えません。"
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
