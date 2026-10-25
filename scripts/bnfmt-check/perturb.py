#!/usr/bin/env python3
"""Copy source files with their layout and lengths perturbed, for checking bnfmt
on code that is near, but not at, its formatted layout.

usage: perturb.py <file list> <out dir> <seed> <mode>

mode:
  id     lengthen a few identifiers (all their uses, not selectors)
  str    insert words into some string literals (not in imports)
  join   join some continuation lines onto the line they continue
  split  break some lines after a `, ` (outside literals, on lines without comments)
  cmt    add block, line and own-line comments after some commas
  mix    two of the above, picked per file

Writes <out dir>/<mode><seed>_<i>.bn for each listed file the perturbation
changes.  The files depend only on the arguments and inputs.
"""
import os
import random
import re
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__.strip())
with open(sys.argv[1]) as f:
    FILES = [ln.strip() for ln in f if ln.strip()]
OUT, SEED, MODE = sys.argv[2], int(sys.argv[3]), sys.argv[4]
R = random.Random(SEED)
KW = set('package import func var const type struct interface impl if else for switch case '
         'default return break continue go defer fallthrough goto in readonly Self nil true '
         'false make make_slice box cast bit_cast len unsafe_index sizeof alignof present same '
         'unsafe_cast'.split())
WORDS = ('alpha beta gamma delta epsilon zeta theta iota kappa lambda omicron sigma '
         'upsilon').split()


def tokens(s):
    """Yield (kind, text) for s, kind one of cmt, str, chr, id, other."""
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if s.startswith('//', i):
            j = s.find('\n', i)
            j = n if j < 0 else j
            yield 'cmt', s[i:j]
            i = j
            continue
        if s.startswith('/*', i):
            j = s.find('*/', i)
            j = n if j < 0 else j + 2
            yield 'cmt', s[i:j]
            i = j
            continue
        if ch in '"\'`':
            j = i + 1
            while j < n and s[j] != ch:
                if s[j] == '\\':
                    j += 1
                j += 1
            yield ('str' if ch == '"' else 'chr'), s[i:j + 1]
            i = j + 1
            continue
        m = re.match(r'[0-9][A-Za-z0-9_.]*', s[i:i + 200])  # a number, hex digits and all
        if m:
            yield 'other', m.group(0)
            i += len(m.group(0))
            continue
        m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', s[i:i + 200])
        if m:
            yield 'id', m.group(0)
            i += len(m.group(0))
            continue
        yield 'other', ch
        i += 1


def p_id(s):
    toks = list(tokens(s))
    ids = [t for k, t in toks if k == 'id' and t not in KW and len(t) <= 12]
    if not ids:
        return s
    pool = sorted(set(ids))
    pick = R.sample(pool, min(len(pool), R.randint(3, 10)))
    longer = {nm: nm + R.choice(['_', 'X', 'q']) * R.randint(1, 12) for nm in pick}
    res = []
    prev = ''
    for k, t in toks:
        res.append(longer.get(t, t) if k == 'id' and prev != '.' else t)
        prev = t[-1:] if t else prev
    return ''.join(res)


def in_import(res):
    tail = ''.join(res[-6:])
    return 'import' in tail or 'package' in tail


def p_str(s):
    res = []
    for k, t in tokens(s):
        if k == 'str' and len(t) >= 2 and R.random() < 0.35 and not in_import(res):
            body = t[1:-1]
            pos = [i for i in range(len(body) + 1) if i == 0 or body[i - 1] != '\\']
            p = R.choice(pos)
            ins = ' '.join(R.choice(WORDS) for _ in range(R.randint(1, 8))) + ' '
            t = '"' + body[:p] + ins + body[p:] + '"'
        res.append(t)
    return ''.join(res)


def indent(ln):
    return len(ln) - len(ln.lstrip('\t'))


def p_join(s):
    lines = s.split('\n')
    res = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        while (i + 1 < len(lines) and ln.rstrip().endswith((',', '(', '+', '&&', '||', '{'))
               and '//' not in ln and '//' not in lines[i + 1] and lines[i + 1].strip()
               and indent(lines[i + 1]) > indent(ln) and R.random() < 0.6
               and not ln.rstrip().endswith('{')
               and not lines[i + 1].lstrip().startswith(('}', 'case', 'default'))):
            sep = '' if ln.rstrip().endswith('(') else ' '
            ln = ln.rstrip() + sep + lines[i + 1].lstrip()
            i += 1
        res.append(ln)
        i += 1
    return '\n'.join(res)


def code_commas(ln):
    """Return the indexes of the `, ` in ln outside string and character
    literals, or none if ln has a comment."""
    res = []
    i = 0
    q = None
    while i < len(ln):
        c = ln[i]
        if q:
            if c == '\\':
                i += 1
            elif c == q:
                q = None
        elif c in '"\'`':
            q = c
        elif ln.startswith('//', i) or ln.startswith('/*', i):
            return []
        elif ln.startswith(', ', i):
            res.append(i)
        i += 1
    return res


def p_split(s):
    res = []
    for ln in s.split('\n'):
        idx = code_commas(ln)
        if idx and R.random() < 0.3:
            p = R.choice(idx)
            res.append(ln[:p + 1])
            res.append('\t' * (indent(ln) + 2) + ln[p + 2:])
        else:
            res.append(ln)
    return '\n'.join(res)


def p_cmt(s):
    res = []
    for k, t in tokens(s):
        res.append(t)
        if k == 'other' and t == ',' and R.random() < 0.12:
            r = R.random()
            if r < 0.4:
                res.append(' /* c%d */' % R.randint(0, 99))
            elif r < 0.8:
                res.append(' // note %d\n' % R.randint(0, 99))
            else:
                res.append('\n// own %d\n' % R.randint(0, 99))
    return ''.join(res)


MODES = {'id': p_id, 'str': p_str, 'join': p_join, 'split': p_split, 'cmt': p_cmt}
if MODE not in MODES and MODE != 'mix':
    sys.exit(__doc__.strip())
os.makedirs(OUT, exist_ok=True)
count = 0
for path in FILES:
    with open(path) as f:
        src = f.read()
    if 'package "' not in src:
        continue
    t = src
    for m in ([MODE] if MODE != 'mix' else R.sample(list(MODES), 2)):
        t = MODES[m](t)
    if t == src:
        continue
    with open(os.path.join(OUT, '%s%d_%d.bn' % (MODE, SEED, count)), 'w') as f:
        f.write(t)
    count += 1
