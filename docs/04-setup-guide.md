# 4. Setup guide

Estimated time: two hours, most of it waiting for the first validations.

## 4.1 Prerequisites

- The repository is in SFDX source format (`sfdx-project.json` at the root, metadata under `force-app/main/default`). The `sfdx-project.json`, `.forceignore`, `.sgdignore` and `.sgdignore-destructive` in this repo are starting points; merge them with what you already have.
- Salesforce CLI `sf` >= 2.x and `gh` (GitHub CLI, authenticated) on developer machines; Git Bash on Windows.
- Gearset: permission to create CI jobs; Automation API access only for `DEPLOY_ENGINE=gearset-api`.
- For the Salesforce CLI paths only (`DEPLOY_ENGINE=sf`, `PR_SF_VALIDATE_ENV`, `Rollback`): an **integration user** per org (Partial, UAT, Production) with an API-only permission set including *Modify Metadata Through Metadata API Functions*, *Author Apex*, *API Enabled*.

## 4.2 Gearset CI jobs

Follow `docs/02-gearset-integration.md` section 2.1:

1. Keep the existing `master -> Partial` job. Confirm "validate pull requests" is on.
2. Create `master -> UAT`: deployment job, PR validation on, run local tests.
3. Create `master -> Production (validate only)`: validation-only job, PR validation on, run local tests, "delete removed components" off.
4. Give the three jobs the same metadata filter as `.forceignore`.
5. Optional but recommended: add the two outgoing webhooks per job (section 2.4).
6. Copy each job's ID if you plan to use the API mode.

## 4.3 GitHub secrets and variables

Repository secrets (Settings > Secrets and variables > Actions):

| Secret | Needed for | Purpose |
|--------|-----------|---------|
| `GEARSET_API_TOKEN` | `gearset-api` | Gearset Automation API token |
| `GEARSET_PARTIAL_CI_JOB_ID` | `gearset-api` | Job ID of `master -> Partial` |
| `GEARSET_UAT_CI_JOB_ID` | `gearset-api` | Job ID of `master -> UAT` |
| `GEARSET_PROD_VALIDATE_CI_JOB_ID` | `gearset-api` | Job ID of `master -> Production (validate only)` |
| `CI_PAT` | `Rollback` | Fine-grained PAT (Contents and Pull requests read/write) so the revert PR triggers `PR checks`. PRs opened with the default token do not trigger workflows |

Repository variables:

| Variable | Values | Default | Meaning |
|----------|--------|---------|---------|
| `DEPLOY_ENGINE` | `gearset-auto` / `gearset-api` / `sf` | `gearset-auto` | Who runs Partial deploy, UAT deploy and Production validation after a merge |
| `PR_SF_VALIDATE_ENV` | empty / `partial` / `uat` / `production-validate` | empty | Extra Salesforce CLI check-only validation on PRs. Leave empty; Gearset already validates PRs |
| `PARTIAL_TEST_LEVEL` | Apex test level | `NoTestRun` | Salesforce CLI path only |
| `UAT_TEST_LEVEL` | | `RunLocalTests` | Salesforce CLI path only |
| `PROD_TEST_LEVEL` | | `RunLocalTests` | Salesforce CLI path and `PR_SF_VALIDATE_ENV` |
| `GEARSET_PARTIAL_JOB_NAME`, `GEARSET_UAT_JOB_NAME`, `GEARSET_PROD_VALIDATE_JOB_NAME` | exact job names | unset | Lets `gearset-callback.yml` map webhook events to environments |
| `SF_CLI_VERSION`, `SGD_VERSION` | npm versions | `latest` | Pin once the pipeline is stable |

## 4.4 GitHub Environments (Salesforce CLI paths only)

Skip this section if `DEPLOY_ENGINE=gearset-auto`, `PR_SF_VALIDATE_ENV` is empty and you will use Gearset's rollback for Production. The `Rollback` workflow for Partial and UAT needs the first two.

Get an auth URL per org on your machine:

```bash
sf org login web --alias partial --instance-url https://test.salesforce.com
sf org display --target-org partial --verbose --json | jq -r .result.sfdxAuthUrl
```

The value looks like `force://PlatformCLI::<refresh token>@<instance>.my.salesforce.com`. Treat it as a password. Prefer JWT (`sf org login jwt`) if your security team asks for it; swap the *Authenticate* step in `_sf-deploy.yml` and `rollback.yml`.

Settings > Environments:

| Environment | Secret `SFDX_AUTH_URL` | Protection |
|-------------|------------------------|------------|
| `partial` | Partial auth URL | none |
| `uat` | UAT auth URL | none |
| `production-validate` | Production auth URL | none. Check-only use |
| `production` | Production auth URL | **Required reviewers**. Used only by `Rollback` and never for routine deployments |

## 4.5 Branch protection for `master` (Settings > Branches or Rulesets)

- Require a pull request before merging, at least one approval, dismiss stale approvals.
- Required status checks: the three Gearset PR validation checks (they appear after the first PR) and `Delta package` from `PR checks`.
- Block force pushes. Merge commits or squash are both fine with a single branch.
- Require review from CODEOWNERS for the paths in `.github/CODEOWNERS`.

Labels used by the automation: `rollback`, `deployment-failure` (created automatically if missing).

## 4.6 Deployment markers

The tags record what is live in each org. Bootstrap them at a moment when the orgs equal `master`:

```bash
git fetch origin
git tag -f deployed/partial    origin/master
git tag -f deployed/uat        origin/master
git tag -f deployed/production origin/master
git push -f origin refs/tags/deployed/partial refs/tags/deployed/uat refs/tags/deployed/production
```

If UAT is behind `master` today, point `deployed/uat` at the last commit that is in UAT. With `DEPLOY_ENGINE=sf` the next run deploys everything since; with Gearset, the first CI run deploys the full difference anyway.

Who moves the tags afterwards:

| Tag | Moved by |
|-----|----------|
| `deployed/partial`, `deployed/uat` | `deploy-on-merge.yml` (API or sf mode), or `gearset-callback.yml` (webhook mode), or `Rollback` |
| `deployed/production` | You, after each manual Production deployment (section 2.2), or `Rollback` |

## 4.7 First-run checklist

1. Push the repo with the workflows; confirm `PR checks`, `Deploy on merge`, `Rollback` and `Gearset callback` appear under Actions. Set `DEPLOY_ENGINE` (or leave the default).
2. Open a trivial PR (a comment in an Apex class). Expect: three Gearset validation checks, the `Delta package` job, a PR comment with the artifact link.
3. Make the four checks required on `master`.
4. Merge the PR. Expect: Gearset deploys Partial and UAT and validates Production. With webhooks, `deployed/partial` and `deployed/uat` move and the callback run shows the Production validation summary. With `gearset-api`, one `Deploy on merge` run shows the three steps in order.
5. Deploy to Production from Gearset, then move `deployed/production`.
6. Run `Rollback` for Partial with `validate_only=true` against the commit before step 4 to confirm the reverse delta builds correctly.

## 4.8 Day-to-day commands

```bash
# Developer: commit local changes and open a PR against master
scripts/create-pr.sh -m "ACC-123 account scoring" \
  -p force-app/main/default/classes/AccountScoring.cls \
  -p force-app/main/default/classes/AccountScoringTest.cls

# Admin: pull a Flow and a field built in Partial into a PR
scripts/create-pr.sh -m "Lead routing flow" -o partial -r "Flow:Lead_Router" -r "CustomField:Lead.Region__c" -l flow

# Release manager: what is waiting for a Production release
git fetch origin && git log --oneline deployed/production..origin/master

# After a manual Production deployment
git tag -f deployed/production origin/master && git push -f origin refs/tags/deployed/production

# Roll UAT back to a commit (check-only first)
gh workflow run rollback.yml -f environment=uat -f good_ref=abc1234 -f validate_only=true

# Re-run the three steps for the current master (API or sf mode)
gh workflow run deploy-on-merge.yml
```
