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

jobs:
  refresh:
    if: ${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || github.event.pull_request != null || (github.event_name == 'issue_comment' && github.event.issue.pull_request != null) }}
    uses: j5ik2o/ci/.github/workflows/review-thread-resolution.yml@v1
    permissions:
      contents: read
      checks: write
      statuses: write
      issues: read
      pull-requests: read
    with:
      pr_number: ${{ github.event.pull_request.number || github.event.issue.number || inputs.pr_number }}
      base_branch: main
      required_context: Check unresolved comments
      ci_ref: v1
```

For branch protection, prefer requiring the synthetic status context
`Check unresolved comments`. The workflow job name is intentionally separate so
cancelled workflow runs do not become the protected gate.

## TAKT Review

The caller repository keeps the trigger policy. The shared workflow resolves and
checks out same-repository, non-draft, non-Renovate PRs, then runs the caller
repository wrapper script.

```yaml
name: TAKT Review

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  issue_comment:
    types: [created]

jobs:
  takt-review:
    if: >
      (
        github.event_name == 'pull_request' &&
        github.event.pull_request.head.repo.full_name == github.repository &&
        github.event.pull_request.draft == false &&
        github.event.sender.type != 'Bot'
      ) ||
      (
        github.event_name == 'issue_comment' &&
        github.event.issue.pull_request != null &&
        github.event.issue.state == 'open' &&
        github.event.sender.type != 'Bot' &&
        startsWith(github.event.comment.body, '@takt') &&
        (
          github.event.comment.author_association == 'OWNER' ||
          github.event.comment.author_association == 'MEMBER' ||
          github.event.comment.author_association == 'COLLABORATOR'
        )
      )
    uses: j5ik2o/ci/.github/workflows/takt-review.yml@v1
    permissions:
      contents: read
      pull-requests: write
      issues: write
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    with:
      pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
      comment_body: ${{ github.event.comment.body }}
      workflow: review-takt-default
      provider: claude-sdk
      model: claude-sonnet-4-5-20250929
      wrapper_script: .github/scripts/takt-review-wrapper.mjs
      ci_ref: v1
```

## Validation

```bash
bash scripts/validate-workflows.sh
```
