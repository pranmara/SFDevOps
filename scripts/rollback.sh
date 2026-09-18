#!/usr/bin/env bash
# =============================================================================
# rollback.sh - Roll an org back from a "bad" commit to a "good" commit by
#               deploying the reverse delta (good state + destructive changes
#               for anything the bad commit added).
#
# Usage: rollback.sh --org ALIAS --good <ref> --bad <ref> [--test-level LEVEL] [--validate-only]
#
# Afterwards, ALWAYS realign git with the org (git revert / revert PR), or the
# next delta deployment will re-apply the bad change. rollback.yml does this.
# =============================================================================
set -Eeuo pipefail
ORG=""; GOOD=""; BAD="HEAD"; TEST_LEVEL="RunLocalTests"; MODE="deploy"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --good) GOOD="$2"; shift 2 ;;
    --bad) BAD="$2"; shift 2 ;;
    --test-level) TEST_LEVEL="$2"; shift 2 ;;
    --validate-only) MODE="validate"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ORG" && -n "$GOOD" ]] || { echo "--org and --good are required" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"

git cat-file -e "${GOOD}^{commit}" || { echo "good ref '$GOOD' not found" >&2; exit 2; }
git cat-file -e "${BAD}^{commit}"  || { echo "bad ref '$BAD' not found" >&2; exit 2; }

echo "Rolling back $ORG: $(git rev-parse --short "$BAD") -> $(git rev-parse --short "$GOOD")"
# Work from the GOOD tree so generated source files reflect the state we want.
git checkout -q "$GOOD"

# Reverse delta: from=bad, to=good. Components added by 'bad' show up in destructiveChanges.
"$HERE/sf-delta.sh" --from "$BAD" --to "$GOOD" --out rollback-delta

if grep -q "<types>" rollback-delta/destructiveChanges/destructiveChanges.xml 2>/dev/null; then
  echo "::warning::This rollback DELETES components that were added by the bad commit. Review rollback-delta/destructiveChanges/destructiveChanges.xml."
fi

"$HERE/sf-deploy.sh" --org "$ORG" --mode "$MODE" --delta rollback-delta --test-level "$TEST_LEVEL"
