# 3. Error handling and rollback

## 3.1 How failures surface

| Where | What happens | What you see |
|-------|--------------|--------------|
| Gearset PR validation | The status check on the PR goes red; the PR cannot be merged while it is a required check. | Red check on the PR, details in Gearset |
| `create-pr.sh` | `set -Eeuo pipefail` plus an `ERR` trap. A branch created by the script with nothing committed is deleted; a committed branch is kept and the exact retry command is printed. | Red `Failed at line N` with the failing command |
| `PR checks` workflow | Delta build failures fail the `Delta package` job. Static analysis is advisory (`continue-on-error`). Deletions produce a warning annotation and a callout in the PR comment. | PR comment, annotations, artifacts |
| Gearset CI job after merge (Mode 1) | Gearset shows the failed run; with the outgoing webhooks, `gearset-callback.yml` opens an issue labelled `deployment-failure`. | Issue in the repo, Gearset run history |
| Gearset CI job after merge (Mode 2, API) | `gearset-run.sh` exits non-zero; the following job (UAT, then Production validation) is skipped. 401/403/404 fail immediately naming the secret to check; 429/5xx retry five times; timeouts exit 2 and say the run may still finish in Gearset. | Failed workflow run with summary |
| Salesforce CLI (Mode 3 or `PR_SF_VALIDATE_ENV`) | `sf-deploy.sh` parses the JSON result. Component failures, Apex test failures and coverage warnings become `::error::` annotations and a table in the job summary. A job still running after `--wait` prints the `sf project deploy resume` command. | Annotations, job summary, PR comment |
| Concurrency | One `Deploy on merge` run at a time, never cancelled mid-flight. The Salesforce CLI path also serialises per org. | Queued runs wait |
| Missing secret | Explicit error naming the environment and secret, before touching the org. | Fails at the auth step |

Every Salesforce CLI run uploads the package it used (`delta-*` artifacts), so a failure can be replayed locally:

```bash
sf project deploy start --manifest delta/package/package.xml \
  --post-destructive-changes delta/destructiveChanges/destructiveChanges.xml \
  --test-level RunLocalTests --target-org uat --dry-run
```

## 3.2 The failure matrix

| Failure | First response | Then |
|---------|----------------|------|
| A Gearset PR validation fails (Partial, UAT or Production) | Nothing was deployed. Fix the branch and push; the validations re-run. | Nothing else |
| Partial or UAT deploy fails after merge | `master` is ahead of that sandbox. Gearset compares the whole branch with the org on the next run, so nothing is lost. Fix forward with a new PR, or revert the merge commit with a PR. | The next merge re-deploys everything missing |
| Production validate-only fails after merge | Nothing was deployed. `master` is **not** releasable. Fix forward before the next release, or revert. Do not deploy to Production until the job is green again. | Re-run the job after the fix |
| Production deployment fails in Gearset (manual) | Metadata API deployments are atomic: nothing partial was saved. Read the failure in Gearset. It usually means Production changed since the last validation; re-run the validate-only job. | Fix forward; deploy again |
| Deployed to Production, behaviour is wrong | Decide between fix-forward and rollback (3.3). Prefer fix-forward when the fix is small and understood. | |
| Salesforce CLI deployment timed out (`--wait`) | It is still running in Salesforce. `sf project deploy resume --job-id <id>` or Setup > Deployment Status. Do not re-run until it finishes; the concurrency group queues it anyway. | |
| `deployed/<env>` tag is wrong (manual deployment, Gearset rollback) | Move it: `git tag -f deployed/uat <sha> && git push -f origin refs/tags/deployed/uat`. | |
| Two PRs merge within a minute | Gearset (Mode 1) runs the jobs for the newest commit; the earlier one is covered because Gearset compares the whole branch. Mode 2 and 3 queue through the concurrency group. | |

## 3.3 Rollback

Three mechanisms, in order of preference.

### a) Revert in git, deploy forward (preferred for Partial and UAT)

Revert the merge commit through a PR: `git revert -m 1 <merge-sha>` on a branch, open the PR, let Gearset validate it, merge. Partial and UAT are rolled back by the normal deploy on merge, and Production's validate-only job confirms the reverted `master` is still deployable. Git stays the source of truth.

### b) Gearset's rollback (preferred for Production)

Gearset > Deployment history > the production deployment > **Roll back**. Gearset redeploys the snapshot it took before the deployment. Immediately afterwards:

1. Move the marker: `git tag -f deployed/production <previous good sha> && git push -f origin refs/tags/deployed/production`.
2. Open the revert PR from (a), or the next Production deployment re-applies the change.

### c) The `Rollback` workflow (Salesforce CLI, any environment)

Actions > **Rollback** > environment, `good_ref` (the previous position of `deployed/<env>`, visible in the tag's push history), leave `bad_ref` empty, `validate_only=true`.

It builds the reverse delta with sfdx-git-delta (`--from bad --to good`): every changed component is restored to its good version, and components the bad commit added are deleted through `destructiveChanges.xml`. Run once with `validate_only=true`, read the summary and the `rollback-delta` artifact, then run again with `validate_only=false`. Production asks for the environment approval. On success it moves the tag back and opens a PR against `master` restoring the same files. **Merge that PR.** Because Partial and UAT both follow `master`, merging it also rolls the other sandbox back through the normal deploy on merge.

Use (c) for Production only when Gearset is unavailable or `DEPLOY_ENGINE=sf`.

### What no rollback can undo

The Metadata API is not a database transaction. These need a plan before the deployment, not after:

- **Deleted custom fields and objects** lose their data (fields sit in the recycle bin for 15 days, but automations that referenced them already broke).
- **Picklist values** that were deactivated or renamed on records.
- **Flow versions**: deploying an older version does not deactivate the newer one; activation state is org-side.
- **Profile and permission set removals** already enforced on users, and **Setup-side settings** excluded by `.forceignore` (they were never in git).
- **Data migrations, custom settings values, scheduled Apex jobs** and anything done by the manual steps listed in the PR.

`.sgdignore-destructive` excludes fields, objects, profiles, permission sets and flows from automatic deletions in the Salesforce CLI path; keep "delete removed components" off on the Gearset Production job for the same reason.

## 3.4 Pre-deployment safety nets that avoid rollbacks

- Three Gearset PR validations, including Production with local tests, before any merge.
- The validate-only job re-checks the cumulative `master` against Production after every merge.
- The `PR checks` comment shows the exact components and deletions a PR carries.
- Production deployment is a deliberate manual step after UAT sign-off.
- Static analysis on changed files (advisory until the baseline is clean, then remove `continue-on-error`).
