#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh - offline test harness for the scripts in scripts/.
#
# Uses STUB gh / sf / curl commands (written to a temp dir and put first on
# PATH) that record their arguments and emulate responses, plus a throwaway git
# repository with a bare "origin". Nothing touches GitHub, Salesforce or
# Gearset. Needs: bash 4+, git, jq.
#
#   bash tests/run-tests.sh
#
# Covers create-pr.sh, sf-delta.sh, sf-deploy.sh, gearset-run.sh, rollback.sh:
# success paths, argument validation, cleanup on failure, delta contents,
# deploy command assembly, failure parsing, Gearset API state machine,
# reverse-delta rollback. See docs/06-running-the-scripts.md for what it does
# NOT cover.
# =============================================================================
set -u
command -v jq >/dev/null || { echo "jq is required (Windows: winget install jqlang.jq, Debian/Ubuntu: apt install jq)"; exit 2; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/sfdevops-tests.XXXXXX")"
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH"
export T
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else fail "$3 (expected to find: $2)"; echo "$1" | head -15 | sed 's/^/      | /'; fi; }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then fail "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

# ------------------------------------------------------------------ stubs
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T/gh-args.txt"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list") cat "$T/existing_pr" 2>/dev/null; exit 0 ;;
  "pr create") echo "https://github.com/pranmara/SFDevOps/pull/42"; exit 0 ;;
  *) exit 0 ;;
esac
STUB

cat > "$T/bin/sf" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$T/sf-args.txt"
case "$1 $2 $3" in
  "project retrieve start")
    mkdir -p force-app/main/default/flows
    echo "<Flow><label>Lead Router $(date +%s%N)</label></Flow>" > force-app/main/default/flows/Lead_Router.flow-meta.xml
    exit 0 ;;
  "sgd source delta")
    FROM=""; TO="HEAD"; OUT="./output"
    while [[ $# -gt 0 ]]; do case "$1" in --from) FROM="$2"; shift 2;; --to) TO="$2"; shift 2;; --output-dir) OUT="$2"; shift 2;; *) shift;; esac; done
    mkdir -p "$OUT/package" "$OUT/destructiveChanges"
    ADD=""; DEL=""
    while IFS=$'\t' read -r st f; do
      [[ -z "$f" ]] && continue
      case "$f" in
        *.cls) name="$(basename "$f" .cls)"; type=ApexClass ;;
        *.flow-meta.xml) name="$(basename "$f" .flow-meta.xml)"; type=Flow ;;
        *) continue ;;
      esac
      if [[ "$st" == D ]]; then DEL+="<types><members>$name</members><name>$type</name></types>"
      else ADD+="<types><members>$name</members><name>$type</name></types>"; mkdir -p "$OUT/$(dirname "$f")"; git show "$TO:$f" > "$OUT/$f" 2>/dev/null; fi
    done < <(git diff --name-status "$FROM" "$TO" -- force-app 2>/dev/null)
    echo "<Package>${ADD}<version>62.0</version></Package>" > "$OUT/package/package.xml"
    echo "<Package>${DEL}<version>62.0</version></Package>" > "$OUT/destructiveChanges/destructiveChanges.xml"
    echo "<Package><version>62.0</version></Package>" > "$OUT/destructiveChanges/package.xml"
    exit 0 ;;
  "project deploy validate"|"project deploy start"|"project deploy quick")
    if [[ "${SF_STUB_GARBAGE:-}" == 1 ]]; then echo "ERROR running project deploy start: Connection refused"; exit 1; fi
    if [[ "${SF_STUB_FAIL:-}" == 1 ]]; then
      echo '{"status":1,"message":"Deploy failed.","result":{"id":"0AfBAD","status":"Failed","details":{"componentFailures":[{"componentType":"ApexClass","fullName":"Foo","problem":"Missing semicolon","lineNumber":3}],"runTestResult":{"failures":[{"name":"FooTest","methodName":"t1","message":"boom"}]}}}}'
      exit 1
    fi
    echo '{"status":0,"result":{"id":"0AfOK","status":"Succeeded","numberComponentsDeployed":1,"numberTestsCompleted":3}}'
    exit 0 ;;
  *) exit 0 ;;
esac
STUB

cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
URL=""; METHOD=GET
while [[ $# -gt 0 ]]; do case "$1" in -X) METHOD="$2"; shift 2;; http*) URL="$1"; shift;; -H|-d|-w) shift 2;; *) shift;; esac; done
echo "$METHOD $URL" >> "$T/curl-args.txt"
if [[ "${GEARSET_STUB_401:-}" == 1 ]]; then printf '{"message":"unauthorized"}\n401'; exit 0; fi
case "$URL" in
  */status) printf '{"State":"Idle"}\n200' ;;
  */run-requests) printf '{"RunRequestId":"rr-1"}\n200' ;;
  */run-requests/rr-1)
    n=$(( $(cat "$T/poll" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/poll"
    if [[ $n -lt 2 ]]; then printf '{"State":"Running"}\n200'
    elif [[ "${GEARSET_STUB_FAIL:-}" == 1 ]]; then printf '{"State":"Failed","RunId":"run-9"}\n200'
    else printf '{"State":"Succeeded","RunId":"run-9","StartDateTime":"2026-09-19T10:00:00Z","EndDateTime":"2026-09-19T10:05:00Z"}\n200'; fi ;;
  *) printf 'not found\n404' ;;
esac
STUB
chmod +x "$T/bin/"*

# ------------------------------------------------------------------ fixture repo
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
cd "$T/work"
git config user.name test; git config user.email test@example.com
git switch -q -c main
mkdir -p force-app/main/default/classes
cp "$REPO/sfdx-project.json" .
echo 'public class Foo { }' > force-app/main/default/classes/Foo.cls
echo '<ApexClass><apiVersion>62.0</apiVersion></ApexClass>' > force-app/main/default/classes/Foo.cls-meta.xml
git add -A && git commit -q -m "initial" && git push -q -u origin main
git remote set-head origin main

echo "=== create-pr.sh"
echo 'public class Foo { public static Integer one() { return 1; } }' > force-app/main/default/classes/Foo.cls
echo 'public class Baz { }' > force-app/main/default/classes/Baz.cls
echo '<ApexClass><apiVersion>62.0</apiVersion></ApexClass>' > force-app/main/default/classes/Baz.cls-meta.xml
OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Fix foo" -p force-app/main/default/classes/Foo.cls -p force-app/main/default/classes/Baz.cls -l bug 2>&1)"; RC=$?
assert_eq "$RC" 0 "path mode exits 0"
assert_contains "$OUT" "pull/42" "path mode prints the PR URL"
assert_eq "$(git branch --show-current)" "feature/fix-foo" "branch name derived from title"
assert_contains "$(git show --stat HEAD)" "Baz.cls-meta.xml" "meta.xml companion committed automatically (only .cls was passed)"
assert_contains "$(git ls-remote origin feature/fix-foo)" "feature/fix-foo" "branch pushed to origin"
assert_contains "$(cat "$T/gh-args.txt")" "pr create --base main --head feature/fix-foo --title Fix foo" "target auto-detected as origin default branch (main)"
assert_contains "$(cat "$T/gh-args.txt")" "--label bug" "label passed to gh"

echo "https://github.com/pranmara/SFDevOps/pull/7" > "$T/existing_pr"; : > "$T/gh-args.txt"
echo 'public class Foo { public static Integer two() { return 2; } }' > force-app/main/default/classes/Foo.cls
OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Fix foo" -p force-app/main/default/classes/Foo.cls 2>&1)"; RC=$?
assert_eq "$RC" 0 "second run on same branch exits 0"
assert_contains "$OUT" "already exists" "existing PR reused"
assert_not_contains "$(cat "$T/gh-args.txt")" "pr create" "no duplicate PR created"
rm -f "$T/existing_pr"

git switch -q main
OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Lead flow" -o partial -r "Flow:Lead_Router" 2>&1)"; RC=$?
assert_eq "$RC" 0 "retrieve mode exits 0"
assert_contains "$(cat "$T/sf-args.txt")" "project retrieve start --metadata Flow:Lead_Router --target-org partial" "sf retrieve called with the spec and org"
assert_contains "$(git show --stat HEAD)" "Lead_Router.flow-meta.xml" "retrieved flow committed"

git switch -q main
OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Nothing here" -p force-app/main/default/classes/Foo.cls 2>&1)"; RC=$?
assert_eq "$RC" 1 "no-change run exits 1"
assert_contains "$OUT" "No changes to commit" "no-change message"
assert_eq "$(git branch --show-current)" "main" "returned to original branch after failure"
assert_eq "$(git branch --list feature/nothing-here | wc -l | tr -d ' ')" "0" "empty feature branch cleaned up"

OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Bad path" -p force-app/nope.cls 2>&1)"; RC=$?
assert_eq "$RC" 1 "missing path exits 1"
assert_contains "$OUT" "Path does not exist" "missing path message"
assert_eq "$(git branch --show-current)" "main" "cleanup after missing path"

echo 'public class Foo { public static Integer three() { return 3; } }' > force-app/main/default/classes/Foo.cls
OUT="$(bash "$REPO/scripts/create-pr.sh" -m "Dry run" -p force-app/main/default/classes/Foo.cls --dry-run 2>&1)"; RC=$?
assert_eq "$RC" 0 "dry-run exits 0"
assert_eq "$(git ls-remote origin feature/dry-run | wc -l | tr -d ' ')" "0" "dry-run does not push"
git switch -q main

OUT="$(bash "$REPO/scripts/create-pr.sh" -m "x" -p force-app -b main 2>&1)"; RC=$?
assert_contains "$OUT" "Refusing to commit directly to protected branch" "protected branch guard"

OUT="$(bash "$REPO/scripts/create-pr.sh" -m "x" -p force-app -t nope 2>&1)"; RC=$?
assert_contains "$OUT" "does not exist on origin" "unknown target branch reported"

echo "=== sf-delta.sh"
git switch -q main
git merge -q --no-ff feature/fix-foo -m "merge fix" 2>/dev/null
echo 'public class Bar { }' > force-app/main/default/classes/Bar.cls
echo '<ApexClass/>' > force-app/main/default/classes/Bar.cls-meta.xml
git rm -q force-app/main/default/classes/Foo.cls force-app/main/default/classes/Foo.cls-meta.xml
git add -A && git commit -q -m "add Bar, delete Foo"
OUT="$(bash "$REPO/scripts/sf-delta.sh" --from HEAD~1 --to HEAD --out "$T/d1" 2>&1)"
assert_contains "$OUT" "has_changes=true" "delta detects changes"
assert_contains "$(cat "$T/d1/package/package.xml")" "<members>Bar</members>" "package.xml lists added class"
assert_contains "$(cat "$T/d1/destructiveChanges/destructiveChanges.xml")" "<members>Foo</members>" "destructiveChanges lists deleted class"
[[ -f "$T/d1/force-app/main/default/classes/Bar.cls" ]] && ok "changed source copied to delta" || fail "changed source not copied"
OUT="$(bash "$REPO/scripts/sf-delta.sh" --from 0000000000000000000000000000000000000000 --to HEAD --out "$T/d2" 2>&1)"
assert_contains "$OUT" "::warning::from ref" "all-zero sha falls back with a warning"
assert_contains "$OUT" "has_changes=true" "fallback delta still built"
OUT="$(bash "$REPO/scripts/sf-delta.sh" --from HEAD --to HEAD --out "$T/d3" 2>&1)"
assert_contains "$OUT" "has_changes=false" "identical refs -> no changes"
OUT="$(bash "$REPO/scripts/sf-delta.sh" --to HEAD 2>&1)"; RC=$?
assert_eq "$RC" 2 "missing --from exits 2"

echo "=== sf-deploy.sh"
cd "$T"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d1" 2>&1)"; RC=$?
assert_eq "$RC" 0 "deploy success exits 0"
assert_contains "$(tail -1 "$T/sf-args.txt")" "project deploy start --manifest $T/d1/package/package.xml --post-destructive-changes $T/d1/destructiveChanges/destructiveChanges.xml --ignore-warnings --test-level RunLocalTests --target-org uat --wait 90 --json" "deploy command assembled with manifest + destructive"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org partial --mode validate --delta "$T/d1" --test-level NoTestRun 2>&1)"
assert_contains "$(tail -1 "$T/sf-args.txt")" "project deploy start --dry-run" "validate + NoTestRun uses start --dry-run"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode validate --delta "$T/d1" --test-level RunLocalTests 2>&1)"
assert_contains "$(tail -1 "$T/sf-args.txt")" "project deploy validate" "validate + tests uses deploy validate"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d1" --test-level RunSpecifiedTests 2>&1)"; RC=$?
assert_eq "$RC" 2 "RunSpecifiedTests without --tests exits 2"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d1" --test-level RunSpecifiedTests --tests "FooTest,BarTest" 2>&1)"
assert_contains "$(tail -1 "$T/sf-args.txt")" "--tests FooTest --tests BarTest" "tests list expanded"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode quick 2>&1)"; RC=$?
assert_eq "$RC" 2 "quick without --job-id exits 2"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode quick --job-id 0Af123 2>&1)"; RC=$?
assert_contains "$(tail -1 "$T/sf-args.txt")" "project deploy quick --job-id 0Af123" "quick deploy command"
OUT="$(bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d3" 2>&1)"; RC=$?
assert_eq "$RC" 0 "empty delta exits 0"
assert_contains "$OUT" "status=Skipped" "empty delta skipped"
OUT="$(SF_STUB_FAIL=1 bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d1" 2>&1)"; RC=$?
assert_eq "$RC" 1 "failed deploy exits 1"
assert_contains "$OUT" "::error::[ApexClass] Foo (line 3): Missing semicolon" "component failure annotated"
assert_contains "$OUT" "::error::Test failed FooTest.t1: boom" "test failure annotated"
OUT="$(SF_STUB_GARBAGE=1 bash "$REPO/scripts/sf-deploy.sh" --org uat --mode deploy --delta "$T/d1" 2>&1)"; RC=$?
assert_eq "$RC" 1 "non-JSON CLI output exits 1"
assert_contains "$OUT" "did not return JSON" "non-JSON output reported"

echo "=== gearset-run.sh"
rm -f "$T/poll"
OUT="$(GEARSET_API_TOKEN=tok GEARSET_CI_JOB_ID=job1 GEARSET_POLL_SEC=0 bash "$REPO/scripts/gearset-run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 0 "gearset success exits 0"
assert_contains "$OUT" "run_request_id=rr-1" "run request id emitted"
assert_contains "$OUT" "state=Succeeded" "final state emitted"
assert_contains "$(cat "$T/curl-args.txt")" "POST https://api.gearset.com/public/automation/continuous-integration-jobs/job1/run-requests" "POST to run-requests"
rm -f "$T/poll"
OUT="$(GEARSET_STUB_FAIL=1 GEARSET_API_TOKEN=tok GEARSET_CI_JOB_ID=job1 GEARSET_POLL_SEC=0 bash "$REPO/scripts/gearset-run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 1 "gearset failed run exits 1"
assert_contains "$OUT" "ended with state 'Failed'" "failure reported"
OUT="$(GEARSET_STUB_401=1 GEARSET_API_TOKEN=bad GEARSET_CI_JOB_ID=job1 bash "$REPO/scripts/gearset-run.sh" 2>&1)"; RC=$?
assert_eq "$RC" 3 "401 exits 3"
assert_contains "$OUT" "auth failed" "auth failure reported"
OUT="$(GEARSET_CI_JOB_ID=job1 bash "$REPO/scripts/gearset-run.sh" 2>&1)"; RC=$?
assert_contains "$OUT" "GEARSET_API_TOKEN is required" "missing token reported"

echo "=== rollback.sh"
cd "$T/work"
GOOD="$(git rev-parse HEAD~1)"; BAD="$(git rev-parse HEAD)"
OUT="$(bash "$REPO/scripts/rollback.sh" --org uat --good "$GOOD" --bad "$BAD" --validate-only 2>&1)"; RC=$?
assert_eq "$RC" 0 "rollback validate-only exits 0"
assert_contains "$(grep 'sgd source delta' "$T/sf-args.txt" | tail -1)" "--from $BAD --to $GOOD" "reverse delta built from bad to good"
assert_contains "$(tail -1 "$T/sf-args.txt")" "project deploy validate" "validate-only does a check-only run"
assert_contains "$(cat rollback-delta/destructiveChanges/destructiveChanges.xml)" "<members>Bar</members>" "component added by bad commit is scheduled for deletion"
assert_contains "$(cat rollback-delta/package/package.xml)" "<members>Foo</members>" "component deleted by bad commit is restored"
assert_contains "$OUT" "::warning::This rollback DELETES" "deletion warning shown"
assert_eq "$(git rev-parse HEAD)" "$GOOD" "working tree checked out at good commit"
OUT="$(bash "$REPO/scripts/rollback.sh" --org uat --good deadbeef 2>&1)"; RC=$?
assert_eq "$RC" 2 "unknown good ref exits 2"

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [[ $FAIL -eq 0 ]]; then rm -rf "$T"; exit 0; else echo "Fixture kept at $T"; exit 1; fi
