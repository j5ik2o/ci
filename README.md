# ci

Common GitHub Actions workflows and composite actions for j5ik2o repositories.

## Versioning

Caller repositories should reference a tag or SHA, not a moving branch, for merge
protection gates.

```yaml
uses: j5ik2o/ci/.github/workflows/review-thread-resolution.yml@v1
```

When a reusable workflow checks out shared scripts from this repository, set
`ci_ref` to the same tag.

## Review Thread Resolution

Keep the trigger wrapper in each caller repository. The shared workflow evaluates
unresolved review threads, top-level PR comments, and review summaries. It
publishes a synthetic commit status named `Check unresolved comments` by default.

```yaml
name: Review Thread Resolution

on:
  pull_request_review:
    types: [submitted, edited, dismissed]
  pull_request_review_comment:
    types: [created, edited, deleted]
  issue_comment:
    types: [created, edited, deleted]
  schedule:
    - cron: "*/15 * * * *"
  workflow_dispatch:
    inputs:
      pr_number:
        description: PR number to refresh. Leave empty to refresh all open main PRs.
        required: false
        type: string
      wait_for_other_checks:
        description: Wait for other PR checks before evaluating review threads.
        required: false
        default: true
        type: boolean

jobs:
  refresh:
    uses: j5ik2o/ci/.github/workflows/review-thread-resolution.yml@v1
    permissions:
      contents: read
      checks: write
      statuses: write
      issues: read
      pull-requests: read
    with:
      pr_number: ${{ inputs.pr_number }}
      wait_for_other_checks: ${{ inputs.wait_for_other_checks }}
      base_branch: main
      required_context: Check unresolved comments
      ci_ref: v1
```

For branch protection, prefer requiring the synthetic status context
`Check unresolved comments`. Event-driven refresh runs publish that context but
do not fail the workflow job for unresolved review state, and concurrent refresh
runs use per-run concurrency groups so GitHub Actions does not cancel older
pending refresh jobs. This keeps the synthetic status as the only branch
protection signal while avoiding cancelled refresh check-runs on the PR head.

CI gate callers should pass `wait_for_other_checks: "false"`. In that mode,
unresolved review state still fails the reusable workflow job so a caller's
aggregate `CI Success` job can depend on it.

Top-level bot report comments and review summaries can be excluded from the
acknowledgement gate with newline-separated literal substrings. The default
`ignored_auto_report_patterns` covers CodeRabbit, Renovate notifications,
Codecov reports, Cursor Bugbot summaries, and Devin Review summaries. Add a
stable HTML marker or unique text with `extra_ignored_auto_report_patterns` when
a caller adopts another review bot:

```yaml
with:
  extra_ignored_auto_report_patterns: |
    <!-- another-review-bot-summary -->
```

For generic text that could appear in a human review comment, use
`extra_ignored_auto_report_author_patterns` instead. Each line is
`author-login<TAB>literal-substring`, and bot logins are normalized without the
trailing `[bot]` suffix:

```yaml
with:
  extra_ignored_auto_report_author_patterns: |
    another-review-bot	## Automated Review Summary
```

## TAKT Review

The caller repository keeps the trigger policy. The shared workflow resolves and
checks out same-repository, non-draft, non-Renovate PRs, then runs the bundled
default TAKT wrapper script. Set `wrapper_script` only when a caller repository
needs a custom wrapper.

```yaml
name: TAKT Review

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  issue_comment:
    types: [created]

jobs:
  takt-review:
    uses: j5ik2o/ci/.github/workflows/takt-review.yml@v1
    permissions:
      contents: read
      pull-requests: write
      issues: write
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    with:
      pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
      event_head_sha: ${{ github.event.pull_request.head.sha }}
      comment_body: ${{ github.event.comment.body }}
      workflow: review-takt-default
      provider: claude-sdk
      model: claude-sonnet-4-5-20250929
      ci_ref: v1
```

## Validation

```bash
bash scripts/validate-workflows.sh
```
