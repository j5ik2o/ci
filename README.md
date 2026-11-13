# ci

Common GitHub Actions workflows and composite actions for j5ik2o repositories.

## Versioning

Caller repositories should reference a tag or SHA, not a moving branch, for merge
protection gates.

```yaml
uses: j5ik2o/ci/.github/workflows/review-thread-resolution.yml@v1
```

When a reusable workflow checks out shared scripts from this repository, set
`ci_ref` to the same tag. The Review Thread Resolution template omits `ci_ref`
because its default, `v1`, matches the tag the template uses.

## Review Thread Resolution

The shared workflow evaluates unresolved review threads, top-level PR comments,
review summaries, and the conclusions of the other checks on the PR head. It
publishes a synthetic commit status named `Check unresolved comments`.

### Caller template

Every caller repository uses this file as is, at
`.github/workflows/review-thread-resolution.yml`. It has no per-repository
values, so copy it without editing. GitHub Actions reads triggers only from the
caller file, so the template carries the trigger list. The shared workflow reads
everything else from the event payload: the PR number, whether to wait for the
other checks, and the base branch (the repository default branch).

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
    workflows: ["**", "!Review Thread Resolution"]
    types: [completed]
  check_suite:
    types: [completed]
  status:
  schedule:
    - cron: "17 18 * * *"
  workflow_dispatch:
    inputs:
      pr_number:
        description: PR number to refresh. Leave empty to refresh all open PRs.
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
```

Each trigger has one job:

- `pull_request` covers `opened`, `synchronize`, `reopened`, and
  `ready_for_review`, so a new PR head receives the status without waiting for a
  review or comment event.
- `pull_request_review`, `pull_request_review_comment`, and `issue_comment`
  re-evaluate when review state changes.
- `workflow_run` re-evaluates when any other workflow completes, because a long
  CI run can finish after the gate's wait ends. The `!Review Thread Resolution`
  pattern keeps the gate from re-triggering on its own runs, and the shared job
  also skips a `workflow_run` event from its own caller file.
- `check_suite` re-evaluates when a GitHub App other than GitHub Actions (Cursor
  Bugbot, CodeRabbit, GitGuardian, and similar) completes its checks. GitHub
  does not send `check_suite` for suites that GitHub Actions created.
- `status` re-evaluates when another service posts a commit status. Statuses
  that this workflow publishes with `GITHUB_TOKEN` do not start workflow runs,
  so the gate does not re-trigger itself.
- `schedule` refreshes every open PR once a day, at 18:17 UTC. It is also the
  only trigger that sees a resolved or unresolved review thread. GitHub Actions
  has no event for thread resolution, and it rejects a workflow that lists
  `pull_request_review_thread` under `on:` as an invalid workflow file.
- After the last thread is resolved, the status stays `failure` until the next
  run. That run comes from the next review, comment, push, completed workflow,
  or app check, or from a manual `workflow_dispatch` with the PR number.
  Without any of these, it comes from the daily schedule, up to about a day
  later.
- `workflow_dispatch` refreshes one PR, or every open PR when `pr_number` is
  empty. Only this event honors the `wait_for_other_checks` input; every other
  event waits for the other checks.

`workflow_run`, `check_suite`, and `status` run from the template on the
default branch. `workflow_run` and `check_suite` re-evaluate the first PR in
the event's `pull_requests` list, and `status` re-evaluates the open PR whose
head is the event's commit. Events for fork PRs or commits without a PR are
skipped.

### Status

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
`workflow_dispatch`), and stops waiting as soon as one of them fails. The status
then follows the table above. A failed check publishes `failure` even while
others are still running. If checks are still running when the wait ends and
none has failed, the run publishes `pending` instead of guessing, and a later
run settles the status. Scheduled and manual refresh-all
runs do not wait, but they still publish `pending` or `failure` from the other
checks.

The gate only sees checks that have already reported on the PR head. GitHub
Actions creates the check runs of every workflow that an event starts while
those jobs are still queued, so a gate run started by the same event sees them.
A check that a GitHub App or another service reports later is not visible until
it reports; its report then re-evaluates the gate through `check_suite` or
`status`.

### Branch protection

Require the synthetic status context `Check unresolved comments`. Because it
requires the other checks to pass, it can be the only required check. Refresh
runs publish that context but do not fail the workflow job for unresolved review
state or for other checks. Concurrent refresh runs use per-run concurrency
groups so GitHub Actions does not cancel older pending refresh jobs.

### CI gate mode

A repository that requires an aggregate CI job instead of this status can call
the shared workflow from its CI workflow with `wait_for_other_checks: "false"`.
In that mode, unresolved review state fails the reusable workflow job so the
aggregate job can depend on it. The job result ignores the other checks, so the
aggregate job does not wait on itself. A CI gate run cannot see the other jobs
of its own run, so it publishes `pending` instead of `success`, and the
template's runs settle `success` after CI completes.

Do not require both. When the aggregate job depends on a CI gate job that failed
for review state, the aggregate job stays failed after the threads are
resolved, and the synthetic status reports it as a failed check until CI runs
again.

### Ignored bot reports

Top-level bot report comments and review summaries can be excluded from the
acknowledgement gate with newline-separated literal substrings. The default
`ignored_auto_report_patterns` covers CodeRabbit, Renovate notifications,
Codecov reports, Cursor Bugbot summaries, and Devin Review summaries. When a
repository adopts another review bot, add a stable HTML marker or unique text to
the defaults in this repository, so the caller template stays the same
everywhere. The `extra_ignored_auto_report_patterns` input exists for callers
outside the template:

```yaml
with:
  extra_ignored_auto_report_patterns: |
    <!-- another-review-bot-summary -->
```

For generic text that could appear in a human review comment, add an
author-scoped pattern instead (`ignored_auto_report_author_patterns`, or
`extra_ignored_auto_report_author_patterns` outside the template). Each line is
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
