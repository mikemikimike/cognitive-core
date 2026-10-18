#!/bin/bash
# =============================================================================
# pr-guard.sh - PR lifecycle rules for gh pr create, ready and merge (#385)
#
# Usage:
#   pr-guard.sh check create|ready|merge "<command text>"
#   pr-guard.sh review-record <PR> --sha <sha> --result PASS|FAIL --body-file <file>
#   pr-guard.sh conf-hash            # current gate config hash (gate stamp field)
#
# The command text is the Bash command as typed, heredoc bodies included; the
# guard reads the first `gh pr <mode>` in it. Every GitHub call happens here,
# callers pass plain arguments. Rules, config and the gate stamp format:
# references/pr-guard.md
#
# Exit codes: 0 pass, 1 rule violated (each failure with its fix) or usage
# error, 2 GitHub failure, 3 not applicable
# Runs on bash 3.2: no associative arrays, no ${v,,}, no mapfile.
# =============================================================================
set -euo pipefail

PG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_provider-lib.sh
source "$PG_DIR/../_provider-lib.sh"
PG_GITHUB_SH="$PG_DIR/../providers/github.sh"
PG_REVIEW_CONTEXT="cc-review"

FAILURES=""
STATUS_JSON=""

pg_rule() { FAILURES="${FAILURES}- $1"$'\n'"  Fix: $2"$'\n'; }   # <failure> <fix>
pg_na() { echo "pr-guard: not applicable: $1"; exit 3; }
pg_usage() { echo "pr-guard: $1" >&2; exit 1; }
pg_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# pg_verdict <what> [detail]: exit 1 with every failure, else exit 0
pg_verdict() {
    if [ -n "$FAILURES" ]; then
        printf 'pr-guard: %s refused:\n%s' "$1" "$FAILURES"
        exit 1
    fi
    echo "pr-guard: $1 allowed${2:+ ($2)}"
    exit 0
}

# pg_gh <gh args>: gh's output; a failure exits 2 with gh's own message
pg_gh() {
    local err out rc=0 msg
    err=$(mktemp)
    out=$(gh "$@" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        msg=$(grep -v '^[[:space:]]*$' "$err" | head -1 || true)
        rm -f "$err"
        echo "pr-guard: gh $1 $2 failed: ${msg:-exit $rc}" >&2
        exit 2
    fi
    rm -f "$err"
    printf '%s\n' "$out"
}

pg_load_config() {
    # A probe in a subshell: _pb_load_config exits 1 when no conf exists
    (_pb_load_config) >/dev/null 2>&1 || pg_na "cognitive-core.conf not found"
    _pb_load_config
    [ -n "${CC_GITHUB_REPO:-}" ] || pg_na "CC_GITHUB_REPO not set"
}

# ---- Gate config hash (stamp field conf_hash) ----
# SHA-256 of these lines, each ending in \n:
#   CC_GATE_STEPS=<value>, CC_GATE_<STEP>_CMD=<value> for each step of
#   CC_GATE_STEPS (default "lint unit integration", step upper-cased),
#   CC_LINT_COMMAND=<value>, CC_TEST_COMMAND=<value>
pg_conf_hash() {
    local step var
    {
        printf 'CC_GATE_STEPS=%s\n' "${CC_GATE_STEPS:-}"
        for step in ${CC_GATE_STEPS:-lint unit integration}; do
            var="CC_GATE_$(printf '%s' "$step" | tr '[:lower:]' '[:upper:]')_CMD"
            if [[ "$var" =~ ^[A-Z0-9_]+$ ]]; then
                printf '%s=%s\n' "$var" "${!var:-}"
            else
                printf '%s=\n' "$var"
            fi
        done
        printf 'CC_LINT_COMMAND=%s\n' "${CC_LINT_COMMAND:-}"
        printf 'CC_TEST_COMMAND=%s\n' "${CC_TEST_COMMAND:-}"
    } | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# ---- Command text -> arguments of the first `gh pr <mode>` ----
# A small shell lexer: quotes, backslashes, $( ), heredocs (their body joins the
# word that holds the operator, so --body "$(cat <<'EOF' ... EOF)" keeps its text),
# redirections dropped. Prints the arguments NUL-separated; exit 1 when absent.
# shellcheck disable=SC2016
PG_LEXER='
import re, sys
mode, s = sys.argv[1], sys.argv[2]
tokens, cur, stack, pending = [], [], [], []
state = {"word": False, "drop": False}

def flush():
    if state["word"] or cur:
        if not state["drop"]:
            tokens.append(("w", "".join(cur)))
        state["drop"] = False
    del cur[:]
    state["word"] = False

i, n = 0, len(s)
while i < n:
    c = s[i]
    top = stack[-1] if stack else ""
    if top == "\x27":
        if c == "\x27":
            stack.pop()
        else:
            cur.append(c)
        i += 1
        continue
    if c == "\\" and i + 1 < n:
        nxt = s[i + 1]
        if nxt != "\n":
            if top == "\"" and nxt not in "$`\"\\":
                cur.append(c)
            cur.append(nxt)
            state["word"] = True
        i += 2
        continue
    if top == "\"":
        if c == "\"":
            stack.pop()
        elif s.startswith("$(", i):
            stack.append("$(")
            cur.append("$(")
            i += 2
            continue
        else:
            cur.append(c)
        i += 1
        continue
    # unquoted: top level or inside $( )
    if c == "\n" and pending:
        i += 1
        bodies = []
        for strip, delim in pending:
            body = []
            while i < n:
                j = s.find("\n", i)
                j = n if j < 0 else j
                line = s[i:j]
                i = j + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                body.append(line)
            bodies.append("\n".join(body))
        del pending[:]
        if stack:
            cur.append("\n" + "\n".join(bodies) + "\n")
        else:
            flush()
            tokens.append(("op", "\n"))
        continue
    if s.startswith("<<", i) and not s.startswith("<<<", i):
        j = i + 2
        strip = j < n and s[j] == "-"
        j += 1 if strip else 0
        while j < n and s[j] in " \t":
            j += 1
        if j < n and s[j] in "\x27\"":
            k = s.find(s[j], j + 1)
            k = n if k < 0 else k
            delim, end = s[j + 1:k], k + 1
        else:
            k = j
            while k < n and s[k] not in " \t\n;&|<>()":
                k += 1
            delim, end = s[j:k].replace("\\", ""), k
        pending.append((strip, delim))
        if stack:
            cur.append(s[i:end])
        else:
            flush()
        i = end
        continue
    if c == "\x27" or c == "\"":
        stack.append(c)
        state["word"] = True
        i += 1
        continue
    if s.startswith("$(", i):
        stack.append("$(")
        cur.append("$(")
        state["word"] = True
        i += 2
        continue
    if stack:
        if c == "(":
            stack.append("(")
        elif c == ")":
            stack.pop()
        cur.append(c)
        i += 1
        continue
    if c in " \t":
        flush()
    elif c in "\n;&|()":
        flush()
        tokens.append(("op", c))
    elif c in "<>":
        if cur and "".join(cur).isdigit():
            del cur[:]
            state["word"] = False
        else:
            flush()
        while i < n and s[i] in "<>&":
            i += 1
        state["drop"] = True
        while i < n and s[i] in " \t":
            i += 1
        continue
    elif c == "#" and not cur and not state["word"]:
        while i < n and s[i] != "\n":
            i += 1
        continue
    else:
        cur.append(c)
        state["word"] = True
    i += 1
flush()

# gh is the command word, after assignments and env, command, exec, sudo, time, nohup
words = []
for kind, text in tokens + [("op", ";")]:
    if kind == "w":
        words.append(text)
        continue
    k = 0
    while k < len(words) and (words[k] in ("env", "command", "exec", "sudo", "time", "nohup")
                              or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k])):
        k += 1
    cmd = words[k:k + 3]
    if len(cmd) == 3 and (cmd[0] == "gh" or cmd[0].endswith("/gh")) and cmd[1:] == ["pr", mode]:
        sys.stdout.write("".join(a + "\0" for a in words[k + 3:]))
        sys.exit(0)
    words = []
sys.exit(1)
'

# pg_args <mode> <text>: fills PG_ARGS; exit 3 when the text has no gh pr <mode>
pg_args() {
    local tmp rc=0 a
    tmp=$(mktemp)
    python3 -c "$PG_LEXER" "$1" "$2" > "$tmp" || rc=$?
    PG_ARGS=()
    while IFS= read -r -d '' a; do PG_ARGS+=("$a"); done < "$tmp"
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || pg_na "no gh pr $1 command found"
}

# pg_repo_applies <repo flag value>: exit 3 for another repository
pg_repo_applies() {
    [ -z "$1" ] && return 0
    [ "$(pg_lower "$1")" = "$(pg_lower "$CC_GITHUB_REPO")" ] || pg_na "another repository ($1)"
}

# ---- References ----
# Close[sd]? Fix(e[sd])? Resolve[sd]? Refs, then #N or <this repo>#N (case-insensitive);
# other repositories, URLs and bare #N are ignored. stdin: text; stdout: numbers
pg_text_refs() {
    _PG_REPO="$CC_GITHUB_REPO" python3 -c '
import os, re, sys
repo = os.environ["_PG_REPO"].lower()
pat = re.compile(r"(?<![\w/.-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs):?[ \t]+(?:([\w.-]+/[\w.-]+))?#([0-9]+)(?!\w)", re.I)
for m in pat.finditer(sys.stdin.read()):
    if m.group(1) is None or m.group(1).lower() == repo:
        print(m.group(2))
'
}

# pg_issue_rule <N>: In Progress (status_key) and assigned, per github.sh board status
pg_issue_rule() {
    local n="$1" out err rc=0 facts key status assignees
    err=$(mktemp)
    out=$("$BASH" "$PG_GITHUB_SH" board status "$n" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        local msg
        msg=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("error", ""))' < "$err" 2>/dev/null || true)
        [ -n "$msg" ] || msg=$(grep -v '^[[:space:]]*$' "$err" | head -1 || true)
        rm -f "$err"
        if [ "$rc" -eq 1 ]; then
            pg_rule "#$n: ${msg:-not on the board}" "providers/github.sh board add $n, then board move $n progress"
            return 0
        fi
        echo "pr-guard: board status #$n failed: ${msg:-exit $rc}" >&2
        exit 2
    fi
    rm -f "$err"
    facts=$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("status_key") or "")
print(d.get("status") or "")
print(len(d.get("assignees") or []))' <<< "$out" 2>/dev/null) || { echo "pr-guard: board status #$n: unexpected answer" >&2; exit 2; }
    { read -r key || true; read -r status || true; read -r assignees || true; } <<< "$facts"
    [ "$key" = "progress" ] || \
        pg_rule "#$n is ${status:-without status} (${key:-no status key}), not In Progress" "providers/github.sh board move $n progress"
    [ "${assignees:-0}" -gt 0 ] || pg_rule "#$n has no assignee" "providers/github.sh issue assign $n <login>"
}

pg_board_configured() {
    [ "${CC_PROJECT_BOARD_PROVIDER:-github}" = "github" ] && [ -n "${CC_GITHUB_OWNER:-}" ] \
        && [ -n "${CC_PROJECT_NUMBER:-}" ] && [ -n "${CC_PROJECT_ID:-}" ] && [ -n "${CC_STATUS_FIELD_ID:-}" ]
}

# ---- check create ----
pg_check_create() {
    local title="" body="" body_file="" head="" base="" repo="" assignee="" web="" fill=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--title)     shift; title="${1-}" ;;
            --title=*)      title="${1#*=}" ;;
            -b|--body)      shift; body="${1-}" ;;
            --body=*)       body="${1#*=}" ;;
            -F|--body-file) shift; body_file="${1--}" ;;
            --body-file=*)  body_file="${1#*=}" ;;
            -H|--head)      shift; head="${1-}" ;;
            --head=*)       head="${1#*=}" ;;
            -B|--base)      shift; base="${1-}" ;;
            --base=*)       base="${1#*=}" ;;
            -R|--repo)      shift; repo="${1-}" ;;
            --repo=*)       repo="${1#*=}" ;;
            -a|--assignee)  shift; assignee="${1-}" ;;
            --assignee=*)   assignee="${1#*=}" ;;
            -w|--web)       web=1 ;;
            -f|--fill|--fill-first|--fill-verbose) fill=1 ;;
            -l|--label|-m|--milestone|-p|--project|-r|--reviewer|-T|--template|--recover) shift ;;
            -[a-zA-Z][a-zA-Z]*)  # boolean cluster such as -dw
                case "$1" in *w*) web=1 ;; esac
                case "$1" in *f*) fill=1 ;; esac ;;
        esac
        [ $# -gt 0 ] && shift
    done
    pg_repo_applies "$repo"

    [ -n "$web" ] && pg_rule "--web: the browser flow cannot be checked" "create the PR in the terminal with --title and --body (or -F <file>)"
    [ -n "$assignee" ] || pg_rule "no --assignee" "add --assignee @me"

    local text="$title"$'\n'"$body"
    if [ "$body_file" = "-" ]; then
        pg_rule "-F -: a body from stdin cannot be checked" "write the body to a file and pass -F <file>, or use --body"
    elif [ -n "$body_file" ]; then
        if [ -f "$body_file" ] && [ -r "$body_file" ]; then
            text="$text"$'\n'"$(cat "$body_file")"
        else
            pg_rule "body file $body_file not found" "pass an existing file to -F"
        fi
    fi
    if [ -n "$fill" ]; then
        local b="${base:-${CC_BRANCH_BASE:-main}}" log=""
        log=$(git log --format=%B "origin/$b..HEAD" 2>/dev/null) || log=$(git log --format=%B "$b..HEAD" 2>/dev/null) || log=""
        text="$text"$'\n'"$log"
    fi

    local branch="${head#*:}" issues="" type=""
    [ -n "$branch" ] || branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [[ "$branch" =~ ^([A-Za-z0-9_-]+)/([0-9]+)(-|$) ]]; then
        issues="${BASH_REMATCH[2]}"
    fi
    case "$branch" in */*) type="${branch%%/*}" ;; esac
    issues=$(printf '%s\n%s\n' "$issues" "$(pg_text_refs <<< "$text")" | awk 'NF && !seen[$0]++')

    local title_type=""
    [[ "$title" =~ ^([a-z]+)(\([^\)]*\))?!?: ]] && title_type="${BASH_REMATCH[1]}"

    if [ -z "$issues" ]; then
        local t optional=""
        for t in ${CC_PR_GUARD_ISSUE_OPTIONAL:-}; do
            [ -n "$t" ] && { [ "$t" = "$type" ] || [ "$t" = "$title_type" ]; } && optional=1
        done
        [ -n "$optional" ] || pg_rule "no issue referenced (branch '${branch:-?}')" \
            "name the branch <type>/<N>-slug or write 'Refs #N' (or Fixes/Closes/Resolves #N) in the title or body"
    elif pg_board_configured; then
        local n
        for n in $issues; do pg_issue_rule "$n"; done
    else
        echo "pr-guard: board not configured, issue status not checked"
    fi
    local list
    # shellcheck disable=SC2086  # one number per word
    list=$(printf '#%s ' $issues)
    pg_verdict "gh pr create" "${issues:+issues ${list% }}"
}

# ---- ready / merge helpers ----

# pg_pr_view <selector>: sets PR_NUMBER PR_STATE PR_DRAFT PR_HEAD PR_BASE
pg_pr_view() {
    local sel="$1" json facts
    if [ -z "$sel" ]; then
        sel=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        [ -n "$sel" ] && [ "$sel" != "HEAD" ] || pg_na "no PR given and no current branch"
    fi
    json=$(pg_gh pr view "$sel" --repo "$CC_GITHUB_REPO" --json number,state,isDraft,headRefOid,baseRefName) || exit $?
    facts=$(python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("number", "state", "isDraft", "headRefOid", "baseRefName"):
    print(str(d.get(k, "")).lower() if k == "isDraft" else d.get(k, ""))' <<< "$json" 2>/dev/null) \
        || { echo "pr-guard: gh pr view: unexpected answer" >&2; exit 2; }
    { read -r PR_NUMBER || true; read -r PR_STATE || true; read -r PR_DRAFT || true
      read -r PR_HEAD || true; read -r PR_BASE || true; } <<< "$facts"
    [[ "$PR_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo "pr-guard: gh pr view: no head commit" >&2; exit 2; }
    [ "$PR_STATE" = "OPEN" ] || pg_na "PR #$PR_NUMBER is $PR_STATE"
}

# Combined commit status of PR_HEAD, fetched once (checks and cc-review)
pg_fetch_status() {
    [ -n "$STATUS_JSON" ] && return 0
    STATUS_JSON=$(pg_gh api "repos/$CC_GITHUB_REPO/commits/$PR_HEAD/status?per_page=100") || exit $?
}

# Sets REQUIRED (newline list) and REQUIRED_SOURCE (ruleset|protection|none)
pg_required_checks() {
    local rules branch
    rules=$(pg_gh api "repos/$CC_GITHUB_REPO/rules/branches/$PR_BASE") || exit $?
    REQUIRED=$(python3 -c '
import json, sys
seen = []
for r in json.load(sys.stdin) or []:
    if r.get("type") == "required_status_checks":
        for c in (r.get("parameters") or {}).get("required_status_checks") or []:
            if c.get("context") and c["context"] not in seen:
                seen.append(c["context"])
print("\n".join(seen))' <<< "$rules" 2>/dev/null) || { echo "pr-guard: rules: unexpected answer" >&2; exit 2; }
    REQUIRED_SOURCE=ruleset
    [ -n "$REQUIRED" ] && return 0
    branch=$(pg_gh api "repos/$CC_GITHUB_REPO/branches/$PR_BASE") || exit $?
    REQUIRED=$(python3 -c '
import json, sys
rsc = ((json.load(sys.stdin).get("protection") or {}).get("required_status_checks") or {})
seen = []
for c in list(rsc.get("contexts") or []) + [x.get("context") for x in rsc.get("checks") or []]:
    if c and c not in seen:
        seen.append(c)
print("\n".join(seen))' <<< "$branch" 2>/dev/null) || { echo "pr-guard: branch: unexpected answer" >&2; exit 2; }
    REQUIRED_SOURCE=protection
    [ -n "$REQUIRED" ] || REQUIRED_SOURCE=none
}

# pg_checks_not_green: prints "<name>\t<state>" for each required check (or, with
# none required, each check on PR_HEAD except cc-review) that is not green.
# Runs in $( ): the caller runs pg_fetch_status first, so the status is fetched once.
pg_checks_not_green() {
    local runs
    runs=$(pg_gh api "repos/$CC_GITHUB_REPO/commits/$PR_HEAD/check-runs?per_page=100") || exit $?
    _PG_RUNS="$runs" _PG_STATUS="$STATUS_JSON" _PG_REQUIRED="$REQUIRED" _PG_REVIEW="$PG_REVIEW_CONTEXT" python3 -c '
import json, os
env = os.environ
state = {}
for r in sorted(json.loads(env["_PG_RUNS"]).get("check_runs") or [], key=lambda r: r.get("id") or 0):
    if r.get("status") != "completed":
        s = "pending"
    elif r.get("conclusion") in ("success", "neutral", "skipped"):
        s = "success"
    else:
        s = r.get("conclusion") or "failure"
    state[r.get("name", "")] = s
for st in json.loads(env["_PG_STATUS"]).get("statuses") or []:
    state[st.get("context", "")] = st.get("state", "")
required = [r for r in env["_PG_REQUIRED"].splitlines() if r]
names = required or sorted(k for k in state if k != env["_PG_REVIEW"])
if not names:
    print("(any check)\tmissing")
for name in names:
    if state.get(name, "missing") != "success":
        print("%s\t%s" % (name, state.get(name, "missing")))
' || { echo "pr-guard: check runs: unexpected answer" >&2; exit 2; }
}

# pg_checks_rule <fix>: one failure per check that is not green
pg_checks_rule() {
    local bad name st
    pg_fetch_status
    bad=$(pg_checks_not_green) || exit $?
    while IFS="$(printf '\t')" read -r name st; do
        [ -n "$name" ] || continue
        if [ "$name" = "(any check)" ]; then
            pg_rule "no checks reported on HEAD ${PR_HEAD:0:7}" "$1"
        else
            pg_rule "check '$name' is $st on HEAD ${PR_HEAD:0:7}" "$1"
        fi
    done <<< "$bad"
}

# pg_stamp_reason: empty when .cognitive-core/gate/<PR_HEAD>.json is a valid PASS stamp
pg_stamp_reason() {
    local top file
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repository"; return 0; }
    file="$top/.cognitive-core/gate/$PR_HEAD.json"
    [ -f "$file" ] || { echo "no gate stamp for ${PR_HEAD:0:7}"; return 0; }
    _PG_SHA="$PR_HEAD" _PG_HASH="$(pg_conf_hash)" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("gate stamp unreadable"); sys.exit(0)
if not isinstance(d, dict) or d.get("format") != 1:
    print("gate stamp format unknown")
elif d.get("sha") != os.environ["_PG_SHA"]:
    print("gate stamp is for another commit")
elif d.get("result") != "PASS":
    print("gate result is %s" % (d.get("result") or "missing"))
elif d.get("conf_hash") != os.environ["_PG_HASH"]:
    print("gate config changed since the stamp")
' < "$file"
}

# pg_review_rule: cc-review success on PR_HEAD
pg_review_rule() {
    local st
    pg_fetch_status
    st=$(_PG_CTX="$PG_REVIEW_CONTEXT" python3 -c '
import json, os, sys
for s in json.load(sys.stdin).get("statuses") or []:
    if s.get("context") == os.environ["_PG_CTX"]:
        print(s.get("state", "")); break' <<< "$STATUS_JSON" 2>/dev/null) || { echo "pr-guard: status: unexpected answer" >&2; exit 2; }
    [ "$st" = "success" ] || pg_rule "$PG_REVIEW_CONTEXT is ${st:-missing} on HEAD ${PR_HEAD:0:7}" \
        "review this HEAD, then record it: pr-guard.sh review-record $PR_NUMBER --sha $PR_HEAD --result PASS --body-file <review>"
}

# ---- check ready ----
pg_check_ready() {
    local sel="" repo="" local_head source="${CC_PR_GATE_SOURCE:-either}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --undo)    pg_na "gh pr ready --undo" ;;
            -R|--repo) shift; repo="${1-}" ;;
            --repo=*)  repo="${1#*=}" ;;
            -*) ;;
            *)         [ -n "$sel" ] || sel="$1" ;;
        esac
        [ $# -gt 0 ] && shift
    done
    pg_repo_applies "$repo"
    pg_pr_view "$sel"
    [ "$PR_DRAFT" = "true" ] || pg_na "PR #$PR_NUMBER is not a draft"

    local_head=$(git rev-parse HEAD 2>/dev/null || true)
    [ "$local_head" = "$PR_HEAD" ] || pg_rule "local HEAD ${local_head:0:7} is not the PR head ${PR_HEAD:0:7}" \
        "push your commits (git push) or check out the PR branch and pull"

    local gate_fix="run the project gate for this HEAD (pr/ci-gate.sh) or wait for green required checks"
    case "$source" in
        stamp)
            local why
            why=$(pg_stamp_reason)
            [ -z "$why" ] || pg_rule "$why" "$gate_fix" ;;
        checks)
            pg_required_checks
            pg_checks_rule "wait for CI, or fix the failure and push" ;;
        either)
            local why bad
            why=$(pg_stamp_reason)
            if [ -n "$why" ]; then
                pg_required_checks
                pg_fetch_status
                bad=$(pg_checks_not_green) || exit $?
                if [ -n "$bad" ]; then
                    bad=$(printf '%s\n' "$bad" | awk -F '\t' 'NF { printf "%s%s %s", (n++ ? ", " : ""), $1, $2 }')
                    pg_rule "no gate evidence for HEAD ${PR_HEAD:0:7}: $why; checks not green: $bad" "$gate_fix"
                fi
            fi ;;
        *)
            pg_rule "CC_PR_GATE_SOURCE=$source is not stamp, checks or either" "fix CC_PR_GATE_SOURCE in cognitive-core.conf" ;;
    esac
    pg_review_rule
    pg_verdict "gh pr ready" "#$PR_NUMBER at ${PR_HEAD:0:7}"
}

# ---- check merge ----
pg_check_merge() {
    local sel="" repo="" auto=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --admin)   pg_rule "--admin bypasses branch protection" "merge without --admin (--auto waits for the checks)" ;;
            --auto)    auto=1 ;;
            --disable-auto) pg_na "gh pr merge --disable-auto" ;;
            -R|--repo) shift; repo="${1-}" ;;
            --repo=*)  repo="${1#*=}" ;;
            -t|--subject|-b|--body|-F|--body-file|-A|--author-email|--match-head-commit) shift ;;
            -*) ;;
            *)         [ -n "$sel" ] || sel="$1" ;;
        esac
        [ $# -gt 0 ] && shift
    done
    pg_repo_applies "$repo"
    pg_pr_view "$sel"
    [ "$PR_DRAFT" = "true" ] && pg_rule "PR #$PR_NUMBER is a draft" "mark it ready first (gh pr ready $PR_NUMBER)"

    pg_required_checks
    # --auto: GitHub itself waits for checks it requires; without required checks it would merge at once
    if [ -n "$auto" ] && [ "$REQUIRED_SOURCE" != "none" ]; then
        :
    else
        pg_checks_rule "wait for CI, or fix the failure and push"
    fi
    pg_review_rule
    pg_verdict "gh pr merge" "#$PR_NUMBER at ${PR_HEAD:0:7}"
}

# ---- review-record ----
pg_review_record() {
    local pr="${1:-}" sha="" result="" body_file="" head
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --sha)       shift; sha="${1-}" ;;
            --result)    shift; result="${1-}" ;;
            --body-file) shift; body_file="${1-}" ;;
            *)           pg_usage "unknown argument: $1" ;;
        esac
        [ $# -gt 0 ] && shift
    done
    [[ "$pr" =~ ^[0-9]+$ ]] || pg_usage "usage: review-record <PR> --sha <sha> --result PASS|FAIL --body-file <file>"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || pg_usage "--sha needs the full 40-character commit SHA"
    case "$result" in PASS|FAIL) ;; *) pg_usage "--result must be PASS or FAIL" ;; esac
    [ -f "$body_file" ] && [ -s "$body_file" ] || pg_usage "--body-file must name a non-empty file"
    pg_load_config

    head=$(pg_gh pr view "$pr" --repo "$CC_GITHUB_REPO" --json headRefOid --jq .headRefOid) || exit $?
    if [ "$head" != "$sha" ]; then
        echo "pr-guard: review-record refused: ${sha:0:7} is not the head of PR #$pr (${head:0:7})"
        echo "  Fix: review the current head ${head:0:7} and record that SHA"
        exit 1
    fi

    local state=success comment
    [ "$result" = "PASS" ] || state=failure
    comment=$(mktemp)
    { printf '<!-- cc-review:v1 result=%s sha=%s -->\n\n' "$result" "$sha"; cat "$body_file"; } > "$comment"
    # The comment first: a status without its review text never exists
    (pg_gh pr comment "$pr" --repo "$CC_GITHUB_REPO" --body-file "$comment" >/dev/null) || { rm -f "$comment"; exit 2; }
    rm -f "$comment"
    pg_gh api "repos/$CC_GITHUB_REPO/statuses/$sha" -f state="$state" -f context="$PG_REVIEW_CONTEXT" \
        -f description="Review $result" >/dev/null || exit $?
    echo "pr-guard: review $result recorded for PR #$pr at ${sha:0:7}"
}

# =============================================================================
# MAIN
# =============================================================================
case "${1:-}" in
    check)
        mode="${2:-}"
        case "$mode" in create|ready|merge) ;; *) pg_usage "usage: check create|ready|merge \"<command text>\"" ;; esac
        [ $# -ge 3 ] || pg_usage "check $mode: command text required"
        pg_args "$mode" "$3"
        git rev-parse --git-dir >/dev/null 2>&1 || pg_na "not a git repository"
        pg_load_config
        set -- ${PG_ARGS[@]+"${PG_ARGS[@]}"}
        case "$mode" in
            create) pg_check_create "$@" ;;
            ready)  pg_check_ready "$@" ;;
            merge)  pg_check_merge "$@" ;;
        esac ;;
    review-record) shift; pg_review_record "$@" ;;
    conf-hash) pg_load_config; pg_conf_hash ;;
    *) pg_usage "usage: pr-guard.sh check create|ready|merge \"<command text>\" | review-record <PR> --sha <sha> --result PASS|FAIL --body-file <file> | conf-hash" ;;
esac
