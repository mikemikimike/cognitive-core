#!/bin/bash
# Test suite: settings.json follows the conf (#345)
# - wires exactly the selected and installed hooks (CC_HOOKS)
# - CC_SECURITY_LEVEL=strict adds no allow rules
# - re-install merges into an existing settings.json (backup, user entries kept)
# - the MCP server is opt-in (CC_MCP_SERVER)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/test-helpers.sh"

suite_start "37 - Settings Generation"

# write_conf <dir> <hooks> <security level> [extra lines]
write_conf() {
    rm -f "${1}/cognitive-core.conf"
    cat > "${1}/cognitive-core.conf" << EOF
CC_PROJECT_NAME="settings-test"
CC_PROJECT_DESCRIPTION="Settings test"
CC_ORG="test-org"
CC_FORMAT_COMMAND=""
CC_TEST_PATTERN="tests/**/*.py"
CC_SRC_ROOT="src"
CC_TEST_ROOT="tests"
CC_COORDINATOR_MODEL="opus"
CC_SPECIALIST_MODEL="sonnet"
CC_COMMIT_FORMAT="conventional"
CC_COMMIT_SCOPES="core"
CC_RUNNER_TYPE="github-hosted"
CC_BLOCKED_PATTERNS=""
CC_ALLOWED_DOMAINS=""
CC_KNOWN_SAFE_DOMAINS=""
CC_COMPACT_RULES="1. Follow standards"
CC_SESSION_DOCS_DIR="docs"
CC_SESSION_MAX_AGE_DAYS="30"
CC_FITNESS_LINT="60"
CC_FITNESS_COMMIT="80"
CC_FITNESS_TEST="85"
CC_FITNESS_MERGE="90"
CC_FITNESS_DEPLOY="95"
CC_RUNNER_NODES="1"
CC_RUNNER_LABELS="self-hosted"
CC_LANGUAGE="python"
CC_LINT_EXTENSIONS=".py"
CC_LINT_COMMAND="ruff check \$1"
CC_TEST_COMMAND="pytest"
CC_DATABASE="none"
CC_ARCHITECTURE="none"
CC_AGENTS="reviewer"
CC_SKILLS="code-review"
CC_HOOKS="${2}"
CC_SECURITY_LEVEL="${3}"
CC_MAIN_BRANCH="main"
CC_ENABLE_CICD="false"
CC_MONITORING="false"
CC_ENABLE_CLEANUP_CRON="false"
CC_AGENT_TEAMS="false"
CC_MCP_SERVERS=""
${4:-}
EOF
}

run_install() {
    bash "${ROOT_DIR}/install.sh" "$@" 2>&1
}

# wired <settings.json>: sorted framework hook names referenced in hooks
wired() {
    python3 - "$1" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
names = {h["command"].rsplit("/", 1)[-1][:-3]
         for groups in d.get("hooks", {}).values() for g in groups for h in g["hooks"]}
print(" ".join(sorted(names)))
PY
}

# ---- 1. Only selected hooks are wired, every wired hook exists ----
t1=$(create_test_dir)
git -C "$t1" init --quiet
write_conf "$t1" "setup-env validate-bash validate-read compact-reminder" "standard"
out1=$(run_install "$t1") || { _fail "install (selection)" "$(echo "$out1" | tail -5)"; }
s1="${t1}/.claude/settings.json"
assert_eq "selection: wired hooks equal CC_HOOKS" \
    "compact-reminder setup-env validate-bash validate-read" "$(wired "$s1")"
missing=""
for h in $(wired "$s1"); do
    [ -f "${t1}/.claude/hooks/${h}.sh" ] || missing="${missing} ${h}"
done
assert_eq "selection: no wired hook is missing on disk" "" "$missing"
assert_eq "selection: valid JSON" "0" "$(python3 -m json.tool "$s1" >/dev/null 2>&1; echo $?)"
assert_contains "selection: standard keeps template allow rules" "$(cat "$s1")" '"Read"'

# ---- 2. Version guards are wired when selected ----
t2=$(create_test_dir)
git -C "$t2" init --quiet
write_conf "$t2" "validate-bash angular-version-guard" "standard"
run_install "$t2" >/dev/null || _fail "install (guards)"
assert_eq "guards: angular-version-guard wired" \
    "angular-version-guard validate-bash" "$(wired "${t2}/.claude/settings.json")"

# ---- 3. strict: no allow rules ----
t3=$(create_test_dir)
git -C "$t3" init --quiet
write_conf "$t3" "validate-bash" "strict"
run_install "$t3" >/dev/null || _fail "install (strict)"
assert_eq "strict: allow list empty" "0" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["permissions"]["allow"]))' "${t3}/.claude/settings.json")"

# ---- 4. Re-install merges: user entries kept, backup written ----
python3 - "$s1" << 'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["deny"].append("Read(**/*.age)")
d["permissions"]["allow"].append("Bash(make test)")
d["hooks"].setdefault("PreToolUse", []).append(
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/own/hook.sh"}]})
d["env"]["MY_VAR"] = "1"
d["model"] = "opus"
json.dump(d, open(p, "w"), indent=2)
PY
write_conf "$t1" "setup-env validate-bash" "standard"
out4=$(run_install "$t1" --force) || _fail "re-install (merge)" "$(echo "$out4" | tail -5)"
c4=$(cat "$s1")
assert_contains "merge: user deny kept" "$c4" 'Read(**/*.age)'
assert_contains "merge: user allow kept" "$c4" 'Bash(make test)'
assert_contains "merge: user hook kept" "$c4" '/opt/own/hook.sh'
assert_contains "merge: user env kept" "$c4" '"MY_VAR"'
assert_contains "merge: other user keys kept" "$c4" '"model": "opus"'
assert_eq "merge: framework wiring follows the new CC_HOOKS" \
    "hook setup-env validate-bash" "$(wired "$s1")"
assert_contains "merge: diff printed" "$out4" "settings.json (after)"
assert_ne "merge: backup written" "" "$(find "${t1}/.claude" -name 'settings.json.bak.*' | head -1)"

# ---- 5. Re-install without changes is idempotent ----
before=$(cat "$s1")
nb=$(find "${t1}/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')
run_install "$t1" --force >/dev/null || _fail "re-install (idempotent)"
assert_eq "idempotent: settings unchanged" "$before" "$(cat "$s1")"
assert_eq "idempotent: no new backup" "$nb" "$(find "${t1}/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')"

# ---- 6. strict re-install drops the template allow rules, keeps user ones ----
write_conf "$t1" "setup-env validate-bash" "strict"
run_install "$t1" --force >/dev/null || _fail "re-install (strict)"
allow6=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["permissions"]["allow"])' "$s1")
assert_eq "strict merge: only user allow rules left" "['Bash(make test)']" "$allow6"

# ---- 7. MCP server is opt-in ----
assert_eq "mcp: no .mcp.json by default" "no" "$([ -e "${t3}/.mcp.json" ] && echo yes || echo no)"
assert_eq "mcp: no server copied by default" "no" "$([ -e "${t3}/.cognitive-core/mcp-server" ] && echo yes || echo no)"
t7=$(create_test_dir)
git -C "$t7" init --quiet
write_conf "$t7" "validate-bash" "standard" 'CC_MCP_SERVER="true"'
run_install "$t7" >/dev/null || _fail "install (mcp)"
assert_file_exists "mcp: .mcp.json with CC_MCP_SERVER=true" "${t7}/.mcp.json"
assert_file_exists "mcp: server copied with CC_MCP_SERVER=true" "${t7}/.cognitive-core/mcp-server/server.py"

rm -rf "$t1" "$t2" "$t3" "$t7"

suite_end
