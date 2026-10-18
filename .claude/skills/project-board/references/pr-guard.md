# PR Lifecycle Guard (`pr/pr-guard.sh`)

One script decides whether a PR may be created, marked ready or merged. The
`validate-bash.sh` hook and the GitHub workflow call it with plain arguments;
every GitHub call happens inside the script. GitHub only (`#N` references).

```
pr/pr-guard.sh check create|ready|merge "<command text>"
pr/pr-guard.sh review-record <PR> --sha <sha> --result PASS|FAIL --body-file <file>
pr/pr-guard.sh conf-hash
```

`<command text>` is the Bash command as typed, heredoc bodies included. The
guard reads the first `gh pr <mode>` in it.

| Exit | Meaning |
|------|---------|
| 0 | allowed |
| 1 | a rule is violated (each failure is listed with its fix), or a usage error |
| 2 | GitHub failure (network, auth, unexpected answer): report it, do not work around it |
| 3 | not applicable (no such command, not a git repository, no conf or `CC_GITHUB_REPO`, another `--repo`, closed PR, `ready` on a non-draft or `--undo`, `merge --disable-auto`) |

## Rules

**References**: the branch `<type>/<N>-slug`, and `Close[sd]` / `Fix(e[sd])` /
`Resolve[sd]` / `Refs` followed by `#N` (case-insensitive) in the title, the body,
the `-F` file and, with `--fill`, the commit messages since the base branch.
`owner/repo#N` counts only for this repository; other repositories, URLs and a
bare `#N` are ignored.

**`check create`**
- every referenced issue is In Progress (`status_key` of `providers/github.sh board status`) and has an assignee
- at least one issue is referenced, unless the branch type or the title's commit type is in `CC_PR_GUARD_ISSUE_OPTIONAL`
- the command carries `--assignee`; `--draft` is fine
- `--web` and `-F -` are refused (the guard cannot read them)
- the board rule is skipped (with a note) when the GitHub board is not configured

**`check ready`** (draft PRs)
- local `HEAD` is the PR head (pushed)
- gate evidence for the head, per `CC_PR_GATE_SOURCE`: `stamp` (a valid gate stamp, below),
  `checks` (required checks green), `either` (default)
- commit status `cc-review` is `success` on the head

**`check merge`**
- not a draft; `--admin` refused, `--auto` allowed
- required checks green on the head; with `--auto` and checks the server requires, GitHub waits for them
- `cc-review` is `success` on the head

**Required checks**: the base branch's rulesets (`GET repos/{o}/{r}/rules/branches/{base}`,
`required_status_checks` rules), else legacy branch protection (`GET repos/{o}/{r}/branches/{base}`),
else every check run and commit status on the head (except `cc-review`), at least one.
A check is green when it completed as success, neutral or skipped (check runs) or is `success` (statuses).

**`review-record`** refuses a SHA that is not the PR head, then posts a PR comment that starts
with `<!-- cc-review:v1 result=PASS|FAIL sha=<sha> -->` and sets the commit status `cc-review`
(`success` or `failure`) on that SHA. A new commit has no `cc-review` status until it is reviewed.

## Configuration (`cognitive-core.conf`)

| Key | Default | Meaning |
|-----|---------|---------|
| `CC_GITHUB_REPO` | (required) | `owner/repo` the guard applies to |
| `CC_PR_GATE_SOURCE` | `either` | `stamp`, `checks` or `either`; any other value is a violation |
| `CC_PR_GUARD_ISSUE_OPTIONAL` | (empty) | commit/branch types that need no issue, e.g. `"docs chore"` |
| `CC_BRANCH_BASE` | `main` | base for `--fill` when `--base` is not given |

## Gate stamp format

`.cognitive-core/gate/<sha>.json` at the repository root, one file per commit, written by the
project gate (`pr/ci-gate.sh`, #386). The stamp is advisory; server checks are authoritative.

```json
{
  "format": 1,
  "sha": "<40-character commit SHA>",
  "result": "PASS",
  "conf_hash": "<sha256 hex>",
  "created_at": "2026-10-18T12:00:00Z",
  "tool": "ci-gate.sh",
  "tool_version": "1.8.0",
  "steps": [{"name": "unit", "exit": 0, "seconds": 12}]
}
```

| Field | Meaning |
|-------|---------|
| `format` | stamp format version, `1` |
| `sha` | commit the gate ran on; must equal the file name and the PR head |
| `result` | `PASS`, `FAIL` or `NONE` (no step configured); only `PASS` is evidence |
| `conf_hash` | gate config hash at run time; must equal `pr-guard.sh conf-hash` now |
| `created_at` | UTC timestamp, ISO 8601 |
| `tool`, `tool_version` | writer and cognitive-core version |
| `steps` | per step: name, exit code, duration in seconds (informational) |

`conf_hash` is the SHA-256 (hex) of these lines, each ending in `\n`, values as loaded from the conf:

```
CC_GATE_STEPS=<value>
CC_GATE_<STEP>_CMD=<value>     one line per step of CC_GATE_STEPS (default: lint unit integration), STEP upper-cased
CC_LINT_COMMAND=<value>
CC_TEST_COMMAND=<value>
```

A change to any of them invalidates every stamp. The reader rejects a stamp with an unknown
`format`, another `sha`, a `result` other than `PASS`, or another `conf_hash`.
