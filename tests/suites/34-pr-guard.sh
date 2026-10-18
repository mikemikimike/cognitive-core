#!/bin/bash
# Test suite: project-board pr/pr-guard.sh against a strict gh stub (#385)
# Every case asserts the exact gh calls; any call the stub does not know fails the case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/test-helpers.sh"

suite_start "34 - PR Guard"

PG="${ROOT_DIR}/core/skills/project-board/pr/pr-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB="${WORK}/bin"
FIX="${WORK}/fix"
REPO="${WORK}/repo"
NOGIT="${WORK}/nogit"
mkdir -p "$STUB" "$FIX" "$REPO" "$NOGIT"
: > "${WORK}/all.log"

cat > "${STUB}/gh" << 'STUBEOF'
#!/bin/bash
# Answers only the calls pr-guard.sh (and github.sh board status) are expected to make
line="$*"
printf '%s\n' "${line//$'\n'/\\n}" | tee -a "${STUB_ALL}" >> "${STUB_LOG}"
fail() { [ -n "${1:-}" ] && { echo "$1" >&2; exit 1; }; return 0; }
R=repos/acme/app
case "$line" in
    "api graphql -f owner=acme -f repo=app -F n="*" -f query=query("*)
        fail "${STUB_FAIL_GQL:-}"
        f="${STUB_FIX}/item-${8#n=}.json"
        if [ -f "$f" ]; then cat "$f"; else echo '{"data":{"repository":{"issueOrPullRequest":null}}}'; fi ;;
    "pr view "*" --repo acme/app --json number,state,isDraft,headRefOid,baseRefName")
        fail "${STUB_FAIL_VIEW:-}"
        printf '{"number":5,"state":"%s","isDraft":%s,"headRefOid":"%s","baseRefName":"main"}\n' \
            "${STUB_STATE:-OPEN}" "${STUB_DRAFT:-false}" "${STUB_HEAD:-}" ;;
    "pr view 5 --repo acme/app --json headRefOid --jq .headRefOid") fail "${STUB_FAIL_VIEW:-}"; echo "${STUB_HEAD:-}" ;;
    "api $R/rules/branches/main") fail "${STUB_FAIL_RULES:-}"; cat "${STUB_FIX}/${STUB_RULES:-rules-none.json}" ;;
    "api $R/branches/main") fail "${STUB_FAIL_BRANCH:-}"; cat "${STUB_FIX}/${STUB_BRANCH:-branch-none.json}" ;;
    "api $R/commits/"*"/check-runs?per_page=100") fail "${STUB_FAIL_RUNS:-}"; cat "${STUB_FIX}/${STUB_RUNS:-runs-none.json}" ;;
    "api $R/commits/"*"/status?per_page=100")
        fail "${STUB_FAIL_STATUS:-}"
        sha="${2#"$R"/commits/}"; sha="${sha%%/*}"
        if [ -f "${STUB_FIX}/status-$sha.json" ]; then cat "${STUB_FIX}/status-$sha.json"; else echo '{"statuses":[]}'; fi ;;
    "pr comment 5 --repo acme/app --body-file "*) fail "${STUB_FAIL_COMMENT:-}"; cp "$7" "${STUB_FIX}/comment.out" ;;
    "api $R/statuses/"*" -f state="*" -f context=cc-review -f description=Review "*)
        fail "${STUB_FAIL_POST:-}"
        printf '{"statuses":[{"context":"cc-review","state":"%s"}]}\n' "${4#state=}" > "${STUB_FIX}/status-${2#"$R"/statuses/}.json" ;;
    *) echo "UNEXPECTED: $line" | tee -a "${STUB_ALL}" >> "${STUB_LOG}"; exit 99 ;;
esac
STUBEOF
chmod +x "${STUB}/gh"

# ---- Board fixtures: mk_item <n> <status> <assignee logins, space separated> ----
mk_item() {
    local a="" l
    for l in $3; do a="${a:+$a,}{\"login\":\"$l\"}"; done
    cat > "${FIX}/item-$1.json" << EOF
{"data":{"repository":{"issueOrPullRequest":{"assignees":{"nodes":[${a}]},"projectItems":{"nodes":[
 {"id":"ITEM_$1","project":{"id":"PROJ_1"},"status":{"name":"$2","optionId":"OPT_X"},"sprint":null}]}}}}}
EOF
}
mk_item 12 "In Progress" ann
mk_item 13 "In Progress" "ann bob"
mk_item 14 "Todo" ann
mk_item 15 "In Progress" ""
# 16: not on the board (no fixture)

# ---- Check fixtures ----
echo '[]' > "${FIX}/rules-none.json"
echo '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI Summary"}]}}]' > "${FIX}/rules-ci.json"
echo '{"name":"main","protection":{"enabled":false,"required_status_checks":{"contexts":[],"checks":[]}}}' > "${FIX}/branch-none.json"
echo '{"name":"main","protection":{"enabled":true,"required_status_checks":{"contexts":["build"],"checks":[{"context":"build"}]}}}' > "${FIX}/branch-build.json"
echo '{"check_runs":[]}' > "${FIX}/runs-none.json"
runs() { # <file> <name:status:conclusion:id>...
    local f="$1" out="" r name st co id
    shift
    for r in "$@"; do
        IFS=: read -r name st co id <<< "$r"
        out="${out:+$out,}{\"id\":$id,\"name\":\"$name\",\"status\":\"$st\",\"conclusion\":${co:-null}}"
    done
    echo "{\"check_runs\":[${out}]}" > "${FIX}/$f"
}
runs runs-green.json 'CI Summary:completed:"success":1' 'lint:completed:"neutral":2' 'docs:completed:"skipped":3'
runs runs-red.json 'CI Summary:completed:"failure":1' 'lint:completed:"success":2'
runs runs-pending.json 'CI Summary:in_progress::1'
runs runs-rerun.json 'CI Summary:completed:"success":7' 'CI Summary:completed:"failure":3'
runs runs-build.json 'build:completed:"success":1'
runs runs-extra-red.json 'CI Summary:completed:"success":1' 'lint:completed:"failure":2'

# ---- Git repo: main, then feature/12-thing with one commit ----
g() { git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
git init -q "$REPO" 2>/dev/null
g checkout -q -b main
g commit -q --allow-empty -m "chore: init"
g checkout -q -b feature/12-thing
g commit -q --allow-empty -m "feat(skills): thing" -m "Fixes #13"
H1=$(git -C "$REPO" rev-parse HEAD)
H0=$(git -C "$REPO" rev-parse main)

BASE_CONF='CC_GITHUB_OWNER="acme"
CC_GITHUB_REPO="acme/app"
CC_PROJECT_NUMBER="9"
CC_PROJECT_ID="PROJ_1"
CC_STATUS_FIELD_ID="FIELD_1"
CC_TEST_COMMAND="make test"'
conf() { printf '%s\n%s\n' "$BASE_CONF" "${1:-}" > "${REPO}/cognitive-core.conf"; }
conf
printf '%s\n' "$BASE_CONF" > "${NOGIT}/cognitive-core.conf"

# run_pg [VAR=value ...] -- <pr-guard args>
# Clean environment, cwd REPO (or RUN_DIR). Sets RC, OUT, ERR, CALLS (graphql shortened).
run_pg() {
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    : > "${WORK}/log"
    (cd "${RUN_DIR:-$REPO}" && env -i PATH="${STUB}:${PATH}" HOME="$WORK" TMPDIR="${TMPDIR:-/tmp}" \
        STUB_LOG="${WORK}/log" STUB_ALL="${WORK}/all.log" STUB_FIX="$FIX" \
        ${envs[@]+"${envs[@]}"} "$SHELL_UNDER_TEST" "$PG" "$@") \
        > "${WORK}/out" 2> "${WORK}/err" && RC=0 || RC=$?
    OUT=$(cat "${WORK}/out")
    ERR=$(cat "${WORK}/err")
    CALLS=$(sed -E 's/^api graphql -f owner=acme -f repo=app -F n=([0-9]+) -f query=query\(.*/graphql item \1/' "${WORK}/log")
}

sha256() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
# conf_hash as references/pr-guard.md defines it, computed independently
HASH=$(printf 'CC_GATE_STEPS=\nCC_GATE_LINT_CMD=\nCC_GATE_UNIT_CMD=\nCC_GATE_INTEGRATION_CMD=\nCC_LINT_COMMAND=\nCC_TEST_COMMAND=make test\n' | sha256)

# mk_stamp <sha> <result> <conf_hash> [format]
mk_stamp() {
    mkdir -p "${REPO}/.cognitive-core/gate"
    printf '{"format":%s,"sha":"%s","result":"%s","conf_hash":"%s","created_at":"2026-10-18T12:00:00Z","tool":"ci-gate.sh","tool_version":"1.8.0","steps":[{"name":"unit","exit":0,"seconds":3}]}\n' \
        "${4:-1}" "$1" "$2" "$3" > "${REPO}/.cognitive-core/gate/$5.json"
}
stamp() { mk_stamp "$1" "$2" "$3" "${4:-1}" "${5:-$1}"; }   # <sha> <result> <hash> [format] [file sha]
no_stamp() { rm -rf "${REPO}/.cognitive-core"; }
review() { printf '{"statuses":[{"context":"cc-review","state":"%s"},{"context":"other","state":"success"}]}\n' "$2" > "${FIX}/status-$1.json"; }
no_review() { rm -f "${FIX}/status-$1.json"; }

VIEW_CALL='pr view 5 --repo acme/app --json number,state,isDraft,headRefOid,baseRefName'
VIEW_BRANCH='pr view feature/12-thing --repo acme/app --json number,state,isDraft,headRefOid,baseRefName'

# =============================================================================
create_cases() {
local S="$1"
CREATE='gh pr create --assignee @me --draft'

# ---- Parser fixtures ----
run_pg -- check create "${CREATE} --title \"feat(skills): thing\" --body \"\$(cat <<'EOF'
## Summary
It's a \"quoted\" (body

Fixes #13
EOF
)\" 2>&1 | tee pr.log"
assert_eq "${S}heredoc body: exit 0" "0" "$RC"
assert_eq "${S}heredoc body: branch #12 and body #13 checked" "graphql item 12
graphql item 13" "$CALLS"
assert_contains "${S}heredoc body: verdict names the issues" "$OUT" "allowed (issues #12 #13)"

printf 'Summary\n\nCloses #14\n' > "${REPO}/body.md"
run_pg -- check create "${CREATE} -t 'feat: x' -F body.md"
assert_eq "${S}-F file: exit 1 (#14 is Todo)" "1" "$RC"
assert_eq "${S}-F file: branch #12 and file #14 checked" "graphql item 12
graphql item 14" "$CALLS"
assert_contains "${S}-F file: failure names the status" "$OUT" "#14 is Todo (todo), not In Progress"
assert_contains "${S}-F file: fix given" "$OUT" "Fix: providers/github.sh board move 14 progress"
run_pg -- check create "${CREATE} --body-file=body.md"
assert_eq "${S}--body-file=: same issues" "graphql item 12
graphql item 14" "$CALLS"

run_pg -- check create "${CREATE} --fill -H chore/tidy"
assert_eq "${S}--fill: commit message #13 from git log" "0|graphql item 13" "${RC}|${CALLS}"
run_pg -- check create "${CREATE} --fill-first -B main -H chore/tidy"
assert_eq "${S}--fill-first -B main: same" "0|graphql item 13" "${RC}|${CALLS}"

run_pg -- check create "${CREATE} --title 'feat: thing' --body 'no reference here'"
assert_eq "${S}branch only: #12 from feature/12-thing" "0|graphql item 12" "${RC}|${CALLS}"

run_pg -- check create "${CREATE} -H chore/x -t 'docs: y' -b 'Fixes other/repo#20
see https://github.com/acme/app/issues/21 and Fixes https://github.com/acme/app/issues/22
#23 alone, fixes #24abc, prefixes #25, Refs acme/app#13'"
assert_eq "${S}cross-repo, URL, bare #N ignored; same-repo owner/repo#N counted" "0|graphql item 13" "${RC}|${CALLS}"

run_pg -- check create "${CREATE} -t 'fix: x (Fixes #13)' -b 'refs #12
Resolves: #15
CLOSED #13'"
assert_eq "${S}several issues: exit 1 (#15 unassigned)" "1" "$RC"
assert_eq "${S}several issues: each checked once, in order" "graphql item 12
graphql item 13
graphql item 15" "$CALLS"
assert_contains "${S}several issues: failure" "$OUT" "#15 has no assignee"
assert_contains "${S}several issues: fix" "$OUT" "Fix: providers/github.sh issue assign 15 <login>"

# ---- Rules ----
run_pg -- check create "${CREATE} -H chore/x -t 'chore: x' -b 'nothing'"
assert_eq "${S}no issue: exit 1, no gh call" "1|" "${RC}|${CALLS}"
assert_contains "${S}no issue: fix names the branch form" "$OUT" "<type>/<N>-slug"
run_pg -- check create "${CREATE} -H docs/readme -t 'x' -b 'nothing'"
assert_eq "${S}no issue, branch type not optional: exit 1" "1" "$RC"
conf 'CC_PR_GUARD_ISSUE_OPTIONAL="docs chore"'
run_pg -- check create "${CREATE} -H docs/readme -t 'x' -b 'nothing'"
assert_eq "${S}optional branch type docs: exit 0, no gh call" "0|" "${RC}|${CALLS}"
run_pg -- check create "${CREATE} -H main -t 'chore(deps): bump' -b 'nothing'"
assert_eq "${S}optional title type chore: exit 0" "0|" "${RC}|${CALLS}"
run_pg -- check create "${CREATE} -H docs/readme -t 'x' -b 'Refs #14'"
assert_eq "${S}optional type still checks a referenced issue" "1|graphql item 14" "${RC}|${CALLS}"
conf

run_pg -- check create "gh pr create --assignee @me --web"
assert_eq "${S}--web: exit 1" "1" "$RC"
assert_contains "${S}--web: refused" "$OUT" "--web: the browser flow cannot be checked"
run_pg -- check create "gh pr create -a @me -dw"
assert_contains "${S}-dw cluster: --web refused" "$OUT" "--web"

run_pg -- check create "gh pr create --assignee @me -t x -F - <<'EOF'
Fixes #13
EOF"
assert_eq "${S}-F -: exit 1" "1" "$RC"
assert_contains "${S}-F -: refused" "$OUT" "-F -: a body from stdin cannot be checked"

run_pg -- check create "gh pr create -t x -b 'Fixes #13'"
assert_eq "${S}no --assignee: exit 1" "1" "$RC"
assert_contains "${S}no --assignee: fix" "$OUT" "Fix: add --assignee @me"
run_pg -- check create "gh pr create --assignee=@me -t x -b 'Fixes #13'"
assert_eq "${S}--assignee=: exit 0" "0" "$RC"

run_pg -- check create "${CREATE} -t x -b 'Fixes #16'"
assert_eq "${S}issue not on the board: exit 1" "1|graphql item 12
graphql item 16" "${RC}|${CALLS}"
assert_contains "${S}issue not on the board: message" "$OUT" "#16: Issue #16 not found on board"

run_pg -- check create "${CREATE} -F missing.md"
assert_contains "${S}missing body file: refused" "$OUT" "body file missing.md not found"

conf 'CC_PROJECT_ID=""'
run_pg -- check create "${CREATE} -t x -b 'Fixes #14'"
assert_eq "${S}board not configured: board rule skipped, exit 0, no gh call" "0|" "${RC}|${CALLS}"
assert_contains "${S}board not configured: noted" "$OUT" "board not configured"
conf

# ---- Exit codes 2 and 3 ----
run_pg STUB_FAIL_GQL="HTTP 502" -- check create "${CREATE} -t x"
assert_eq "${S}board lookup fails: exit 2" "2" "$RC"
assert_contains "${S}board lookup fails: message" "$ERR" "HTTP 502"
run_pg -- check create "git status && echo gh pr create"
assert_eq "${S}gh pr create as an echo argument: exit 3" "3|" "${RC}|${CALLS}"
run_pg -- check create "cd . && GH_DEBUG=0 gh pr create --assignee @me -t x"
assert_eq "${S}after cd and an assignment: applies" "0|graphql item 12" "${RC}|${CALLS}"
run_pg -- check create "git status; gh pr list"
assert_eq "${S}no gh pr create: exit 3, no gh call" "3|" "${RC}|${CALLS}"
run_pg -- check create "${CREATE} -R other/repo -t x"
assert_eq "${S}another --repo: exit 3" "3|" "${RC}|${CALLS}"
run_pg -- check create "${CREATE} --repo ACME/App -t x"
assert_eq "${S}same --repo (case-insensitive): applies" "0|graphql item 12" "${RC}|${CALLS}"
RUN_DIR="$NOGIT" run_pg -- check create "${CREATE} -t x"
assert_eq "${S}not a git repository: exit 3" "3|" "${RC}|${CALLS}"
RUN_DIR="$WORK" run_pg -- check create "${CREATE} -t x"
assert_eq "${S}no cognitive-core.conf: exit 3" "3" "$RC"
run_pg -- check create
assert_eq "${S}usage: command text missing: exit 1" "1" "$RC"
}

# =============================================================================
ready_cases() {
local S="$1"
no_stamp; review "$H1" success
RD=(STUB_HEAD="$H1" STUB_DRAFT=true)

stamp "$H1" PASS "$HASH"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready"
assert_eq "${S}stamp PASS + review: exit 0" "0" "$RC"
assert_eq "${S}stamp PASS: current branch as selector, no check lookups" "${VIEW_BRANCH}
api repos/acme/app/commits/${H1}/status?per_page=100" "$CALLS"
assert_contains "${S}stamp PASS: verdict" "$OUT" "gh pr ready allowed (#5 at ${H1:0:7})"
run_pg "${RD[@]}" -- check ready "gh pr ready 5"
assert_eq "${S}either: a valid stamp is enough" "0|${VIEW_CALL}
api repos/acme/app/commits/${H1}/status?per_page=100" "${RC}|${CALLS}"

stamp "$H1" FAIL "$HASH"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_eq "${S}stamp FAIL: exit 1" "1" "$RC"
assert_contains "${S}stamp FAIL: reason" "$OUT" "gate result is FAIL"
stamp "$H1" NONE "$HASH"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_contains "${S}stamp NONE: not evidence" "$OUT" "gate result is NONE"
stamp "$H1" PASS "$HASH"
conf 'CC_TEST_COMMAND="make test-all"'
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_contains "${S}stamp: changed gate config invalidates it" "$OUT" "gate config changed since the stamp"
conf
stamp "$H0" PASS "$HASH" 1 "$H1"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_contains "${S}stamp: sha field of another commit" "$OUT" "gate stamp is for another commit"
stamp "$H1" PASS "$HASH" 2
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_contains "${S}stamp: unknown format" "$OUT" "gate stamp format unknown"
echo 'not json' > "${REPO}/.cognitive-core/gate/${H1}.json"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_contains "${S}stamp: unreadable" "$OUT" "gate stamp unreadable"
no_stamp
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=stamp -- check ready "gh pr ready 5"
assert_eq "${S}stamp missing: exit 1, no check lookups" "1|${VIEW_CALL}
api repos/acme/app/commits/${H1}/status?per_page=100" "${RC}|${CALLS}"
assert_contains "${S}stamp missing: fix" "$OUT" "Fix: run the project gate for this HEAD"

# checks: ruleset, legacy protection, all checks
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_RULES=rules-ci.json STUB_RUNS=runs-green.json -- check ready "gh pr ready 5"
assert_eq "${S}checks: ruleset check green: exact calls" "0|${VIEW_CALL}
api repos/acme/app/rules/branches/main
api repos/acme/app/commits/${H1}/status?per_page=100
api repos/acme/app/commits/${H1}/check-runs?per_page=100" "${RC}|${CALLS}"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_RULES=rules-ci.json STUB_RUNS=runs-red.json -- check ready "gh pr ready 5"
assert_eq "${S}checks: required check red: exit 1" "1" "$RC"
assert_contains "${S}checks: names the check" "$OUT" "check 'CI Summary' is failure on HEAD ${H1:0:7}"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_RULES=rules-ci.json STUB_RUNS=runs-extra-red.json -- check ready "gh pr ready 5"
assert_eq "${S}checks: a red check that is not required does not count" "0" "$RC"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_RULES=rules-ci.json STUB_RUNS=runs-rerun.json -- check ready "gh pr ready 5"
assert_eq "${S}checks: the latest run of a check wins" "0" "$RC"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_BRANCH=branch-build.json STUB_RUNS=runs-build.json -- check ready "gh pr ready 5"
assert_eq "${S}checks: legacy protection when no ruleset" "0|${VIEW_CALL}
api repos/acme/app/rules/branches/main
api repos/acme/app/branches/main
api repos/acme/app/commits/${H1}/status?per_page=100
api repos/acme/app/commits/${H1}/check-runs?per_page=100" "${RC}|${CALLS}"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_BRANCH=branch-build.json STUB_RUNS=runs-green.json -- check ready "gh pr ready 5"
assert_contains "${S}checks: required check missing on HEAD" "$OUT" "check 'build' is missing"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks STUB_RUNS=runs-extra-red.json -- check ready "gh pr ready 5"
assert_contains "${S}checks: none required -> every check counts" "$OUT" "check 'lint' is failure"
printf '{"statuses":[{"context":"cc-review","state":"success"}]}\n' > "${FIX}/status-${H1}.json"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=checks -- check ready "gh pr ready 5"
assert_contains "${S}checks: none required, none reported (cc-review does not count)" "$OUT" "no checks reported on HEAD"
review "$H1" success

run_pg "${RD[@]}" STUB_RULES=rules-ci.json STUB_RUNS=runs-green.json -- check ready "gh pr ready 5"
assert_eq "${S}either: no stamp, checks green: exit 0" "0" "$RC"
run_pg "${RD[@]}" STUB_RULES=rules-ci.json STUB_RUNS=runs-pending.json -- check ready "gh pr ready 5"
assert_eq "${S}either: no stamp, checks pending: exit 1" "1" "$RC"
assert_contains "${S}either: both reasons" "$OUT" "no gate stamp for ${H1:0:7}; checks not green: CI Summary pending"
run_pg "${RD[@]}" CC_PR_GATE_SOURCE=always -- check ready "gh pr ready 5"
assert_contains "${S}invalid CC_PR_GATE_SOURCE: violation" "$OUT" "CC_PR_GATE_SOURCE=always is not stamp, checks or either"

# local HEAD, review, applicability
stamp "$H1" PASS "$HASH"
run_pg STUB_HEAD="$H0" STUB_DRAFT=true -- check ready "gh pr ready 5"
assert_eq "${S}local HEAD is not the PR head: exit 1" "1" "$RC"
assert_contains "${S}local HEAD differs: fix" "$OUT" "local HEAD ${H1:0:7} is not the PR head ${H0:0:7}"
no_review "$H1"
run_pg "${RD[@]}" -- check ready "gh pr ready 5"
assert_contains "${S}cc-review missing: refused" "$OUT" "cc-review is missing on HEAD ${H1:0:7}"
assert_contains "${S}cc-review missing: fix names review-record" "$OUT" "pr-guard.sh review-record 5 --sha ${H1}"
review "$H1" failure
run_pg "${RD[@]}" -- check ready "gh pr ready 5"
assert_contains "${S}cc-review failure: refused" "$OUT" "cc-review is failure on HEAD"
review "$H1" success
run_pg STUB_HEAD="$H1" STUB_DRAFT=false -- check ready "gh pr ready 5"
assert_eq "${S}not a draft: exit 3" "3" "$RC"
run_pg "${RD[@]}" -- check ready "gh pr ready 5 --undo"
assert_eq "${S}--undo: exit 3, no gh call" "3|" "${RC}|${CALLS}"
run_pg "${RD[@]}" STUB_STATE=MERGED -- check ready "gh pr ready 5"
assert_eq "${S}merged PR: exit 3" "3" "$RC"
run_pg "${RD[@]}" STUB_FAIL_VIEW="no pull requests found" -- check ready "gh pr ready 5"
assert_eq "${S}pr view fails: exit 2" "2" "$RC"
assert_contains "${S}pr view fails: gh message" "$ERR" "no pull requests found"
no_stamp
run_pg "${RD[@]}" STUB_FAIL_RULES="HTTP 500" -- check ready "gh pr ready 5"
assert_eq "${S}rules lookup fails: exit 2" "2" "$RC"
}

# =============================================================================
merge_cases() {
local S="$1"
review "$H1" success
MG=(STUB_HEAD="$H1" STUB_RULES=rules-ci.json)

run_pg "${MG[@]}" STUB_RUNS=runs-green.json -- check merge "gh pr merge 5 --squash --delete-branch"
assert_eq "${S}merge green + review: exact calls" "0|${VIEW_CALL}
api repos/acme/app/rules/branches/main
api repos/acme/app/commits/${H1}/status?per_page=100
api repos/acme/app/commits/${H1}/check-runs?per_page=100" "${RC}|${CALLS}"
run_pg "${MG[@]}" STUB_RUNS=runs-green.json -- check merge "gh pr merge --squash"
assert_eq "${S}merge without selector: current branch" "0" "$RC"
assert_contains "${S}merge without selector: pr view by branch" "$CALLS" "$VIEW_BRANCH"
run_pg "${MG[@]}" STUB_RUNS=runs-green.json STUB_DRAFT=true -- check merge "gh pr merge 5 -s"
assert_eq "${S}draft: exit 1" "1" "$RC"
assert_contains "${S}draft: fix" "$OUT" "mark it ready first"
run_pg "${MG[@]}" STUB_RUNS=runs-green.json -- check merge "gh pr merge 5 --squash --admin"
assert_eq "${S}--admin: exit 1" "1" "$RC"
assert_contains "${S}--admin: refused" "$OUT" "--admin bypasses branch protection"
run_pg "${MG[@]}" STUB_RUNS=runs-red.json -- check merge "gh pr merge 5 --squash"
assert_eq "${S}required check red: exit 1" "1" "$RC"
assert_contains "${S}required check red: named" "$OUT" "check 'CI Summary' is failure"
run_pg "${MG[@]}" STUB_RUNS=runs-pending.json -- check merge "gh pr merge 5 --auto --squash"
assert_eq "${S}--auto with server-required checks: allowed, no check-run lookup" "0|${VIEW_CALL}
api repos/acme/app/rules/branches/main
api repos/acme/app/commits/${H1}/status?per_page=100" "${RC}|${CALLS}"
run_pg STUB_HEAD="$H1" STUB_RUNS=runs-pending.json -- check merge "gh pr merge 5 --auto"
assert_eq "${S}--auto without required checks: checks still evaluated" "1" "$RC"
assert_contains "${S}--auto without required checks: pending named" "$OUT" "check 'CI Summary' is pending"
run_pg STUB_HEAD="$H1" STUB_RUNS=runs-green.json -- check merge "gh pr merge 5 -t 'feat: x' -b 'body --admin'"
assert_eq "${S}no required checks, all green; --admin inside a value is not a flag" "0" "$RC"
review "$H1" failure
run_pg "${MG[@]}" STUB_RUNS=runs-green.json -- check merge "gh pr merge 5"
assert_contains "${S}cc-review failure: refused" "$OUT" "cc-review is failure"
review "$H1" success
run_pg "${MG[@]}" STUB_RUNS=runs-red.json STUB_DRAFT=true -- check merge "gh pr merge 5 --admin"
assert_eq "${S}every failure listed" "3" "$(grep -c '^- ' <<< "$OUT")"
run_pg "${MG[@]}" -- check merge "gh pr merge 5 --disable-auto"
assert_eq "${S}--disable-auto: exit 3, no gh call" "3|" "${RC}|${CALLS}"
run_pg "${MG[@]}" STUB_STATE=CLOSED -- check merge "gh pr merge 5"
assert_eq "${S}closed PR: exit 3" "3" "$RC"
run_pg "${MG[@]}" STUB_FAIL_RUNS="HTTP 403 rate limit" -- check merge "gh pr merge 5"
assert_eq "${S}check-runs lookup fails: exit 2" "2" "$RC"
run_pg "${MG[@]}" STUB_FAIL_STATUS="HTTP 500" -- check merge "gh pr merge 5"
assert_eq "${S}status lookup fails: exit 2" "2" "$RC"
}

# =============================================================================
review_cases() {
local S="$1"
printf 'All criteria met.\n' > "${REPO}/review.md"
no_review "$H1"; rm -f "${FIX}/comment.out"

run_pg STUB_HEAD="$H1" -- review-record 5 --sha "$H0" --result PASS --body-file review.md
assert_eq "${S}stale SHA: exit 1, only the head lookup" "1|pr view 5 --repo acme/app --json headRefOid --jq .headRefOid" "${RC}|${CALLS}"
assert_contains "${S}stale SHA: refused" "$OUT" "${H0:0:7} is not the head of PR #5 (${H1:0:7})"
assert_eq "${S}stale SHA: no comment written" "no" "$([ -f "${FIX}/comment.out" ] && echo yes || echo no)"

run_pg STUB_HEAD="$H1" -- review-record 5 --sha "$H1" --result PASS --body-file review.md
assert_eq "${S}PASS: exact calls (comment before status)" "0|pr view 5 --repo acme/app --json headRefOid --jq .headRefOid
pr comment 5 --repo acme/app --body-file <tmp>
api repos/acme/app/statuses/${H1} -f state=success -f context=cc-review -f description=Review PASS" \
    "${RC}|$(sed -E 's|--body-file /.*|--body-file <tmp>|' <<< "$CALLS")"
assert_eq "${S}PASS: comment marker line" "<!-- cc-review:v1 result=PASS sha=${H1} -->" "$(head -1 "${FIX}/comment.out")"
assert_contains "${S}PASS: comment carries the review" "$(cat "${FIX}/comment.out")" "All criteria met."

# The recorded review satisfies merge for that HEAD; a new commit has none
run_pg STUB_HEAD="$H1" STUB_RULES=rules-ci.json STUB_RUNS=runs-green.json -- check merge "gh pr merge 5"
assert_eq "${S}recorded review: merge allowed for the reviewed HEAD" "0" "$RC"
g commit -q --allow-empty -m "fix: follow-up"
H2=$(git -C "$REPO" rev-parse HEAD)
run_pg STUB_HEAD="$H2" STUB_RULES=rules-ci.json STUB_RUNS=runs-green.json -- check merge "gh pr merge 5"
assert_eq "${S}new commit: no cc-review, merge refused" "1" "$RC"
assert_contains "${S}new commit: cc-review missing" "$OUT" "cc-review is missing on HEAD ${H2:0:7}"
g reset -q --hard "$H1"

run_pg STUB_HEAD="$H1" -- review-record 5 --sha "$H1" --result FAIL --body-file review.md
assert_contains "${S}FAIL: status failure" "$CALLS" "-f state=failure -f context=cc-review -f description=Review FAIL"
assert_eq "${S}FAIL: comment marker" "<!-- cc-review:v1 result=FAIL sha=${H1} -->" "$(head -1 "${FIX}/comment.out")"

no_review "$H1"
run_pg STUB_HEAD="$H1" STUB_FAIL_COMMENT="HTTP 502" -- review-record 5 --sha "$H1" --result PASS --body-file review.md
assert_eq "${S}comment fails: exit 2" "2" "$RC"
assert_not_contains "${S}comment fails: no status written" "$CALLS" "statuses"
run_pg STUB_HEAD="$H1" STUB_FAIL_POST="HTTP 502" -- review-record 5 --sha "$H1" --result PASS --body-file review.md
assert_eq "${S}status fails: exit 2" "2" "$RC"

run_pg -- review-record 5 --sha abc123 --result PASS --body-file review.md
assert_eq "${S}short SHA: usage error, no gh call" "1|" "${RC}|${CALLS}"
run_pg -- review-record 5 --sha "$H1" --result OK --body-file review.md
assert_eq "${S}bad result: usage error" "1|" "${RC}|${CALLS}"
: > "${REPO}/empty.md"
run_pg -- review-record 5 --sha "$H1" --result PASS --body-file empty.md
assert_eq "${S}empty body: usage error" "1|" "${RC}|${CALLS}"
run_pg -- review-record x --sha "$H1" --result PASS --body-file review.md
assert_eq "${S}PR not a number: usage error" "1|" "${RC}|${CALLS}"
}

# =============================================================================
hash_cases() {
local S="$1"
run_pg -- conf-hash
assert_eq "${S}conf-hash: documented formula" "$HASH" "$OUT"
conf 'CC_GATE_STEPS="unit e2e"
CC_GATE_E2E_CMD="npm run e2e"
CC_LINT_COMMAND="lint \$1"'
expected=$(printf 'CC_GATE_STEPS=unit e2e\nCC_GATE_UNIT_CMD=\nCC_GATE_E2E_CMD=npm run e2e\nCC_LINT_COMMAND=lint $1\nCC_TEST_COMMAND=make test\n' | sha256)
run_pg -- conf-hash
assert_eq "${S}conf-hash: custom steps" "$expected" "$OUT"
conf
}

SHELL_UNDER_TEST="$BASH"
create_cases ""
ready_cases ""
merge_cases ""
review_cases ""
hash_cases ""
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" = "3" ]; then
    SHELL_UNDER_TEST=/bin/bash
    create_cases "bash 3.2: "
    ready_cases "bash 3.2: "
    merge_cases "bash 3.2: "
    review_cases "bash 3.2: "
    hash_cases "bash 3.2: "
else
    _skip "bash 3.2 not available (/bin/bash is not 3.x)"
fi

assert_eq "no unexpected gh call in any case" "0" "$(grep -c '^UNEXPECTED' "${WORK}/all.log" || true)"

suite_end
