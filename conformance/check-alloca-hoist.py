#!/usr/bin/env python3
# check-alloca-hoist.py — verify the "all allocas are hoisted to the
# function entry block" invariant on bnc-emitted LLVM IR.
#
# WHY: an `alloca` in a non-entry basic block (e.g. a loop body or an
# if-branch) allocates fresh native stack every time control reaches it
# and is NOT reclaimed until the function returns — so a construct that
# emits an un-hoisted alloca inside a loop leaks native stack per
# iteration and eventually SIGSEGVs (stack overflow).  bnc's codegen
# hoists every alloca to the entry block via emitFuncDbg's alloca
# pre-pass; this checker is the machine-checkable statement of that
# invariant.  It is a STATIC, construct-agnostic detector for the whole
# class: any new lowering path that emits an un-hoisted alloca trips it,
# without needing a high-iteration runtime repro for that specific shape.
#
# USAGE:
#   bnc --emit-llvm ... prog.bn | check-alloca-hoist.py [--name LABEL]
#   check-alloca-hoist.py FILE.ll [FILE2.ll ...]
# Exit status 0 if all allocas are entry-block; 1 if any violation.
#
# The entry block is the first basic block of each `define`.  A label
# line (`name:`) starts a basic block; the label appearing as the first
# body line names the entry block, any later label starts a new (non-
# entry) block.

import re
import sys

LABEL_RE = re.compile(r'^[A-Za-z0-9._$-]+:\s*(;.*)?$')
DEFINE_RE = re.compile(r'^\s*define\b.*\{\s*$')
ALLOCA_RE = re.compile(r'^\s*%\S+\s*=\s*alloca\b')


def check_text(text, source):
    """Return a list of (source, func, lineno, line) violations."""
    violations = []
    in_func = False
    func_name = '?'
    block_idx = 0
    body_started = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip('\n')
        stripped = line.strip()
        if not in_func:
            m = DEFINE_RE.match(line)
            if m:
                in_func = True
                block_idx = 0
                body_started = False
                fm = re.search(r'@([A-Za-z0-9._$]+)', line)
                func_name = fm.group(1) if fm else '?'
            continue
        # inside a function
        if stripped == '}':
            in_func = False
            continue
        if stripped == '' or stripped.startswith(';'):
            continue
        if LABEL_RE.match(stripped):
            # A label names the entry block only if it is the first body
            # token; otherwise it opens a new (non-entry) block.
            if body_started:
                block_idx += 1
            body_started = True
            continue
        body_started = True
        if ALLOCA_RE.match(line) and block_idx >= 1:
            violations.append((source, func_name, lineno, stripped))
    return violations


def main(argv):
    label = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == '--name':
            label = argv[i + 1]
            i += 2
        else:
            files.append(argv[i])
            i += 1

    all_violations = []
    if files:
        for f in files:
            with open(f) as fh:
                all_violations += check_text(fh.read(), f)
    else:
        all_violations += check_text(sys.stdin.read(), label or '<stdin>')

    if all_violations:
        for (src, func, lineno, line) in all_violations:
            sys.stderr.write(
                f'ALLOCA-LEAK: {src}: {func} (line {lineno}): '
                f'non-entry-block alloca: {line}\n')
        sys.stderr.write(
            f'check-alloca-hoist: {len(all_violations)} non-entry alloca(s) '
            f'— each leaks native stack per execution of its block\n')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
