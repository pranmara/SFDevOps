# 2. Gearset configuration and integration

## 2.1 The three CI jobs

All three jobs share the same source: the GitHub repository, branch `master`, SFDX source format. Gearset detects `sfdx-project.json` and reads `force-app/`; no conversion to metadata format is needed.

| Setting | `master -> Partial` (existing) | `master -> UAT` (new) | `master -> Production (validate only)` (new) |
|---------|-------------------------------|-----------------------|----------------------------------------------|
| Source | GitHub, `master` | GitHub, `master` | GitHub, `master` |
| Target org | Partial sandbox | UAT sandbox | Production |
| Job type | Deployment | Deployment | **Validation only** (check-only; nothing is saved in Production) |
| Validate pull requests | On | On | On |
| Trigger | On every commit (webhook), or manual/API when `DEPLOY_ENGINE=gearset-api` | same | same |
| Apex tests | None or local tests (fast feedback) | Run local tests | Run local tests |
| Delete removed components | Optional | Optional | Off (a validate-only job never deletes, keep it off anyway) |
| Metadata filter | Exclude the same items as `.forceignore`: org settings, named credentials, remote site settings, connected apps, `Admin` profile | same | same |
| Outgoing webhooks | success and failure webhooks (2.4) | same | same |

Create the two new jobs from the Continuous integration dashboard with **Add new job**: pick the source, pick the target org, set the job type, enable PR validation, choose the test level, set the metadata filter, add the webhooks, save. Then use **Copy job ID** on the job card; the IDs go into GitHub secrets if you use the API mode.

**PR validation.** With "validate pull requests" on, Gearset validates every non-draft PR targeting `master` against the job's org and posts a status check on the PR. After the first PR shows the three checks, add them to the `master` branch protection as required checks. Draft PRs are skipped, so open PRs as drafts while iterating.

**What "validation only" means.** Gearset runs a Metadata API check-only deployment with the selected test level. Apex tests execute in Production, coverage is computed, but no metadata is written. A green run means the current `master` can be deployed to Production as is.

## 2.2 Deploying to Production (manual, after UAT sign-off)

1. Confirm the latest `master -> Production (validate only)` run is green for the commit you intend to release. If it is older than a day, run the job again (job card > Run now).
2. Gearset > **Compare and deploy**: source = GitHub `master`, target = Production. Use the same metadata filter as the CI job.
3. Review the diff. Deploy **everything** the comparison shows, not a hand-picked subset (see risk 2 in the critique).
4. After success, record what is live:

   ```bash
   git fetch origin
   git tag -f deployed/production origin/master   # or the exact sha you deployed
   git push -f origin refs/tags/deployed/production
   ```

   `git log --oneline deployed/production..master` is now the list of changes still waiting for a release.

## 2.3 Mode 1: Gearset triggers itself (`DEPLOY_ENGINE=gearset-auto`, default)

Gearset installs one webhook per repository. On every push to `master` it runs the three jobs. GitHub Actions does nothing for deployments in this mode; `deploy-on-merge.yml` is inert and can be deleted. To get the results back into GitHub, use the outgoing webhooks in 2.4.

## 2.4 Gearset calls GitHub back (outgoing webhooks, recommended with Mode 1)

In each CI job > **Outgoing webhooks**, add two webhooks:

| Field | Value |
|-------|-------|
| URL | `https://api.github.com/repos/<owner>/<repo>/dispatches` |
| Method | POST |
| Headers | `Accept: application/vnd.github+json` and `Authorization: Bearer <fine-grained PAT with Contents and Issues read/write on this repo>` |
| Event | Webhook 1: run succeeded. Webhook 2: run failed or errored |
| Custom payload (success) | `{"event_type":"gearset-ci-succeeded","client_payload":{"job":"<exact CI job name>","commit":"${SOURCE_COMMIT_ID}"}}` |
| Custom payload (failure) | `{"event_type":"gearset-ci-failed","client_payload":{"job":"<exact CI job name>","commit":"${SOURCE_COMMIT_ID}"}}` |

`${SOURCE_COMMIT_ID}` is replaced by Gearset with the commit that was deployed. Set the repository variables `GEARSET_PARTIAL_JOB_NAME`, `GEARSET_UAT_JOB_NAME` and `GEARSET_PROD_VALIDATE_JOB_NAME` to the exact job names so `gearset-callback.yml` can map a job to an environment. It then moves `deployed/partial` or `deployed/uat` on success, writes a summary for a successful Production validation, and opens an issue labelled `deployment-failure` on any failure.

If your Gearset plan does not allow custom headers on outgoing webhooks, put a small relay (Cloudflare Worker, Azure Function, Zapier) in front that receives Gearset's standard payload and forwards it to GitHub with the token. The standard payload is:

```json
{ "job": { "name": "master -> UAT" },
  "run": { "status": "Succeeded", "type": "Deployment",
           "start_date_utc": "2026-09-18T16:37:41Z", "end_date_utc": "2026-09-18T16:39:06Z" } }
```

with the header `X-Gearset-Event: ci_job_run`. `run.type` is `Validation` for the Production job.

## 2.5 Mode 2: GitHub Actions starts the jobs through the Automation API (`DEPLOY_ENGINE=gearset-api`)

Use this when you want the three jobs to run **in order** (Partial, then UAT, then the Production validation) and to stop at the first failure, with everything visible in one GitHub Actions run. Requires a Gearset Automation Platform licence.

`scripts/gearset-run.sh` does, for one job:

| Step | Call |
|------|------|
| Wait until the job is idle | `GET https://api.gearset.com/public/automation/continuous-integration-jobs/{jobId}/status` -> `{"State":"Idle"}` |
| Start a run | `POST https://api.gearset.com/public/automation/continuous-integration-jobs/{jobId}/run-requests` with body `{}` -> `{"RunRequestId":"..."}` |
| Poll until terminal | `GET .../run-requests/{runRequestId}` -> `{"State":"Succeeded","RunId":"...","StartDateTime":"...","EndDateTime":"..."}` |

Every request carries `Authorization: token <API token>` and `Content-Type: application/json`. The script retries on 429 and 5xx with back-off, fails fast on 401/403/404 and times out after `GEARSET_TIMEOUT_MIN` (default 90 minutes).

Setup:

1. Gearset > Settings > **API access** > create a token. Store it as the repository secret `GEARSET_API_TOKEN`.
2. Copy the three job IDs into `GEARSET_PARTIAL_CI_JOB_ID`, `GEARSET_UAT_CI_JOB_ID`, `GEARSET_PROD_VALIDATE_CI_JOB_ID`.
3. In each CI job, **turn off the automatic on-commit trigger**. If you leave it on, every merge runs each job twice.
4. Set the repository variable `DEPLOY_ENGINE=gearset-api`.

PR validation is unaffected: Gearset still validates PRs from its own webhook.

Test a job by hand:

```bash
GEARSET_API_TOKEN=... GEARSET_CI_JOB_ID=... bash scripts/gearset-run.sh
```

## 2.6 Mode 3: Salesforce CLI instead of Gearset (`DEPLOY_ENGINE=sf`)

`deploy-on-merge.yml` then deploys the incremental delta to Partial and UAT and validates the cumulative `deployed/production..master` difference against Production with `sf project deploy validate`. Needs the `SFDX_AUTH_URL` secrets described in the setup guide. Gearset's deployment history and rollback button are not involved; the `Rollback` workflow and the `delta-*` artifacts replace them. Production deployment stays manual (Gearset), or run `sf project deploy quick --job-id <validation job id>` within 10 days of the validation.

## 2.7 Keep Gearset and git in agreement

- Mirror `.forceignore` in the CI jobs' metadata filters, and the other way round.
- Do not enable "delete removed components" on the Production job; review deletions in the `PR checks` comment instead.
- Gearset's PR validation and the optional Salesforce CLI validation (`PR_SF_VALIDATE_ENV`) do the same thing; run only one of them per org or every PR waits for both.
