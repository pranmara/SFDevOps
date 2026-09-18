#!/usr/bin/env bash
# =============================================================================
# gearset-run.sh - Start a Gearset CI job through the Gearset Automation API
#                  and wait for it to finish.
#
# Env vars
#   GEARSET_API_TOKEN     (required) API token from Gearset > Settings > API access
#   GEARSET_CI_JOB_ID     (required) "Copy job ID" on the CI job's card
#   GEARSET_TIMEOUT_MIN   max minutes to wait for the run (default 90)
#   GEARSET_POLL_SEC      polling interval in seconds (default 30)
#   GEARSET_WAIT_IDLE_MIN minutes to wait for a job that is already running (default 30)
#
# Endpoints (Gearset Automation API):
#   GET  /public/automation/continuous-integration-jobs/{id}/status            -> {"State":"Idle"}
#   POST /public/automation/continuous-integration-jobs/{id}/run-requests      -> {"RunRequestId":"..."}
#   GET  /public/automation/continuous-integration-jobs/{id}/run-requests/{r}  -> {"State":"Succeeded","RunId":...}
#
# Exit codes: 0 succeeded, 1 failed/error, 2 timed out, 3 configuration error
# =============================================================================
set -Eeuo pipefail

: "${GEARSET_API_TOKEN:?GEARSET_API_TOKEN is required}"
: "${GEARSET_CI_JOB_ID:?GEARSET_CI_JOB_ID is required}"
TIMEOUT_MIN="${GEARSET_TIMEOUT_MIN:-90}"
POLL_SEC="${GEARSET_POLL_SEC:-30}"
WAIT_IDLE_MIN="${GEARSET_WAIT_IDLE_MIN:-30}"

BASE="https://api.gearset.com/public/automation/continuous-integration-jobs/${GEARSET_CI_JOB_ID}"
HDR=(-H "Authorization: token ${GEARSET_API_TOKEN}" -H "Content-Type: application/json" -H "Accept: application/json")

emit()    { echo "$1"; if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; fi; }

# curl with retries for transient errors and Gearset's 429 rate limiting.
# Prints the response body; returns non-zero on hard failures.
gs_curl() {
  local attempt=0 out code body
  while :; do
    attempt=$((attempt + 1))
    out="$(curl -sS -w '\n%{http_code}' "${HDR[@]}" "$@")" || out="
000"
    code="${out##*
}"
    body="${out%
*}"
    case "$code" in
      2*) echo "$body"; return 0 ;;
      401|403) echo "::error::Gearset API auth failed ($code). Check GEARSET_API_TOKEN and that the token's team owns the CI job." >&2; return 3 ;;
      404) echo "::error::Gearset CI job not found ($code). Check GEARSET_CI_JOB_ID." >&2; return 3 ;;
      429|5*|000)
        if [[ $attempt -ge 5 ]]; then echo "::error::Gearset API error $code after $attempt attempts: $body" >&2; return 1; fi
        sleep $((attempt * 10)) ;;
      *) echo "::error::Unexpected Gearset API response $code: $body" >&2; return 1 ;;
    esac
  done
}

# 1. Wait for the job to be idle (another run may be in progress)
echo "Checking CI job state..."
deadline=$(( $(date +%s) + WAIT_IDLE_MIN * 60 ))
while :; do
  state="$(gs_curl "$BASE/status" | jq -r '.State // "Unknown"')"
  echo "  job state: $state"
  if [[ "$state" == "Idle" ]]; then break; fi
  if (( $(date +%s) > deadline )); then echo "::error::CI job still '$state' after ${WAIT_IDLE_MIN}m"; exit 2; fi
  sleep "$POLL_SEC"
done

# 2. Request a run
echo "Requesting a run of CI job $GEARSET_CI_JOB_ID"
RUN_REQ="$(gs_curl -X POST -d '{}' "$BASE/run-requests" | jq -r '.RunRequestId // empty')"
[[ -n "$RUN_REQ" ]] || { echo "::error::No RunRequestId returned"; exit 1; }
echo "  run request id: $RUN_REQ"
emit "run_request_id=$RUN_REQ"

# 3. Poll until the run reaches a terminal state
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while :; do
  resp="$(gs_curl "$BASE/run-requests/$RUN_REQ")"
  state="$(echo "$resp" | jq -r '.State // "Unknown"')"
  run_id="$(echo "$resp" | jq -r '.RunId // empty')"
  echo "  $(date -u +%H:%M:%S) state=$state${run_id:+ run=$run_id}"
  case "$state" in
    Succeeded)
      emit "state=$state"; emit "run_id=$run_id"
      echo "::notice::Gearset CI job succeeded (run $run_id)"
      summary "### :white_check_mark: Gearset CI job succeeded" "" \
              "- Run request: \`$RUN_REQ\`" "- Run id: \`$run_id\`" \
              "- Started: $(echo "$resp" | jq -r .StartDateTime)  Ended: $(echo "$resp" | jq -r .EndDateTime)"
      exit 0 ;;
    Failed|Error|Errored|Cancelled|Canceled)
      emit "state=$state"; emit "run_id=$run_id"
      echo "::error::Gearset CI job ended with state '$state' (run ${run_id:-n/a}). Open the run in Gearset > Continuous integration > job history for component/test errors."
      summary "### :x: Gearset CI job $state" "" "- Run request: \`$RUN_REQ\`" "- Run id: \`${run_id:-n/a}\`" \
              "- See the run in the Gearset CI dashboard for the deployment report."
      exit 1 ;;
  esac
  if (( $(date +%s) > deadline )); then
    emit "state=Timeout"
    echo "::error::Timed out after ${TIMEOUT_MIN}m waiting for Gearset run $RUN_REQ (last state: $state). The run may still complete in Gearset."
    exit 2
  fi
  sleep "$POLL_SEC"
done
