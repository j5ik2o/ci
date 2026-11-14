# AISLOP check

Common gate that compares an [aislop](https://github.com/j5ik2o/aislop) scan
against a per-repository accepted-findings list and fails on any mismatch.
There is exactly one copy of the checker logic, in this directory of
`j5ik2o/ci`. Caller repositories pin a version and fetch it; they keep only
their own data (the accepted list) and a verbatim copy of the bootstrap.

Decided 2026-11-14 as an all-project common specification: the three
anti-empty-pass checks below are mandatory, distribution is canonical
(this repository), and adoption is piloted in ddd-principles before rollout.

## Files

- `check-aislop.mjs` — the checker. Compares `aislop scan --json` output
  with the caller's accepted list (`engine` / `rule` / `file` / `message`,
  line numbers ignored) and fails when they disagree.
- `check-aislop.test.mjs` — the checker's tests (`node --test`). Pure-logic
  tests run anywhere; tests that need a real aislop installation or a real
  accepted list read `AISLOP_CHECK_ROOT`, `AISLOP_CHECK_ACCEPTED`, and
  `AISLOP_CHECK_CLI` and skip when aislop is absent.
- `bootstrap.mjs` — the fetch-and-run launcher. Caller repositories copy
  this file verbatim to `scripts/aislop-check-bootstrap.mjs` and do not
  edit the copy; fixes land here first and are then re-copied, the same
  treatment as the review-thread-resolution caller file.
- `fixtures/aislop-accepted.json` — a minimal accepted list so the shape
  tests can run inside this repository.

## The three anti-empty-pass checks (mandatory)

aislop can return a clean-looking result while having seen nothing. The
checker must not pass in that state:

1. **Zero target files fail.** The scan's target file count
   (`coverage.supportedFiles`, falling back to `summary.files`) must be
   present and greater than zero. A scan that saw nothing never "matches
   the accepted list". (Observed in practice: a real-repository run with
   0 files and 0 diagnostics passed before this check existed.)
2. **A stopped engine passes only on verified, allowed absence.** aislop
   0.20.1 has no dedicated failure record; an engine failure surfaces as
   `skipped: true`, indistinguishable in the report from a stop caused by
   a missing tool. So when an engine is skipped, the checker itself probes
   whether each missing tool is actually absent (Node tools by resolution
   from aislop's location, external tools such as `ruff` by attempting to
   run them) and passes the skip only when every missing tool is both
   verified absent and listed in the caller's `missingToolsAllowed`.
   A skip with no recorded missing tool, an unallowed tool, or a tool
   whose absence cannot be verified is a failure.
3. **Every expected engine must appear.** Each engine named in the
   accepted list's `engines` must have a record in the scan result.
   A missing record is a failure.

The checker also keeps the earlier safeguards: tools that aislop resolves
from its own location (oxlint, biome, knip) are resolution-checked before
the scan, biome must actually run, and an engine whose accepted findings
all disappear is treated as suspected-stopped rather than fixed.

## How a caller repository adopts this

1. Add aislop as a pinned devDependency (`"aislop": "0.20.1"`).
2. Copy `bootstrap.mjs` to `scripts/aislop-check-bootstrap.mjs`, unedited.
3. Write `scripts/aislop-accepted.json`: your `engines`, your
   `missingToolsAllowed` (each entry with the reason the tool is not
   installed), and your accepted findings grouped by reason.
4. Write `scripts/aislop-check-pin.json` with the canonical ref and the
   SHA-256 of the two canonical files at that ref:

   ```json
   {
     "ref": "aislop-check-v1",
     "files": {
       "check-aislop.mjs": "<sha256>",
       "check-aislop.test.mjs": "<sha256>"
     }
   }
   ```

5. Add npm scripts and wire them into the repository's CI chain:

   ```json
   "check:aislop": "node scripts/aislop-check-bootstrap.mjs check",
   "test:aislop": "node scripts/aislop-check-bootstrap.mjs test"
   ```

The bootstrap downloads the two files from
`raw.githubusercontent.com/j5ik2o/ci/<ref>/aislop/...` (this repository is
public, so no credentials are needed), verifies each file's SHA-256
against the pin before use, and caches them under
`node_modules/.aislop-check/<ref>/`. The cache lives under `node_modules`
on purpose: aislop does not scan `node_modules`, so the fetched canonical
files cannot produce findings of their own (a repository-root cache was
measured to fail the check for exactly that reason). With a valid cache
the bootstrap works without network access. A hash mismatch is a hard
failure and the fetched file is never used.

## Versioning

Canonical changes land on `main` through a pull request, then a new tag
(`aislop-check-v2`, `aislop-check-v3`, ...) is placed on the merge commit.
Tags are never moved. A caller moves to a new version by updating
`scripts/aislop-check-pin.json` (the ref and both hashes) in its own pull
request, so every adoption is reviewed with the version it pins.

## Running the tests in this repository

```
node --test aislop/check-aislop.test.mjs
```

The fixture accepted list is used by default. To run the same tests the
way a caller does, set `AISLOP_CHECK_ROOT`, `AISLOP_CHECK_ACCEPTED`, and
`AISLOP_CHECK_CLI` to the caller's values (the bootstrap does this).
