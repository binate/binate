#!/usr/bin/env python3
"""Copy source files with comments injected, for checking bnfmt's comment
placement in lists.

usage: inject_comments.py <mode> <seed> <out dir> <file>...

Writes each file to <out dir>/<its path with / replaced by __>, with numbered
comments (`K<n>`) added at random:
  1  a block comment before an element after `, `, or after an opener; a line
     comment after a trailing comma (lines with strings or comments untouched)
  2  as 1, placed by a scan that skips string and character literals, so lines
     with strings get comments too
  3  an own-line line or block comment before a line that continues a list, a
     line comment after an opener ending a line, a one- or two-line block
     comment after a trailing comma
Package, import and annotation lines, and lines with a backquote (modes 2 and
3), are copied unchanged.  The files depend only on the arguments and inputs.
"""
import os
import random
import re
import sys

if len(sys.argv) < 4:
    sys.exit(__doc__.strip())
MODE, SEED, OUT, FILES = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
R = random.Random(SEED)
N = [0]


def mark():
    """Return a fresh comment marker, numbered across all the files."""
    N[0] += 1
    return 'K%d' % N[0]


def code_positions(ln):
    """Return the indexes of ln outside string and character literals, up to a
    comment, and whether ln has a comment."""
    res = []
    i = 0
    q = None
    while i < len(ln):
        c = ln[i]
        if q:
            if c == '\\':
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in '"\'':
            q = c
            i += 1
            continue
        if ln.startswith('//', i) or ln.startswith('/*', i):
            return res, True
        res.append(i)
        i += 1
    return res, False


def mode1(lines):
    out = []
    for ln in lines:
        s = ln.lstrip()
        if ('"' in ln or "'" in ln or '//' in ln or '/*' in ln or s.startswith('#')
                or s.startswith('import')):
            out.append(ln)
            continue
        if ', ' in ln and R.random() < 0.5:
            parts = ln.split(', ')
            i = R.randrange(1, len(parts))
            parts[i] = '/* %s */ ' % mark() + parts[i]
            ln = ', '.join(parts)
        m = list(re.finditer(r'[\(\[\{](?=[A-Za-z0-9_&*@-])', ln))
        if m and R.random() < 0.3:
            mm = R.choice(m)
            ln = ln[:mm.end()] + '/* %s */ ' % mark() + ln[mm.end():]
        if ln.rstrip().endswith(',') and R.random() < 0.7:
            ln = ln + ' // %s' % mark()
        out.append(ln)
    return out


def skipped(ln):
    s = ln.lstrip()
    return (s.startswith('#') or s.startswith('import') or s.startswith('package')
            or '`' in ln)


def mode2(lines):
    out = []
    for ln in lines:
        if skipped(ln):
            out.append(ln)
            continue
        pos, hascomment = code_positions(ln)
        ps = set(pos)
        commas = [i for i in pos if ln.startswith(', ', i) and i + 1 in ps]
        if commas and R.random() < 0.5:
            i = R.choice(commas) + 2
            ln = ln[:i] + '/* %s */ ' % mark() + ln[i:]
            pos, hascomment = code_positions(ln)
        openers = [i for i in pos if ln[i] in '([{' and i + 1 < len(ln)
                   and (ln[i + 1].isalnum() or ln[i + 1] in '_&*@-"')]
        if openers and R.random() < 0.3:
            i = R.choice(openers) + 1
            ln = ln[:i] + '/* %s */ ' % mark() + ln[i:]
            pos, hascomment = code_positions(ln)
        if not hascomment and ln.rstrip().endswith(',') and R.random() < 0.7:
            ln = ln + ' // %s' % mark()
        out.append(ln)
    return out


def mode3(lines):
    out = []
    prev = ''
    for ln in lines:
        s = ln.lstrip()
        if skipped(ln):
            out.append(ln)
            prev = ln
            continue
        _, hascomment = code_positions(ln)
        _, prevcomment = code_positions(prev)
        if (not prevcomment and (prev.rstrip().endswith(',') or prev.rstrip().endswith('('))
                and R.random() < 0.4):
            ind = ln[:len(ln) - len(s)]
            k = mark()
            out.append(ind + ('// %s' % k if R.random() < 0.5 else '/* %s */' % k))
        if not hascomment and ln.rstrip().endswith('(') and R.random() < 0.6:
            ln = ln + ' // %s' % mark()
        elif not hascomment and ln.rstrip().endswith(',') and R.random() < 0.3:
            k = mark()
            ln = ln + (' /* %s */' % k if R.random() < 0.5 else ' /* %s\n   x */' % k)
        out.append(ln)
        prev = ln
    return out


MODES = {'1': mode1, '2': mode2, '3': mode3}
if MODE not in MODES:
    sys.exit(__doc__.strip())
os.makedirs(OUT, exist_ok=True)
for path in FILES:
    with open(path) as f:
        lines = f.read().split('\n')
    with open(os.path.join(OUT, path.replace('/', '__')), 'w') as f:
        f.write('\n'.join(MODES[MODE](lines)))
