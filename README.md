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
unresolved review threads, top-level PR comments, review summaries, and the
conclusions of the other checks on the PR head. It publishes a synthetic commit
status named `Check unresolved comments` by default.

```yaml
name: Review Thread Resolution

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  pull_request_review:
    types: [submitted, edited, dismissed]
  pull_request_review_comment:
    types: [created, edited, deleted]
  issue_comment:
    types: [created, edited, deleted]
  workflow_run:
    workflows: [CI]
    types: [completed]
  check_suite:
    types: [completed]
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
      wait_for_other_checks: ${{ (github.event_name != 'workflow_dispatch' || inputs.wait_for_other_checks) && 'true' || 'false' }}
      base_branch: main
      required_context: Check unresolved comments
      ci_ref: v1
```

The `pull_request` trigger covers `opened`, `synchronize`, `reopened`, and
`ready_for_review` so that a new PR head also receives the synthetic status
context instead of relying on later review or comment events. The
`wait_for_other_checks` expression only honors the manual input on
`workflow_dispatch` runs, because `inputs.*` is empty for every other event
type; all other runs wait for the other PR checks.

The status reflects both the review state and the other checks on the PR head:

| Review state | Other checks | Status |
| --- | --- | --- |
| Unresolved threads or unacknowledged comments | any | `failure` |
| Clean | at least one did not pass | `failure` |
| Clean | none failed, at least one still running | `pending` |
| Clean | all passed | `success` |

A check run passes when it concludes `success`, `skipped`, or `neutral`. Any
other conclusion (`failure`, `cancelled`, `timed_out`, `action_required`,
`stale`, `startup_failure`) does not pass. A commit status passes only when its
state is `success`; `pending` and `expected` count as running, and `failure` and
`error` do not pass. The gate ignores its own status context, the check runs of
the review-thread workflows by job name, and the jobs of its own workflow run.

A run waits for the other checks before it evaluates (up to 60 polls, or 3 for
`workflow_dispatch`). If checks are still running when the wait ends, the run
publishes `pending` instead of guessing, and a later run settles the status.
Scheduled and manual refresh-all runs do not wait, but they still publish
`pending` or `failure` from the other checks.

Because a long CI run can finish after the gate's wait ends, the example
re-evaluates the gate when other work completes:

- `workflow_run` fires when the listed workflows complete. Replace `[CI]` with
  the names of the caller's own CI workflows, and do not list this workflow.
  GitHub runs `workflow_run` from the workflow file on the default branch.
- `check_suite` fires when a GitHub App other than GitHub Actions (Cursor
  Bugbot, CodeRabbit, and similar) completes its checks. GitHub does not send
  `check_suite` for suites that GitHub Actions created, which is why
  `workflow_run` is also needed. Like `workflow_run`, it runs from the default
  branch.
- `schedule` refreshes every open PR as a fallback.

Statuses that this workflow publishes with `GITHUB_TOKEN` do not start new
workflow runs, so the gate does not re-trigger itself.

For branch protection, prefer requiring only the synthetic status context
`Check unresolved comments`, because it already requires the other checks to
pass. Event-driven refresh runs publish that context but do not fail the
workflow job for unresolved review state or for other checks, and concurrent refresh
runs use per-run concurrency groups so GitHub Actions does not cancel older
pending refresh jobs. This keeps the synthetic status as the only branch
protection signal while avoiding cancelled refresh check-runs on the PR head.

CI gate callers should pass `wait_for_other_checks: "false"`. In that mode,
unresolved review state still fails the reusable workflow job so a caller's
aggregate `CI Success` job can depend on it. The job result ignores the other
checks, so the aggregate job does not wait on itself, but the published status
still includes them.

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

## Node TypeScript Unit Coverage

Use this workflow for repo-native unit coverage gates in Node.js + TypeScript
repositories. The shared workflow owns CI orchestration only: checkout, Node and
pnpm setup, dependency install, build, head/base measurement, evaluation summary,
and artifact upload. Coverage policy, target selection, and report generation
stay in the caller repository through `unit-coverage.manifest.json` and the
caller scripts.

On pull request events, the workflow creates a base worktree from the PR base
branch, installs and builds dependencies in both head and base, measures both
coverage states, and then runs the caller evaluation command. On non-PR events,
only head coverage is measured.

The base measurement command runs from the head checkout with
`UNIT_COVERAGE_TARGET_WORKSPACE` pointing at the base worktree. That keeps new
coverage tooling in the head branch and avoids requiring the base branch to
already contain the same coverage scripts.

```yaml
name: Unit Coverage

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  push:
    branches: [main]

jobs:
  unit-coverage:
    uses: j5ik2o/ci/.github/workflows/node-typescript-unit-coverage.yml@v1
    permissions:
      contents: read
    with:
      node_version: "24"
      pnpm_version: 9.15.9
      base_branch: ${{ github.event.pull_request.base.ref || 'main' }}
      manifest_path: unit-coverage.manifest.json
      build_command: pnpm -r build
      install_command: pnpm install --frozen-lockfile
      coverage_plan_command: pnpm coverage:plan
      coverage_measure_command: pnpm coverage:measure
      coverage_evaluate_command: pnpm coverage:evaluate
      artifact_name: unit-coverage-reports
```

Caller scripts can use these environment variables to avoid hard-coding shared
CI paths:

- `UNIT_COVERAGE_MANIFEST_PATH`: manifest path from the workflow input.
- `UNIT_COVERAGE_PLAN_PATH`: expected measurement plan path.
- `UNIT_COVERAGE_SUMMARY_PATH`: Markdown summary appended to
  `$GITHUB_STEP_SUMMARY` after evaluation, even when evaluation fails.
- `UNIT_COVERAGE_PHASE`: one of `plan`, `head`, `base`, or `evaluate`.
- `UNIT_COVERAGE_OUTPUT_DIR`: phase-specific output directory.
- `UNIT_COVERAGE_WORKSPACE`: workspace where the caller script is running.
- `UNIT_COVERAGE_TARGET_WORKSPACE`: workspace that should be measured for the
  current `head` or `base` phase.
- `UNIT_COVERAGE_HEAD_OUTPUT_DIR`: head coverage report directory.
- `UNIT_COVERAGE_BASE_OUTPUT_DIR`: base coverage report directory.
- `UNIT_COVERAGE_HEAD_WORKSPACE`: head checkout path.
- `UNIT_COVERAGE_BASE_WORKSPACE`: base worktree path for PR events.
- `UNIT_COVERAGE_IS_PR`: `true` for pull request events.
- `UNIT_COVERAGE_BASE_BRANCH`: branch used for base coverage comparison.

## Validation

```bash
bash scripts/validate-workflows.sh
```
