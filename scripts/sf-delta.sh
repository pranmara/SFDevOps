#!/usr/bin/env bash
# =============================================================================
# sf-delta.sh - Build an incremental deployment package between two git refs
#               with sfdx-git-delta (sgd).
#
# Usage: sf-delta.sh --from <ref> --to <ref> [--out DIR] [--merge-base]
#
# Prints KEY=VALUE lines and, inside GitHub Actions, appends them to
# $GITHUB_OUTPUT: has_changes, package, destructive, out_dir
# =============================================================================
set -Eeuo pipefail

FROM=""; TO="HEAD"; OUT="delta"; MERGE_BASE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --merge-base) MERGE_BASE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$FROM" ]] || { echo "--from is required" >&2; exit 2; }

emit() { echo "$1"; if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }

# GitHub sends an all-zero 'before' sha on the first push to a branch, and a
# force-push can leave 'before' unreachable. Fall back to the previous commit.
if [[ "$FROM" =~ ^0+$ ]] || ! git cat-file -e "${FROM}^{commit}" 2>/dev/null; then
  echo "::warning::from ref '$FROM' is not available; falling back to ${TO}~1"
  FROM="${TO}~1"
fi

rm -rf "$OUT"; mkdir -p "$OUT"
args=(--from "$FROM" --to "$TO" --output-dir "$OUT" --generate-delta)
if $MERGE_BASE; then args+=(--merge-base); fi
if [[ -f .sgdignore ]]; then args+=(--ignore-file .sgdignore); fi
if [[ -f .sgdignore-destructive ]]; then args+=(--ignore-destructive-file .sgdignore-destructive); fi

echo "Computing delta: $(git rev-parse --short "$FROM")..$(git rev-parse --short "$TO")"
sf sgd source delta "${args[@]}"

PKG="$OUT/package/package.xml"
DES="$OUT/destructiveChanges/destructiveChanges.xml"
has=false
if grep -q "<types>" "$PKG" 2>/dev/null; then has=true; fi
if grep -q "<types>" "$DES" 2>/dev/null; then has=true; fi

echo "----- package.xml -----";            cat "$PKG" 2>/dev/null || echo "(none)"
echo "----- destructiveChanges.xml -----"; cat "$DES" 2>/dev/null || echo "(none)"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Delta $(git rev-parse --short "$FROM")..$(git rev-parse --short "$TO")"
    echo '<details><summary>package.xml</summary>'; echo; echo '```xml'; cat "$PKG" 2>/dev/null; echo '```'; echo '</details>'
    if grep -q "<types>" "$DES" 2>/dev/null; then
      echo '<details open><summary>:warning: destructiveChanges.xml</summary>'; echo; echo '```xml'; cat "$DES"; echo '```'; echo '</details>'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

emit "has_changes=$has"
emit "package=$PKG"
emit "destructive=$DES"
emit "out_dir=$OUT"
