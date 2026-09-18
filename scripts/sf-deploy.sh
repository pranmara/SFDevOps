#!/usr/bin/env bash
# =============================================================================
# sf-deploy.sh - Validate / deploy an sgd delta with the Salesforce CLI, with
#                structured error reporting for GitHub Actions.
#
# Usage:
#   sf-deploy.sh --org ALIAS --mode validate|deploy|quick [--delta DIR]
#                [--test-level LEVEL] [--tests "A,B"] [--wait MIN] [--job-id ID]
#
# Modes
#   validate  check-only. With RunLocalTests/RunAllTestsInOrg/RunSpecifiedTests
#             this uses `sf project deploy validate`, whose job id can be
#             quick-deployed within 10 days. With NoTestRun it falls back to
#             `sf project deploy start --dry-run`.
#   deploy    real deployment.
#   quick     `sf project deploy quick --job-id` of a previous validation.
#
# Outputs (stdout + $GITHUB_OUTPUT): status, job_id
# =============================================================================
set -Eeuo pipefail

ORG=""; MODE="deploy"; DELTA="delta"; TEST_LEVEL="RunLocalTests"; TESTS=""; WAIT=90; JOB_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --delta) DELTA="$2"; shift 2 ;;
    --test-level) TEST_LEVEL="$2"; shift 2 ;;
    --tests) TESTS="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    --job-id) JOB_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ORG" ]] || { echo "--org is required" >&2; exit 2; }

emit()    { echo "$1"; if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; fi; }

PKG="$DELTA/package/package.xml"
DES="$DELTA/destructiveChanges/destructiveChanges.xml"
DES_WRAPPER="$DELTA/destructiveChanges/package.xml"

# ---- Build the command ------------------------------------------------------
cmd=(sf project deploy)
case "$MODE" in
  quick)
    [[ -n "$JOB_ID" ]] || { echo "--job-id is required for quick mode" >&2; exit 2; }
    cmd+=(quick --job-id "$JOB_ID")
    ;;
  validate|deploy)
    if [[ "$MODE" == validate && "$TEST_LEVEL" != NoTestRun ]]; then
      cmd+=(validate)
    else
      cmd+=(start)
      if [[ "$MODE" == validate ]]; then cmd+=(--dry-run); fi
    fi
    has_pkg=false; has_des=false
    if grep -q "<types>" "$PKG" 2>/dev/null; then has_pkg=true; fi
    if grep -q "<types>" "$DES" 2>/dev/null; then has_des=true; fi
    if ! $has_pkg && ! $has_des; then
      echo "Nothing to deploy (empty delta)."; emit "status=Skipped"; emit "job_id="; exit 0
    fi
    if $has_pkg; then cmd+=(--manifest "$PKG"); else cmd+=(--manifest "$DES_WRAPPER"); fi
    if $has_des; then cmd+=(--post-destructive-changes "$DES" --ignore-warnings); fi
    cmd+=(--test-level "$TEST_LEVEL")
    if [[ "$TEST_LEVEL" == RunSpecifiedTests ]]; then
      [[ -n "$TESTS" ]] || { echo "--tests is required with RunSpecifiedTests" >&2; exit 2; }
      IFS=',' read -ra tarr <<< "$TESTS"; for t in "${tarr[@]}"; do cmd+=(--tests "$t"); done
    fi
    ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
cmd+=(--target-org "$ORG" --wait "$WAIT" --json)

echo "Running: ${cmd[*]}"
set +e
RAW="$("${cmd[@]}" 2>&1)"
RC=$?
set -e

# ---- Parse the result -------------------------------------------------------
if ! echo "$RAW" | jq -e . >/dev/null 2>&1; then
  echo "::error::Salesforce CLI did not return JSON (exit $RC). Raw output follows."
  echo "$RAW"
  emit "status=Error"; emit "job_id="
  exit 1
fi

STATUS="$(echo "$RAW" | jq -r '.result.status // .status // "Unknown"')"
JOB="$(echo "$RAW" | jq -r '.result.id // empty')"
emit "status=$STATUS"
emit "job_id=$JOB"

if [[ $RC -eq 0 && "$STATUS" =~ ^(Succeeded|SucceededPartial)$ ]]; then
  N_DEP="$(echo "$RAW" | jq -r '.result.numberComponentsDeployed // 0')"
  N_TST="$(echo "$RAW" | jq -r '.result.numberTestsCompleted // 0')"
  echo "::notice::$MODE against $ORG succeeded (job $JOB): $N_DEP components, $N_TST tests"
  summary "### :white_check_mark: $MODE -> \`$ORG\` succeeded" "" "- Job id: \`$JOB\`" "- Components: $N_DEP" "- Tests run: $N_TST"
  exit 0
fi

# ---- Failure reporting: component errors, test failures, coverage ----------
echo "::error::$MODE against $ORG failed with status '$STATUS' (exit $RC, job ${JOB:-n/a})"
MSG="$(echo "$RAW" | jq -r '.message // empty')"
if [[ -n "$MSG" ]]; then echo "::error::$MSG"; fi

summary "### :x: $MODE -> \`$ORG\` failed (status: $STATUS, job: \`${JOB:-n/a}\`)" ""

echo "$RAW" | jq -r '
  (.result.details.componentFailures // []) | if type=="array" then . else [.] end
  | .[] | "COMPONENT|\(.componentType // "?")|\(.fullName // "?")|\(.problem // "?")|\(.lineNumber // "")"' 2>/dev/null \
  | tr -d '\r' | while IFS='|' read -r _ ctype cname problem line; do
      echo "::error::[$ctype] $cname${line:+ (line $line)}: $problem"
      summary "- :red_circle: **$ctype** \`$cname\`${line:+ line $line}: $problem"
    done

echo "$RAW" | jq -r '
  (.result.details.runTestResult.failures // []) | if type=="array" then . else [.] end
  | .[] | "TEST|\(.name // "?")|\(.methodName // "?")|\(.message // "?")"' 2>/dev/null \
  | tr -d '\r' | while IFS='|' read -r _ cls meth msg; do
      echo "::error::Test failed $cls.$meth: $msg"
      summary "- :test_tube: **$cls.$meth**: $msg"
    done

echo "$RAW" | jq -r '
  (.result.details.runTestResult.codeCoverageWarnings // []) | if type=="array" then . else [.] end
  | .[] | "\(.name // "org") \(.message // "")"' 2>/dev/null \
  | tr -d '\r' | while read -r line; do
      if [[ -n "$line" ]]; then echo "::warning::Coverage: $line"; summary "- :warning: Coverage: $line"; fi
    done

if [[ "$STATUS" =~ ^(InProgress|Pending|Queued)$ ]]; then
  echo "::warning::The deployment is still running in Salesforce. Resume with: sf project deploy resume --job-id $JOB --target-org $ORG"
  summary "" "Deployment still running: \`sf project deploy resume --job-id $JOB\`"
fi
exit 1
