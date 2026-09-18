# 5. Scripts reference: what each script does and what it changes

Every script lives in `scripts/`, runs under Bash (Git Bash on Windows), and uses `set -Eeuo pipefail` so any failing command stops it. Each section lists the purpose, inputs, the exact side effects (grouped by **git**, **Salesforce org**, **GitHub**, **Gearset**, **local files**) and what happens on failure.

| Symbol | Meaning |
|--------|---------|
| Writes | The script creates, modifies or deletes something |
| Reads | The script only reads |
| None | The script does not touch this system |

---

## `create-pr.sh`: commit metadata to a feature branch and open a PR

**Purpose.** Turns Salesforce metadata into a reviewed pull request against `master` in one command. The metadata can come from files already changed in the working tree (`--path`) or be pulled from an org in SFDX source format (`--retrieve Type:Name` or `--manifest package.xml`). Once the PR exists, the three Gearset CI jobs validate it.

**Typical use**

```bash
# Files you changed locally
scripts/create-pr.sh -m "ACC-123 account scoring" \
  -p force-app/main/default/classes/AccountScoring.cls \
  -p force-app/main/default/classes/AccountScoringTest.cls

# A Flow and a field an admin built in the Partial sandbox
scripts/create-pr.sh -m "Lead routing flow" -o partial \
  -r "Flow:Lead_Router" -r "CustomField:Lead.Region__c" -l flow
```

**Inputs.** `--title` (required), `--target` (default: origin's default branch, `master` here, or `DEFAULT_TARGET`), `--branch` (default `feature/<slug-of-title>`), one or more `--path`, `--retrieve`, `--manifest`, `--source-org` (or `SF_SOURCE_ORG`), `--body`/`--body-file`, `--label`, `--reviewer`, `--draft`, `--dry-run`.

**What it changes**

| System | Effect |
|--------|--------|
| Local git | **Writes.** Fetches `origin/master`. Creates the feature branch from `origin/master` (or switches to it if it exists). Stages only the given paths plus their `-meta.xml` companions, or, in retrieve mode with no paths, everything under the package directories from `sfdx-project.json`. Creates **one commit** whose subject is the title. Leaves you on the feature branch. |
| Remote git | **Writes.** Pushes the feature branch to `origin` with upstream tracking. Nothing is pushed with `--dry-run`. |
| Salesforce org | **Reads only.** With `--retrieve`/`--manifest` it runs `sf project retrieve start` against the source org, which downloads metadata into `force-app/`. It never deploys. |
| GitHub | **Writes.** Creates a pull request from the feature branch to `master` with the title, body, labels and reviewers. If an open PR already exists for that branch it prints its URL instead of creating a second one. |
| Gearset | **None directly.** Opening the PR causes Gearset's PR validation to run on the three CI jobs. |
| Local files | **Writes** to `force-app/` when retrieving (overwrites local copies of the retrieved components). |

**Guard rails.** Refuses `master` or `main` as the feature branch. Requires `git` and `gh` (authenticated), and `sf` only when retrieving. Aborts with "No changes to commit" when the staged metadata equals `master`.

**On failure.** The `ERR` trap prints the failing line and command; an `EXIT` trap then runs the cleanup for every non-zero exit, including the script's own validation errors. If the branch was created by the script and nothing was committed, it switches back to your original branch and deletes the new branch. If a commit exists, it keeps the branch and prints the push and PR command to retry by hand.

**Tested by** `tests/run-tests.sh` (see `docs/06-running-the-scripts.md`).

---

## `sf-delta.sh`: build an incremental package between two commits

**Purpose.** Wraps `sf sgd source delta` (sfdx-git-delta) so the workflows build packages the same way. Produces `package.xml` for added/changed components, `destructiveChanges.xml` for deleted ones, and copies the changed SFDX source files. Used by `PR checks` to show what a PR will deploy, and by the Salesforce CLI deployment and rollback paths.

**Typical use**

```bash
scripts/sf-delta.sh --from refs/tags/deployed/uat --to HEAD
scripts/sf-delta.sh --from <base-sha> --to <head-sha> --merge-base   # PRs
```

**Inputs.** `--from` (required), `--to` (default `HEAD`), `--out` (default `delta`), `--merge-base` (three-dot diff, used for PRs).

**What it changes**

| System | Effect |
|--------|--------|
| Local git | **Reads only.** Resolves refs and reads file contents at both commits. Never commits, checks out or pushes. |
| Salesforce org / Gearset | **None.** |
| GitHub | **Writes** the outputs `has_changes`, `package`, `destructive`, `out_dir` to `$GITHUB_OUTPUT` and a delta summary to `$GITHUB_STEP_SUMMARY` when running inside Actions. |
| Local files | **Writes.** Deletes and recreates the output directory (`delta/` by default) containing `package/package.xml`, `destructiveChanges/destructiveChanges.xml`, `destructiveChanges/package.xml` and the changed source under `delta/force-app/`. |

**Behaviour to know.** If `--from` is the all-zero sha GitHub sends on a first push, or a commit that no longer exists after a force-push, it warns and uses `<to>~1`. It honours `.sgdignore` (files that never enter a delta) and `.sgdignore-destructive` (files that never generate deletions). `has_changes=false` makes the calling workflow skip deployment.

---

## `sf-deploy.sh`: validate, deploy or quick-deploy a delta with the Salesforce CLI

**Purpose.** Runs the Salesforce CLI deployment for a delta and turns the JSON result into readable errors. Used only on the Salesforce CLI paths: `DEPLOY_ENGINE=sf`, `PR_SF_VALIDATE_ENV`, and the `Rollback` workflow. Not used when Gearset deploys.

**Typical use**

```bash
scripts/sf-deploy.sh --org uat  --mode validate --delta delta --test-level RunLocalTests
scripts/sf-deploy.sh --org uat  --mode deploy   --delta delta --test-level RunLocalTests
scripts/sf-deploy.sh --org prod --mode quick    --job-id 0Af...
```

**Inputs.** `--org` (required alias), `--mode validate|deploy|quick`, `--delta` (default `delta`), `--test-level` (default `RunLocalTests`), `--tests` (for `RunSpecifiedTests`), `--wait` minutes (default 90), `--job-id` (quick mode).

**What it changes, per mode**

| Mode | Salesforce org | Notes |
|------|----------------|-------|
| `validate` | **Check-only.** Runs `sf project deploy validate` (tests required) or `sf project deploy start --dry-run` with `NoTestRun`. Apex tests execute in the org but no metadata is saved. | A validation with tests produces a job id that can be quick-deployed within 10 days. |
| `deploy` | **Writes.** `sf project deploy start` with the delta's `package.xml` and, if present, `--post-destructive-changes` (components are **deleted** from the org after the additions succeed). Metadata API deployments are atomic: if any component or test fails, nothing is saved. | Deletions are limited by `.sgdignore-destructive`. |
| `quick` | **Writes.** `sf project deploy quick --job-id` applies a previously validated package without re-running tests. | Only valid if nothing changed in the org since the validation. |

| System | Effect |
|--------|--------|
| Local git / files | **Reads** the delta directory only. Writes nothing. |
| GitHub | **Writes** `status` and `job_id` to `$GITHUB_OUTPUT`; success or failure tables to `$GITHUB_STEP_SUMMARY`; `::error::`/`::warning::`/`::notice::` annotations. |
| Gearset | **None.** |

**On failure.** Exit 1. Every component failure (type, name, line, problem), every failed Apex test (class.method and message) and every coverage warning is printed as an annotation and listed in the summary. If the CLI produced no JSON, the raw output is printed. If the deployment is still running after `--wait`, it prints the `sf project deploy resume --job-id` command. An empty delta exits 0 with `status=Skipped`.

---

## `gearset-run.sh`: start a Gearset CI job and wait for it

**Purpose.** Lets GitHub Actions run the three CI jobs in order (Partial, UAT, Production validation) and stop at the first failure. Used by `deploy-on-merge.yml` when `DEPLOY_ENGINE=gearset-api`.

**Typical use**

```bash
GEARSET_API_TOKEN=... GEARSET_CI_JOB_ID=... scripts/gearset-run.sh
```

**Inputs (environment variables).** `GEARSET_API_TOKEN`, `GEARSET_CI_JOB_ID` (required); `GEARSET_TIMEOUT_MIN` (90), `GEARSET_POLL_SEC` (30), `GEARSET_WAIT_IDLE_MIN` (30).

**What it changes**

| System | Effect |
|--------|--------|
| Gearset | **Writes.** Polls `GET .../continuous-integration-jobs/{id}/status` until `Idle`, then `POST .../run-requests` with `{}` to **start one run of the CI job**, then polls `GET .../run-requests/{id}` until `Succeeded`, `Failed`, `Error` or `Cancelled`. |
| Salesforce org | **Writes, indirectly**, for the Partial and UAT jobs: the CI job performs the deployment exactly as if started from Gearset's UI. For the Production validate-only job nothing is written. |
| Local git / files | **None.** |
| GitHub | **Writes** `run_request_id`, `run_id`, `state` to `$GITHUB_OUTPUT` and a result block to the step summary. |

**On failure.** 401/403 or 404 exit 3 immediately with the secret or job id to check. 429 and 5xx retry five times with growing back-off. A `Failed`/`Error`/`Cancelled` run exits 1 and points to the run history in Gearset. A run still going after the timeout exits 2; the run continues in Gearset. The workflow moves `deployed/partial` or `deployed/uat` only when this script exits 0.

---

## `rollback.sh`: deploy the reverse delta to an org

**Purpose.** Returns an org to a known-good commit with the Salesforce CLI. Used by `rollback.yml`; can also be run by hand. For Production, prefer Gearset's own rollback.

**Typical use**

```bash
scripts/rollback.sh --org uat --good abc1234 --bad refs/tags/deployed/uat --validate-only
scripts/rollback.sh --org uat --good abc1234 --bad refs/tags/deployed/uat
```

**Inputs.** `--org`, `--good` (required), `--bad` (default `HEAD`), `--test-level` (default `RunLocalTests`), `--validate-only`.

**What it changes**

| System | Effect |
|--------|--------|
| Local git | **Writes to the working tree.** Runs `git checkout <good>` so the working tree matches the good commit (detached HEAD). No commits, no pushes. In a workflow the runner is thrown away; locally, switch back to your branch afterwards. |
| Salesforce org | **Writes** (unless `--validate-only`). Deploys the delta from *bad* to *good*: every component changed by the bad commits is **restored** to its good version, and every component **added** by the bad commits is **deleted** through `destructiveChanges.xml`. Deletions are still filtered by `.sgdignore-destructive`, so fields, objects, profiles, permission sets and flows are never deleted automatically. |
| Local files | **Writes** `rollback-delta/` with the reverse package. |
| GitHub | Same outputs and summaries as `sf-delta.sh` and `sf-deploy.sh`. |
| Gearset | **None.** Gearset's next CI run will see `master` ahead of the org again, which is why the workflow opens a revert PR. |

**What it does not do.** It does not change `master`. `rollback.yml` follows up by moving the `deployed/<env>` tag and opening a PR against `master` that restores the same files. Merge that PR, or the next merge re-applies the bad change to both sandboxes. See `docs/03-error-handling-and-rollback.md` for what no rollback can undo.

---

## How the workflows use the scripts

| Workflow | Trigger | Scripts called | Changes it makes beyond the scripts |
|----------|---------|----------------|--------------------------------------|
| `pr-validate.yml` (`PR checks`) | PR to `master` | `sf-delta.sh`; `_sf-deploy.yml` when `PR_SF_VALIDATE_ENV` is set | Uploads the delta artifact; flags deletions; runs Code Analyzer; posts or updates one PR comment |
| `deploy-on-merge.yml` (`Deploy on merge`) | push to `master` | `gearset-run.sh` (API mode) or `_sf-deploy.yml` (sf mode); nothing in `gearset-auto` mode | Moves `deployed/partial` and `deployed/uat` after each successful deploy; writes a "deployable to Production" summary |
| `_sf-deploy.yml` (reusable) | called | `sf-delta.sh`, `sf-deploy.sh` | Authenticates from the environment's `SFDX_AUTH_URL`; uploads `delta/`; after a successful **deploy** moves `deployed/<environment>` |
| `rollback.yml` (`Rollback`) | manual | `rollback.sh` | Moves `deployed/<env>` back to the good commit; creates branch `revert/<env>-<run>` and opens a PR against `master` labelled `rollback` |
| `gearset-callback.yml` (`Gearset callback`) | Gearset webhook via `repository_dispatch` | none | Moves `deployed/partial` or `deployed/uat` on a successful deploy; summary for a successful Production validation; opens an issue labelled `deployment-failure` on failure |

## Quick matrix

| Script | Git commits/pushes | Org metadata | GitHub PRs/issues | Gearset |
|--------|-------------------|--------------|-------------------|---------|
| `create-pr.sh` | commit + push feature branch | reads (retrieve) | creates PR | triggers PR validation indirectly |
| `sf-delta.sh` | no | no | no | no |
| `sf-deploy.sh` | no | validate: check-only; deploy/quick: writes | no | no |
| `gearset-run.sh` | no | indirectly, via the CI job | no | starts a run |
| `rollback.sh` | checks out a commit locally | writes (unless validate-only), incl. deletions | no | no |
