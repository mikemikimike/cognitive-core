"""Find `gh pr <mode>` in a Bash command text for pr-guard.sh (#385).

Usage: python3 -I cmd_lexer.py <mode> <command text>

A small shell lexer, not a shell: quotes ('', "", $''), backslashes, $( ),
backticks, heredocs (their body joins the word that holds the operator, so
--body "$(cat <<'EOF' ... EOF)" keeps its text) and redirections. $( ) and
backtick contents are analysed as commands of their own.

gh counts in command position: first word of a simple command, after
reserved words ({ ! if then do else elif while until), assignments and the
prefixes env, sudo, time, timeout, nice, command, exec, nohup (with options).

Exit codes:
  0   found once; the arguments after `gh pr <mode>` on stdout, NUL-separated
  10  not found
  11  found more than once
  14  not found; mentioned only as arguments of echo, printf or gh
anything else: the lexer failed (the caller fails closed)
"""
from __future__ import annotations

import re
import sys

RESERVED = {"{", "}", "!", "if", "then", "do", "else", "elif", "while", "until"}
# prefix command -> its options that take a value
PREFIXES = {
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-U", "-r", "-t", "-T", "-D"},
    "time": {"-f", "-o"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "command": set(),
    "exec": {"-a"},
    "nohup": set(),
}
HARMLESS = {"echo", "printf"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
ANSI_C = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "e": "\x1b", "a": "\a", "b": "\b"}


def lex(s: str) -> tuple[list[tuple[str, str]], list[str]]:
    """Top-level tokens ("w", word) / ("op", char) and the texts of $( ) and backticks."""
    tokens: list[tuple[str, str]] = []
    subs: list[str] = []
    cur: list[str] = []
    stack: list[tuple[str, int]] = []      # open contexts: ', ", $', $(, (, `
    pending: list[tuple[bool, str]] = []   # heredocs waiting for the end of the line
    word = False
    drop = False

    def flush() -> None:
        nonlocal word, drop
        if word or cur:
            if not drop:
                tokens.append(("w", "".join(cur)))
            drop = False
        del cur[:]
        word = False

    i, n = 0, len(s)
    while i < n:
        c = s[i]
        top = stack[-1][0] if stack else ""
        if top == "'":
            if c == "'":
                stack.pop()
            else:
                cur.append(c)
            i += 1
            continue
        if top == "$'":
            if c == "'":
                stack.pop()
            elif c == "\\" and i + 1 < n:
                cur.append(ANSI_C.get(s[i + 1], "\\" + s[i + 1]))
                i += 1
            else:
                cur.append(c)
            i += 1
            continue
        if top == "`":
            if c == "\\" and i + 1 < n:
                cur.append(s[i:i + 2])
                i += 2
                continue
            if c == "`":
                subs.append(s[stack.pop()[1]:i])
            cur.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            nxt = s[i + 1]
            if nxt != "\n":
                if top == '"' and nxt not in '$`"\\':
                    cur.append(c)
                cur.append(nxt)
                word = True
            i += 2
            continue
        if c == "`":
            stack.append(("`", i + 1))
            cur.append(c)
            word = True
            i += 1
            continue
        if top == '"':
            if c == '"':
                stack.pop()
            elif s.startswith("$(", i):
                stack.append(("$(", i + 2))
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
            if j < n and s[j] in "'\"":
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
        if s.startswith("$'", i):
            stack.append(("$'", i))
            word = True
            i += 2
            continue
        if c in "'\"":
            stack.append((c, i))
            word = True
            i += 1
            continue
        if s.startswith("$(", i):
            stack.append(("$(", i + 2))
            cur.append("$(")
            word = True
            i += 2
            continue
        if stack:
            if c == "(":
                stack.append(("(", i))
            elif c == ")":
                kind, start = stack.pop()
                if kind == "$(":
                    subs.append(s[start:i])
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
                word = False
            else:
                flush()
            while i < n and s[i] in "<>&":
                i += 1
            drop = True
            while i < n and s[i] in " \t":
                i += 1
            continue
        elif c == "#" and not cur and not word:
            while i < n and s[i] != "\n":
                i += 1
            continue
        else:
            cur.append(c)
            word = True
        i += 1
    flush()
    return tokens, subs


def command_start(words: list[str]) -> int:
    """Index of the command word: past reserved words, assignments and prefixes with their options."""
    k = 0
    while k < len(words):
        w = words[k]
        if w in RESERVED or ASSIGNMENT.match(w):
            k += 1
        elif w in PREFIXES:
            takes_value = PREFIXES[w]
            k += 1
            while k < len(words) and (words[k].startswith("-") or ASSIGNMENT.match(words[k])):
                k += 2 if words[k] in takes_value else 1
            if w == "timeout" and k < len(words):
                k += 1          # the duration
        else:
            break
    return k


def is_gh(word: str) -> bool:
    return word == "gh" or word.endswith("/gh")


def analyse(s: str, mode: str, loose: re.Pattern[str]) -> tuple[list[list[str]], list[str]]:
    """Argument lists of every `gh pr <mode>`, and the command words of commands that mention it otherwise."""
    tokens, subs = lex(s)
    found: list[list[str]] = []
    mentions: list[str] = []
    words: list[str] = []
    for kind, text in tokens + [("op", ";")]:
        if kind == "w":
            words.append(text)
            continue
        k = command_start(words)
        if words[k:k + 1] and is_gh(words[k]) and words[k + 1:k + 3] == ["pr", mode]:
            found.append(words[k + 3:])
        elif loose.search(" ".join(words)):
            mentions.append(words[k] if k < len(words) else "")
        words = []
    for sub in subs:
        f, m = analyse(sub, mode, loose)
        found += f
        mentions += m
    return found, mentions


def main() -> int:
    mode, text = sys.argv[1], sys.argv[2]
    # the same loose pattern pr-guard.sh applies to the raw text
    loose = re.compile(r"(^|[^\w])gh([^\w]|$)(.*\s)?pr\s+" + re.escape(mode) + r"(\W|$)", re.S)
    found, mentions = analyse(text, mode, loose)
    if len(found) > 1:
        return 11
    if found:
        sys.stdout.write("".join(a + "\0" for a in found[0]))
        return 0
    if mentions and all(m in HARMLESS or is_gh(m) for m in mentions):
        return 14
    return 10


if __name__ == "__main__":
    sys.exit(main())
