# Session history

Date: 2026-09-18
Working directory: `C:\Users\PRANAV\Salesforce-Devops` (empty at the start, not a git repository)
Assistant: Claude Code (Claude Fable 5.1)

## 1. Request

The user, acting as the owner of a Salesforce DevOps setup, asked for a branching strategy and CI/CD pipeline design plus its automation. Their setup:

- Environments: Partial sandbox, UAT, Production.
- One GitHub repository; `master` represents Production.
- Gearset deploys `master` to Production.
- An existing GitHub Actions workflow validates and deploys pull-request changes to the Partial sandbox.

Deliverables requested:

1. An automated PR-creation script (Bash, Python or GitHub CLI) that accepts specific Salesforce metadata, commits it to a feature branch and opens a PR against a target branch.
2. Automatic deployment to UAT once a PR is merged into `master`, before or concurrently with the Gearset production deployment.
3. A critique of the current branching strategy and a more feasible, industry-standard alternative if the current logic introduces risk.
4. Step-by-step GitHub Actions YAML, details on triggering Gearset via API or webhooks or an `sf` CLI equivalent, and error handling and rollback guidance.
5. Option A: direct implementation of Feature -> Partial -> master -> UAT -> Prod. Option B: the refined architecture with setup steps.

## 2. Research performed before writing

The assistant verified external facts rather than relying on memory:

- **Gearset Automation API** (docs.gearset.com, "Getting started with the Gearset Automation API"): endpoints `GET .../continuous-integration-jobs/{id}/status`, `POST .../continuous-integration-jobs/{id}/run-requests` (body `{}`, returns `RunRequestId`), `GET .../run-requests/{RunRequestId}` (returns `State`, `RunId`, start and end times). Header `Authorization: token <API token>`. Requires an Automation Platform licence.
- **Gearset outgoing webhooks**: standard payload (`job.name`, `run.status` in `Succeeded|Failed|Error`, `run.type`, timestamps) and the `X-Gearset-Event: ci_job_run` header; custom payloads support `${SOURCE_COMMIT_ID}`; webhooks can fire on selected events.
- **Gearset inbound trigger**: one GitHub webhook per repository, pooled across CI jobs, matched on push event and branch.
- **sfdx-git-delta v6**: flags `--from`, `--to`, `--output-dir`, `--generate-delta`, `--merge-base`, `--ignore-file`, `--ignore-destructive-file`; output layout `package/package.xml` and `destructiveChanges/destructiveChanges.xml` plus wrapper `package.xml`; recommended `sf project deploy start -x ... --post-destructive-changes ...`.

## 3. Design decisions

- **Recommended Option B**: one long-lived branch per org (`develop` -> Partial, `uat` -> UAT, `master` -> Production), promotion by PR between branches validated against the next org, hotfixes from `master` with back-merges. Option A kept but hardened.
- **Critique of the current flow** (recorded in `docs/01-critique-and-recommendation.md`): UAT sits after the production decision; no production validation before merge; Partial is the union of all open PRs; a delta based on the push "before" sha silently drops a failed deployment's changes; no selective release; undefined rollback; no hotfix path.
- **Deployment markers**: a `deployed/<env>` git tag moved only after a successful deployment is the base of the next delta, fixing the dropped-changes problem.
- **Gearset in three modes**: self-trigger on push (`gearset-auto`), started by GitHub Actions through the Automation API after UAT and a manual approval (`gearset`), and Gearset calling back through outgoing webhooks relayed to `repository_dispatch`. An `sf` CLI engine is available for every environment.
- **GitHub Environments**: `partial`, `uat`, `production-validate` (check-only, no approvals so PR validation is not blocked) and `production` (required reviewers).
- **Safety**: one deployment per org at a time; destructive changes for fields, objects, profiles, permission sets and flows excluded by `.sgdignore-destructive`; validation with `RunLocalTests` for UAT and Production, `NoTestRun` for Partial by default.
- **Scripts in Bash** (Git Bash on the user's Windows machine) rather than Python, so the same files run locally and on Ubuntu runners.

## 4. Files created

| Path | Purpose |
|------|---------|
| `README.md` | Overview, layout, quick start |
| `docs/01-critique-and-recommendation.md` | Critique, Option A hardened, Option B recommendation, diagrams, decision |
| `docs/02-gearset-integration.md` | The three Gearset integration modes with endpoints, headers, payloads and setup |
| `docs/03-error-handling-and-rollback.md` | Failure surfacing, failure matrix, three rollback mechanisms, what cannot be rolled back |
| `docs/04-setup-guide.md` | Auth URLs, environments, secrets, variables, branch protection, migration, first-run checklist |
| `docs/05-scripts-reference.md` | Per-script purpose and side effects (added in this session's second request) |
| `docs/SESSION-HISTORY.md` | This file |
| `scripts/create-pr.sh` | Commit metadata to a feature branch and open a PR |
| `scripts/sf-delta.sh` | sfdx-git-delta wrapper with fallbacks and summaries |
| `scripts/sf-deploy.sh` | Validate / deploy / quick-deploy with parsed failures |
| `scripts/gearset-run.sh` | Start a Gearset CI job via API and wait |
| `scripts/promote-pr.sh` | Open or refresh promotion and back-merge PRs |
| `scripts/rollback.sh` | Build and deploy the reverse delta |
| `.github/workflows/_sf-deploy.yml` | Reusable workflow: auth, delta, validate/deploy, artifact, deployment marker |
| `.github/workflows/pr-validate.yml` | PR gate for both options |
| `.github/workflows/deploy-option-a.yml` | master -> UAT -> approval -> Production |
| `.github/workflows/deploy-option-b.yml` | develop/uat/master -> matching org -> promotion PR |
| `.github/workflows/promote.yml` | Manual promotion / back-merge PRs |
| `.github/workflows/rollback.yml` | Reverse-delta rollback plus re-align PR |
| `.github/workflows/gearset-callback.yml` | Handles Gearset webhook events |
| `sfdx-project.json`, `.forceignore`, `.sgdignore`, `.sgdignore-destructive`, `.gitignore` | Project configuration |
| `.github/CODEOWNERS`, `.github/pull_request_template.md` | Review ownership and PR checklist |

## 5. Verification performed

- First attempt to write the five scripts through one Bash heredoc command failed with a shell parse error before anything was written; the files were then written individually with the editor tool.
- `bash -n` passed for all six scripts.
- PyYAML was installed for the user and all seven workflow files parsed; job names were listed.
- `create-pr.sh`: `--help`, missing title, retrieve without a source org, and `promote-pr.sh` with a disallowed branch pair all produced the intended errors. The protected-branch check could not be reached because `gh` is not installed on this machine.
- `sf-deploy.sh` was run against a stub `sf` executable (jq 1.8.2 downloaded to the scratchpad):
  - Failed validation: the command was `sf project deploy validate --manifest ... --test-level RunLocalTests --target-org target --wait 90 --json`; the component failure with line number, the Apex test failure and the coverage warning all appeared as annotations and in the step summary; outputs `status=Failed`, `job_id=0AfXX000000001`.
  - Destructive-only success: the command used the wrapper `destructiveChanges/package.xml` as manifest with `--post-destructive-changes` and `--ignore-warnings`; outputs `status=Succeeded`.

## 6. Not verified

- No live run against the user's Salesforce orgs, GitHub repository or Gearset account.
- Whether the user's Gearset tier allows custom headers on outgoing webhooks (a relay is described as the fallback).
- Exact flags of the installed Salesforce Code Analyzer version in the advisory scan job.
- `gh` behaviour of `create-pr.sh` end to end.

## 7. Second request

The user asked to save this session's history to a file and to generate a file explaining the use of each script and the changes each script makes. Result: this file and `docs/05-scripts-reference.md`, both linked from `README.md`.

## 8. Suggested next steps

1. `git init`, commit, push to the GitHub repository.
2. Follow `docs/04-setup-guide.md` sections 4.2 to 4.5, then 4.6 (Option B) or 4.7 (Option A).
3. Run the first-run checklist in section 4.9.

## 9. Third request: drop Option B, align with the real Gearset setup

The user clarified the actual environment and asked for changes:

- The organisation does not use Option B. Remove it and update the scripts accordingly.
- Gearset CI jobs exist today for the Partial sandbox only: they validate PRs and deploy after a PR is merged to `master`.
- The same is needed for the UAT sandbox, plus a **validate-only** (no deploy) CI job for Production.
- The repository uses the Salesforce DX (SFDX) source format folder structure.
- Update all documentation to match.

### Changes made

| Action | Files |
|--------|-------|
| Deleted | `.github/workflows/deploy-option-b.yml`, `.github/workflows/promote.yml`, `.github/workflows/deploy-option-a.yml`, `scripts/promote-pr.sh` |
| Added | `.github/workflows/deploy-on-merge.yml`: on push to `master`, runs Partial deploy, UAT deploy and Production validation in order through the Gearset Automation API (`DEPLOY_ENGINE=gearset-api`) or the Salesforce CLI (`DEPLOY_ENGINE=sf`); inert in the default `gearset-auto` mode where Gearset's own webhook triggers the jobs |
| Rewritten | `.github/workflows/pr-validate.yml` ("PR checks"): no branch mapping; builds the delta artifact, flags destructive changes, runs static analysis, posts one PR comment, optional Salesforce CLI validation via `PR_SF_VALIDATE_ENV`. Org validation itself is left to Gearset's PR validation on the three CI jobs |
| Rewritten | `.github/workflows/gearset-callback.yml`: maps the three job names (`GEARSET_PARTIAL_JOB_NAME`, `GEARSET_UAT_JOB_NAME`, `GEARSET_PROD_VALIDATE_JOB_NAME`); moves `deployed/partial` or `deployed/uat` on a successful deploy, summary only for the Production validation, issue on failure |
| Edited | `.github/workflows/rollback.yml`: revert PR always targets `master`; `CI_PAT` replaces `PROMOTION_PAT`; header explains Gearset rollback is preferred for Production |
| Edited | `.github/workflows/_sf-deploy.yml`: header comment |
| Edited | `scripts/create-pr.sh`: default target `master`, protected-branch guard reduced to `master`/`main`, examples updated. `sf-delta.sh`, `sf-deploy.sh`, `gearset-run.sh`, `rollback.sh` unchanged |
| Edited | `.github/pull_request_template.md`: removed promotion and back-merge items, added the three Gearset validations |
| Rewritten | `README.md`, `docs/01` to `docs/05` for the single-branch, three-CI-job model, SFDX source format, manual Production release with the `deployed/production` tag |

### Verification

- `bash -n` passed for the five remaining scripts: `create-pr.sh`, `gearset-run.sh`, `rollback.sh`, `sf-delta.sh`, `sf-deploy.sh`.
- All five remaining workflows parsed as YAML: `_sf-deploy.yml` (job `run`), `deploy-on-merge.yml` (jobs `partial-gearset`, `uat-gearset`, `production-validate-gearset`, `partial-sf`, `uat-sf`, `production-validate-sf`), `gearset-callback.yml` (`handle`), `pr-validate.yml` (`delta`, `code-scan`, `sf-validate`, `comment`), `rollback.yml` (`rollback`).
- A search across all `.md`, `.yml` and `.sh` files for "Option B", `develop`, `promote-pr`, `PROMOTION_PAT` and `deploy-option` found no stale references (the history file itself excluded).

### Reported to the user

- The pipeline now has one `master` branch in SFDX source format, three Gearset CI jobs (Partial and UAT validate PRs and deploy on merge; Production validates PRs and is validate-only on merge), and a manual Production release from Gearset recorded by the `deployed/production` tag. `git log deployed/production..master` lists pending changes.
- `deploy-on-merge.yml` is inert in the default `gearset-auto` mode; `gearset-api` runs the three jobs in order and stops at the first failure; `sf` does the same with the Salesforce CLI.
- `pr-validate.yml` no longer validates against orgs (Gearset does); it shows the delta, flags deletions, runs static analysis and can add an optional CLI validation.
- Two items to confirm in Gearset during setup: the exact label of the validation-only option on a CI job, and whether the plan allows custom headers on outgoing webhooks (a relay is documented as the fallback).

### Current file set after this request

```
README.md
docs/01-critique-and-recommendation.md   target flow, what it fixes, seven residual risks with containment
docs/02-gearset-integration.md           three CI jobs, manual Production release, webhook and API modes
docs/03-error-handling-and-rollback.md   failure matrix, three rollback mechanisms
docs/04-setup-guide.md                   Gearset jobs, secrets, variables, environments, branch protection, tags, checklist
docs/05-scripts-reference.md             per-script side effects, workflow table
docs/SESSION-HISTORY.md
scripts/create-pr.sh  sf-delta.sh  sf-deploy.sh  gearset-run.sh  rollback.sh
.github/workflows/pr-validate.yml  deploy-on-merge.yml  _sf-deploy.yml  rollback.yml  gearset-callback.yml
.github/CODEOWNERS  .github/pull_request_template.md
sfdx-project.json  .forceignore  .sgdignore  .sgdignore-destructive  .gitignore
```

## 10. Fourth request

The user asked to record the previous exchange in this session history. Section 9 was completed with the verification results, the points reported to the user and the current file set; this section was added. No other files changed.
