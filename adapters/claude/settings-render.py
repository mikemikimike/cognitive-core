#!/usr/bin/env python3
# SPDX-License-Identifier: FSL-1.1-ALv2
"""Render .claude/settings.json from the rendered template (#345).

- Wires a framework hook only if it is selected (CC_HOOKS) and installed.
- CC_SECURITY_LEVEL=strict: no allow rules from the template.
- An existing settings.json is merged, not overwritten: user hooks, permissions,
  env and other keys stay; framework hook wiring is replaced by the selection.

Usage:
  settings-render.py TEMPLATE OUT HOOKS_DIR "SELECTED" SECURITY_LEVEL "FRAMEWORK_HOOKS"

Standard library only. Prints a unified diff when an existing file changes.
"""
import difflib
import json
import os
import shutil
import sys
import time

HOOK_PREFIX = "$CLAUDE_PROJECT_DIR/.claude/hooks/"


def hook_name(entry):
    """Framework hook name of a hook entry, or None for anything else."""
    cmd = entry.get("command", "") if isinstance(entry, dict) else ""
    if not cmd.startswith(HOOK_PREFIX) or not cmd.endswith(".sh"):
        return None
    name = cmd[len(HOOK_PREFIX):-3]
    return name if "/" not in name else None


def prune(hooks, keep):
    """Hooks config with only the hook entries for which keep(entry) is true."""
    out = {}
    for event, groups in (hooks or {}).items():
        new_groups = []
        for group in groups:
            entries = [e for e in group.get("hooks", []) if keep(e)]
            if entries:
                new_groups.append(dict(group, hooks=entries))
        if new_groups:
            out[event] = new_groups
    return out


def merge_hooks(generated, existing, framework):
    """Generated wiring first; user entries kept, framework entries replaced."""
    user = prune(existing, lambda e: hook_name(e) not in framework)
    merged = {event: [dict(g, hooks=list(g["hooks"])) for g in groups]
              for event, groups in generated.items()}
    for event, groups in user.items():
        target = merged.setdefault(event, [])
        for group in groups:
            same = next((g for g in target if g.get("matcher") == group.get("matcher")), None)
            if same is None:
                target.append(group)
            else:
                same["hooks"].extend(e for e in group["hooks"] if e not in same["hooks"])
    return merged


def union(first, second):
    return list(first) + [x for x in second if x not in first]


def main(argv):
    if len(argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    template, out, hooks_dir, selected, level, framework = argv[1:]
    selected = set(selected.split())
    framework = set(framework.split()) | selected

    with open(template, encoding="utf-8") as fh:
        gen = json.load(fh)

    def wanted(entry):
        name = hook_name(entry)
        if name is None:
            return True
        return name in selected and os.path.isfile(os.path.join(hooks_dir, name + ".sh"))

    dropped = sorted({hook_name(e) for groups in gen.get("hooks", {}).values()
                      for g in groups for e in g.get("hooks", [])
                      if hook_name(e) and not wanted(e)})
    gen["hooks"] = prune(gen.get("hooks"), wanted)
    strict = level == "strict"
    perms = gen.setdefault("permissions", {})
    template_allow = list(perms.get("allow", []))
    if strict:
        perms["allow"] = []

    old_text = None
    if os.path.isfile(out):
        with open(out, encoding="utf-8") as fh:
            old_text = fh.read()
        try:
            cur = json.loads(old_text)
        except json.JSONDecodeError:
            print(f"settings.json is not valid JSON, not merged: {out}", file=sys.stderr)
            return 1
        result = dict(cur)
        for key, value in gen.items():
            result.setdefault(key, value)
        result["hooks"] = merge_hooks(gen["hooks"], cur.get("hooks"), framework)
        cur_perms = cur.get("permissions", {})
        allow = cur_perms.get("allow", [])
        if strict:
            allow = [a for a in allow if a not in template_allow]
        result["permissions"] = dict(cur_perms,
                                     allow=union(allow, perms.get("allow", [])),
                                     deny=union(cur_perms.get("deny", []), perms.get("deny", [])))
        result["env"] = dict(cur.get("env", {}), **gen.get("env", {}))
    else:
        result = gen

    new_text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if old_text is not None and old_text != new_text:
        backup = f"{out}.bak.{time.strftime('%Y%m%d%H%M%S')}"
        shutil.copy2(out, backup)
        print(f"settings.json merged, previous file: {backup}")
        sys.stdout.writelines(difflib.unified_diff(
            old_text.splitlines(True), new_text.splitlines(True), "settings.json (before)",
            "settings.json (after)"))
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    if dropped:
        print("not wired (not selected or not installed): " + " ".join(dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
