#!/usr/bin/env bash
# =============================================================================
# create-pr.sh - Commit specific Salesforce metadata to a feature branch and
#                open a GitHub pull request against a target branch.
#
# Works in Git Bash on Windows, macOS and Linux. Requires: git, gh (logged in),
# and sf only when --retrieve / --manifest is used.
#
# Examples
#   # 1. Commit files you already changed locally and open a PR against master
#   scripts/create-pr.sh -m "Add AccountService" \
#       -p force-app/main/default/classes/AccountService.cls \
#       -p force-app/main/default/classes/AccountServiceTest.cls
#
#   # 2. Pull metadata straight out of an org (e.g. an admin's Flow built in
#   #    the Partial sandbox), commit it and open a PR
#   scripts/create-pr.sh -m "Lead routing flow" -o partial \
#       -r "Flow:Lead_Router" -r "CustomField:Lead.Region__c" -l flow
#
#   # 3. Retrieve using a package.xml (SFDX source format is written to force-app/)
#   scripts/create-pr.sh -m "Q3 release fixes" -o partial -x manifest/fixes.xml
#
# Once the PR is open, the Gearset CI jobs (Partial, UAT, Production
# validate-only) validate it and report status checks on the PR.
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Defaults (override via flags or environment)
# --------------------------------------------------------------------------- #
TARGET="${DEFAULT_TARGET:-master}"       # base branch for the PR
SOURCE_ORG="${SF_SOURCE_ORG:-}"           # sf alias to retrieve from
BRANCH=""
TITLE=""
BODY=""
BODY_FILE=""
DRAFT=false
DRY_RUN=false
PATHS=()
RETRIEVE=()
MANIFEST=""
LABELS=()
REVIEWERS=()

usage() {
  cat <<USAGE
Usage: scripts/create-pr.sh -m "Title" [-t master] [-p PATH ...] [-r Type:Name ...] [-o ORG]

Options
  -m, --title TEXT        PR title and commit subject (required)
  -t, --target BRANCH     Base branch for the PR (default: ${TARGET})
  -b, --branch NAME       Feature branch name (default: feature/<slug-of-title>)
  -p, --path PATH         Metadata file/dir to include (repeatable). *-meta.xml
                          companions are added automatically.
  -r, --retrieve SPEC     Retrieve "Type:Name" from --source-org first (repeatable)
  -x, --manifest FILE     Retrieve everything listed in a package.xml first
  -o, --source-org ALIAS  sf org alias/username used for --retrieve/--manifest
  -d, --body TEXT         PR body (or use --body-file)
      --body-file FILE    PR body from a file
  -l, --label LABEL       PR label (repeatable)
      --reviewer USER     GitHub reviewer (repeatable)
      --draft             Open the PR as a draft
      --dry-run           Do everything except push and create the PR
  -h, --help
USAGE
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Arg parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--title)      TITLE="$2"; shift 2 ;;
    -t|--target)     TARGET="$2"; shift 2 ;;
    -b|--branch)     BRANCH="$2"; shift 2 ;;
    -p|--path)       PATHS+=("$2"); shift 2 ;;
    -r|--retrieve)   RETRIEVE+=("$2"); shift 2 ;;
    -x|--manifest)   MANIFEST="$2"; shift 2 ;;
    -o|--source-org) SOURCE_ORG="$2"; shift 2 ;;
    -d|--body)       BODY="$2"; shift 2 ;;
    --body-file)     BODY_FILE="$2"; shift 2 ;;
    -l|--label)      LABELS+=("$2"); shift 2 ;;
    --reviewer)      REVIEWERS+=("$2"); shift 2 ;;
    --draft)         DRAFT=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ -n "$TITLE" ]] || die "--title is required"
if [[ ${#PATHS[@]} -eq 0 && ${#RETRIEVE[@]} -eq 0 && -z "$MANIFEST" ]]; then
  die "Nothing to commit: pass at least one --path, --retrieve or --manifest"
fi
if [[ ${#RETRIEVE[@]} -gt 0 || -n "$MANIFEST" ]]; then
  [[ -n "$SOURCE_ORG" ]] || die "--source-org (or SF_SOURCE_ORG) is required when retrieving"
fi

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
for tool in git gh; do command -v "$tool" >/dev/null || die "'$tool' is not installed or not on PATH"; done
if [[ ${#RETRIEVE[@]} -gt 0 || -n "$MANIFEST" ]]; then
  command -v sf >/dev/null || die "'sf' (Salesforce CLI) is required for --retrieve/--manifest"
fi
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository"
cd "$REPO_ROOT"
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Slug the title into a branch name when none is supplied
if [[ -z "$BRANCH" ]]; then
  slug="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-50)"
  BRANCH="feature/${slug}"
fi

# Guard against committing to the long-lived branch by accident
case "$BRANCH" in
  master|main) die "Refusing to commit directly to protected branch '$BRANCH'. Use a feature/* or hotfix/* branch." ;;
esac

# --------------------------------------------------------------------------- #
# Cleanup / error trap: report where we failed and how to recover
# --------------------------------------------------------------------------- #
CREATED_BRANCH=false
COMMITTED=false
on_error() {
  local rc=$? line=$1
  echo
  printf '\033[1;31mFailed\033[0m at line %s (exit %s): %s\n' "$line" "$rc" "$BASH_COMMAND" >&2
  if $CREATED_BRANCH && ! $COMMITTED; then
    warn "Branch '$BRANCH' was created but nothing was committed. Cleaning up."
    git switch -q "$ORIGINAL_BRANCH" 2>/dev/null || true
    git branch -D "$BRANCH" >/dev/null 2>&1 || true
  elif $COMMITTED; then
    warn "Commit exists on '$BRANCH'. To retry the push + PR step run:"
    warn "  git push -u origin $BRANCH && gh pr create --base $TARGET --head $BRANCH --title \"$TITLE\""
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR

# --------------------------------------------------------------------------- #
# 1. Sync the target branch and create / switch to the feature branch
# --------------------------------------------------------------------------- #
log "Fetching origin/$TARGET"
git fetch -q origin "$TARGET" || die "Target branch '$TARGET' does not exist on origin"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  log "Switching to existing branch $BRANCH"
  git switch -q "$BRANCH"
else
  log "Creating branch $BRANCH from origin/$TARGET"
  # 'git switch' carries uncommitted local changes across when they don't conflict,
  # which is exactly what we want for --path usage.
  git switch -q -c "$BRANCH" "origin/$TARGET" \
    || die "Could not create branch. Commit or stash unrelated local changes and retry."
  CREATED_BRANCH=true
fi

# --------------------------------------------------------------------------- #
# 2. Optionally retrieve metadata from an org into the working tree
# --------------------------------------------------------------------------- #
if [[ ${#RETRIEVE[@]} -gt 0 ]]; then
  log "Retrieving ${#RETRIEVE[@]} metadata item(s) from org '$SOURCE_ORG'"
  args=()
  for spec in "${RETRIEVE[@]}"; do args+=(--metadata "$spec"); done
  sf project retrieve start "${args[@]}" --target-org "$SOURCE_ORG" --ignore-conflicts --wait 30
fi
if [[ -n "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"
  log "Retrieving manifest $MANIFEST from org '$SOURCE_ORG'"
  sf project retrieve start --manifest "$MANIFEST" --target-org "$SOURCE_ORG" --ignore-conflicts --wait 30
fi

# --------------------------------------------------------------------------- #
# 3. Stage the metadata
# --------------------------------------------------------------------------- #
if [[ ${#PATHS[@]} -gt 0 ]]; then
  for p in "${PATHS[@]}"; do
    [[ -e "$p" ]] || die "Path does not exist: $p"
    git add -A -- "$p"
    # Add the -meta.xml companion (or the source file, if the companion was passed)
    [[ -f "${p}-meta.xml" ]] && git add -- "${p}-meta.xml"
    [[ "$p" == *-meta.xml && -f "${p%-meta.xml}" ]] && git add -- "${p%-meta.xml}"
  done
else
  # Retrieval mode with no explicit paths: stage everything the retrieve touched
  # inside the package directories declared in sfdx-project.json.
  mapfile -t pkg_dirs < <(jq -r '.packageDirectories[].path' sfdx-project.json 2>/dev/null || echo force-app)
  git add -A -- "${pkg_dirs[@]}"
fi

if git diff --cached --quiet; then
  die "No changes to commit. The metadata is identical to origin/$TARGET."
fi

log "Staged changes:"
git diff --cached --stat

# --------------------------------------------------------------------------- #
# 4. Commit
# --------------------------------------------------------------------------- #
COMMIT_MSG="$TITLE"
if [[ -n "$BODY" ]]; then
  COMMIT_MSG="$COMMIT_MSG

$BODY"
fi
git commit -q -m "$COMMIT_MSG"
COMMITTED=true
log "Committed $(git rev-parse --short HEAD) on $BRANCH"

if $DRY_RUN; then
  warn "--dry-run: skipping push and PR creation. Branch '$BRANCH' is ready locally."
  exit 0
fi

# --------------------------------------------------------------------------- #
# 5. Push and create (or reuse) the PR
# --------------------------------------------------------------------------- #
log "Pushing $BRANCH"
git push -q -u origin "$BRANCH"

existing="$(gh pr list --head "$BRANCH" --base "$TARGET" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
  log "A PR already exists for $BRANCH -> $TARGET: $existing"
  echo "$existing"
  exit 0
fi

pr_args=(--base "$TARGET" --head "$BRANCH" --title "$TITLE")
if   [[ -n "$BODY_FILE" ]]; then pr_args+=(--body-file "$BODY_FILE")
elif [[ -n "$BODY" ]];      then pr_args+=(--body "$BODY")
else
  pr_args+=(--body "Automated PR created by scripts/create-pr.sh

Source org: ${SOURCE_ORG:-local working tree}")
fi
for l in "${LABELS[@]}";    do pr_args+=(--label "$l"); done
for r in "${REVIEWERS[@]}"; do pr_args+=(--reviewer "$r"); done
$DRAFT && pr_args+=(--draft)

log "Creating pull request $BRANCH -> $TARGET"
PR_URL="$(gh pr create "${pr_args[@]}")"
log "Pull request created: $PR_URL"
echo "$PR_URL"
