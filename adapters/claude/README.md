# Claude Code Adapter

This adapter translates universal cognitive-core skills to Claude Code's SKILL.md format.

## Overview

Claude Code uses Markdown-based skill definitions with YAML frontmatter. This adapter:

1. Reads universal `skill.yaml` format
2. Generates `SKILL.md` files for Claude Code
3. Handles capability mapping to allowed-tools
4. Preserves inheritance via `extends` directive

## Mapping

### Capabilities → Allowed Tools

| Universal Capability | Claude Tool |
|---------------------|-------------|
| `file_read` | `Read` |
| `file_write` | `Edit`, `Write` |
| `file_search` | `Grep` |
| `file_glob` | `Glob` |
| `shell_execute` | `Bash` |
| `web_fetch` | `WebFetch` |
| `web_search` | `WebSearch` |
| `human_interaction` | `AskUserQuestion` |

### Skill Format Translation

**Universal Format (skill.yaml)**:
```yaml
name: validate
version: 1.0.0
description: Universal input validation
category: atomic
capabilities:
  - file_read
  - file_search
inputs:
  - name: type
    type: enum[email|url|path]
    required: true
```

**Claude Format (SKILL.md)**:
```markdown
---
name: validate
description: Universal input validation
argument-hint: [type] [value]
allowed-tools: Read, Grep
---

# Validate

Universal input validation with multiple validators.

## Usage
/validate email user@example.com
/validate url https://example.com
/validate path /etc/passwd
```

## Installation

### Manual Installation

```bash
# Copy skills to Claude's skill directory
cp -r cognitive-core/skills/atomic/* ~/.claude/skills/

# For project-specific skills
cp -r cognitive-core/skills/cellular/templates/* .claude/skills/
```

### Using the Converter

```bash
# Convert single skill
python adapters/claude/convert.py skills/atomic/validate/skill.yaml

# Convert all skills
python adapters/claude/convert.py skills/ --output ~/.claude/skills/
```

## Generated settings.json

`install.sh` renders `core/templates/settings.json.tmpl` and passes it through
`settings-render.py` (python3 required):

- A framework hook is wired only if it is in `CC_HOOKS` and installed in `.claude/hooks/`.
- `CC_SECURITY_LEVEL="strict"` adds no allow rules.
- An existing `settings.json` is merged, not overwritten: user hooks, permissions, env and other
  keys stay; framework hook wiring follows `CC_HOOKS`. A changed file is backed up to
  `settings.json.bak.<timestamp>` and the diff is printed.

The cognitive-core MCP server (`.cognitive-core/mcp-server/`, `.mcp.json`) is installed only with
`CC_MCP_SERVER="true"`; Claude Code runs the hooks natively.

## Skill Locations

| Scope | Location | Purpose |
|-------|----------|---------|
| Global | `~/.claude/skills/` | Available to all projects |
| Project | `.claude/skills/` | Project-specific skills |

## Inheritance

Claude supports skill inheritance via `extends`:

```markdown
---
name: python-patterns
extends: global:check-pattern
description: Python/FastAPI patterns
---

# Python Patterns

Extends global check-pattern with Python-specific rules.

## Additional Patterns
- Type hints required (PEP 484)
- Pydantic for validation
- async/await for I/O
```

## Fitness Integration

Claude skills can include fitness evaluation:

```markdown
## Fitness Criteria

| Function | Threshold |
|----------|-----------|
| syntax_valid | 1.0 |
| pattern_compliance | 0.9 |
| no_security_issues | 1.0 |

## Gate Integration
- lint: threshold 0.60
- commit: threshold 0.80
- deploy: threshold 0.95
```

## Examples

See `examples/` directory for complete Claude skill implementations.
