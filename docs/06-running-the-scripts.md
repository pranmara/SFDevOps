# 6. Running the scripts: what can break them, and how they were tested

## 6.1 Environment requirements that break scripts when missing

| Requirement | Symptom when missing | Fix |
|-------------|----------------------|-----|
| **Git Bash** (Windows) or bash 4+ (macOS ships bash 3.2) | `mapfile: command not found`, `syntax error near unexpected token` | Run from Git Bash, not PowerShell or cmd. On macOS `brew install bash` and run with `bash scripts/...`. |
| **jq** on PATH | `jq: command not found` in `create-pr.sh` (retrieve mode), `sf-deploy.sh`, `gearset-run.sh` | Windows: `winget install jqlang.jq` (jq is not bundled with Git Bash). Ubuntu GitHub runners have it preinstalled. |
| **gh** authenticated | `GitHub CLI is not authenticated` | `gh auth login`. Organisations with SAML SSO also need `gh auth refresh -s repo` and SSO authorisation of the token. |
| **sf** CLI with the **sfdx-git-delta** plugin | `sf: command not found`, `Warning: sgd is not a sf command` | `npm install -g @salesforce/cli` then `echo y \| sf plugins install sfdx-git-delta`. The workflows install both themselves. |
| Authenticated org alias | `No authorization information found for partial` | `sf org login web --alias partial --instance-url https://test.salesforce.com` |
| **LF line endings** | `$'\r': command not found`, `bad interpreter` | `.gitattributes` enforces LF. If a checkout predates it: `git add --renormalize . && git checkout -- .` or `dos2unix scripts/*.sh`. |
| **Full git history** | sfdx-git-delta errors on unknown refs, empty deltas | Do not use shallow clones (`--depth`). The workflows use `fetch-depth: 0`. |
| **Repository root as working directory** | `.sgdignore` not applied, `delta/` and `rollback-delta/` created in the wrong place | Always run `scripts/<name>.sh` from the repository root. |

## 6.2 Per-script pitfalls

### `create-pr.sh`

- **Target branch.** The default is origin's default branch (`main` in this repository). The old `master` default would have failed here. Pass `-t` or set `DEFAULT_TARGET` to override. If detection fails (`Could not detect origin's default branch`), run `git remote set-head origin --auto` once.
- **Unrelated local changes travel with you.** The script creates the feature branch from `origin/<target>` with `git switch -c`, which carries uncommitted changes across. Only the paths you pass are staged, so unrelated edits stay uncommitted on the new branch. If they conflict with the target branch, branch creation fails with `Could not create branch`; commit or stash them first.
- **Retrieve mode without `--path` stages everything under `force-app/`**, including unrelated uncommitted edits. Stash them first, or pass explicit `--path` values alongside `--retrieve`.
- **Retrieve overwrites local files** with the org's version (`--ignore-conflicts`). Local, uncommitted edits to the same components are lost.
- **Only changed companions are added.** A `-meta.xml` file is committed only if it is new or modified, which is correct behaviour; do not expect it in every commit.
- **Branch names** are derived from the title (`feature/<slug>`, 50 characters). Two PRs with the same title reuse the same branch; pass `-b` for a distinct one. `master`/`main` are refused as branch names.
- **Draft PRs are not validated by Gearset.** Use `--draft` while iterating, then mark ready to trigger the three validations.
- **On failure** the script now cleans up (returns to your branch and deletes an empty feature branch) for every error, including its own validation errors. This was fixed during testing, see 6.4.

### `sf-delta.sh`

- **`--from` must exist.** An all-zero sha (first push to a branch) or a commit lost to a force push falls back to `<to>~1`, which covers only the last commit. After a force push to `main`, run the deployment with `from_ref` set explicitly.
- **Renames** appear as a deletion plus an addition. The deletion is subject to `.sgdignore-destructive`.
- **Unknown metadata types** produce warnings from sfdx-git-delta and are left out of `package.xml`. Add them with `--additional-metadata-registry` if you use uncommon types.
- **`has_changes=false` is a valid outcome** (docs-only PRs); the workflows skip deployment rather than fail.

### `sf-deploy.sh`

- **`--wait` (default 90 minutes)** is a client-side wait. After it expires, the deployment continues in Salesforce. Do not re-run; use `sf project deploy resume --job-id <id>`.
- **`validate` with `NoTestRun`** runs `sf project deploy start --dry-run` and produces no quick-deployable job id. Only validations with tests can be quick-deployed, and only within 10 days and if nothing changed in the org since.
- **`RunSpecifiedTests` requires `--tests`**; the script exits 2 otherwise.
- **Production needs 75 % org-wide coverage** with `RunLocalTests`. A green sandbox validation does not guarantee Production coverage.
- **Deletions are atomic with the rest.** A component in `destructiveChanges.xml` that something else still references fails the whole deployment; nothing is saved.
- **Auth URL expiry.** `SFDX_AUTH_URL` embeds a refresh token. It stops working when the integration user's password is reset, the token is revoked, or the connected app is removed. Regenerate the secret when you see `expired access/refresh token`.

### `gearset-run.sh`

- Requires a Gearset **Automation Platform** licence and an API token whose user can access the CI job; otherwise `401`/`403` (exit 3).
- **Double deployments.** If the CI job's on-commit trigger is still on, the API run duplicates the webhook run. Turn the trigger off when `DEPLOY_ENGINE=gearset-api`.
- A job that is already running makes the script wait up to `GEARSET_WAIT_IDLE_MIN` (30) minutes, then exit 2.
- The API returns only the run state, not the failure details. Read those in Gearset's run history.
- Default timeout is 90 minutes (`GEARSET_TIMEOUT_MIN`); the Production validation job in `deploy-on-merge.yml` uses 120.

### `rollback.sh`

- **Leaves you on a detached HEAD** at the good commit when run locally; `git switch -` returns. In a workflow the runner is discarded.
- **Deletes components** the bad commit added, unless `.sgdignore-destructive` filters them. Always run with `--validate-only` first and read `rollback-delta/destructiveChanges/destructiveChanges.xml`.
- **Git and org diverge after a rollback** until the revert PR that `rollback.yml` opens is merged, or the tag is moved. The next merge to `main` re-applies the bad change otherwise.
- Cannot undo data changes, Flow activation state, picklist deactivations, or Setup settings excluded from git (see `docs/03`).

## 6.3 Workflow-level pitfalls

- `deploy-on-merge.yml` **does nothing** until `DEPLOY_ENGINE` is set to `gearset-api` or `sf`. In the default `gearset-auto` mode Gearset's own webhook runs the jobs.
- The repository branch is **`main`**; the Gearset CI jobs must watch `main`. The workflows trigger on both `main` and `master`.
- PRs and revert PRs created with the default `GITHUB_TOKEN` **do not trigger workflows**. `rollback.yml` needs the `CI_PAT` secret for its revert PR to get `PR checks`.
- `deployed/<env>` tags must be bootstrapped (`docs/04` section 4.6) before the `sf` engine or the `Rollback` workflow is used; without them the delta falls back to the push's previous commit.
- The `production` GitHub Environment should have required reviewers; the `production-validate` environment must not, or PR validations would wait for approval.
- Static analysis is `continue-on-error`; a red scan never blocks a merge until you remove that line.

## 6.4 How the scripts were tested

`tests/run-tests.sh` is an offline harness. It writes stub `gh`, `sf` and `curl` commands to a temporary directory, puts them first on `PATH`, builds a throwaway git repository with a bare `origin`, and drives every script through its paths. The stubs record the exact arguments they were called with, so the assertions check the real commands the scripts would run.

```bash
bash tests/run-tests.sh        # needs bash 4+, git, jq; takes about 30 seconds
```

What the 64 checks cover:

| Script | Checked |
|--------|---------|
| `create-pr.sh` | branch creation from origin's default branch, slug naming, companion `-meta.xml` staging, push, `gh pr create` arguments (base, head, title, label), reuse of an existing PR, retrieve mode (`sf project retrieve start --metadata ... --target-org ...`) and commit of retrieved files, "no changes" abort, missing path abort, cleanup of the empty branch and return to the original branch after any failure, `--dry-run` not pushing, protected-branch refusal, unknown target branch error |
| `sf-delta.sh` | added component in `package.xml`, deleted component in `destructiveChanges.xml`, changed source copied, all-zero sha fallback with warning, identical refs give `has_changes=false`, missing `--from` exits 2 |
| `sf-deploy.sh` | exact `sf project deploy start` command with manifest, post-destructive changes and `--ignore-warnings`; `validate` + `NoTestRun` becomes `start --dry-run`; `validate` + tests becomes `deploy validate`; `RunSpecifiedTests` guard and `--tests` expansion; `quick` guard and command; empty delta skipped with exit 0; failure JSON parsed into component, test and coverage annotations; non-JSON CLI output reported with exit 1 |
| `gearset-run.sh` | idle check, `POST .../run-requests`, polling through `Running` to `Succeeded` with outputs, `Failed` exits 1, `401` exits 3, missing token reported |
| `rollback.sh` | reverse delta built `--from <bad> --to <good>`, `--validate-only` runs a check-only deployment, component added by the bad commit lands in `destructiveChanges.xml`, component deleted by the bad commit is restored, deletion warning shown, working tree at the good commit, unknown ref exits 2 |

Bugs the harness found and that were fixed:

1. `create-pr.sh` defaulted to `master`; this repository uses `main`. It now detects origin's default branch.
2. `create-pr.sh` skipped its cleanup when it failed through its own `die` calls (an `ERR` trap does not fire on `exit`), leaving you on an empty feature branch. Cleanup moved to an `EXIT` trap.
3. On Windows, jq emits CRLF. `mapfile` in `create-pr.sh` kept the carriage return and git rejected the package directory path (`pathspec 'force-app?' did not match`). The `read` loops in `sf-deploy.sh` had the same exposure. Both now strip carriage returns.

What the harness does **not** cover, and what to test for real before relying on the pipeline:

- Real `sf` behaviour: retrieve of specific metadata, sfdx-git-delta's actual `package.xml` for your metadata types, Metadata API errors. Run `scripts/sf-delta.sh --from HEAD~1 --to HEAD` and `scripts/sf-deploy.sh --org partial --mode validate --test-level NoTestRun` against the Partial sandbox.
- Real `gh` behaviour: `scripts/create-pr.sh --dry-run ...` first, then a real run on a throwaway branch.
- The Gearset API with your token and job IDs: `GEARSET_API_TOKEN=... GEARSET_CI_JOB_ID=... scripts/gearset-run.sh` against a sandbox job.
- The workflows themselves: only their YAML was parsed. Follow the first-run checklist in `docs/04` section 4.7.
