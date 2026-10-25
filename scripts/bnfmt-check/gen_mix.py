#!/usr/bin/env python3
"""Generate random statement mixes for checking bnfmt.

usage: gen_mix.py [--dense] <seed> <count> <out dir>

Writes <out dir>/g<seed>_<i>.bn for i < count: one function of one to three
statements (and sometimes a package-level var), built from calls, composite
literals, function literals, index and slice expressions, binary chains and
runs of adjacent strings, nested up to five levels, with line breaks, line and
block comments and `// LONG-LINE ALLOWED` markers in their lists.  --dense puts
more comments in the lists, a block comment before arguments, a call with a line
comment in function-literal bodies, and more function literals (fewer index
expressions).  The files depend only on the arguments.
"""
import os
import random
import sys

DENSE = '--dense' in sys.argv
ARGS = [a for a in sys.argv[1:] if a != '--dense']
if len(ARGS) != 3:
    sys.exit(__doc__.strip())
SEED, COUNT, OUT = int(ARGS[0]), int(ARGS[1]), ARGS[2]
R = random.Random(SEED)
K = [0]


def mark():
    """Return a fresh comment marker, numbered within the current file."""
    K[0] += 1
    return 'K%d' % K[0]


def maybe_bc():
    if R.random() < (0.3 if DENSE else 0.12):
        return '/* %s */ ' % mark()
    return ''


def ident():
    return R.choice(['a', 'b', 'xx', 'value', 'someLongerName', 'q' * R.randint(1, 30),
                     'p.field', 'obj.method'])


def strlit():
    r = R.random()

    def one():
        return '"' + 'a' * R.randint(0, 40) + '"'
    if r < 0.5:
        return one()
    if r < 0.85:
        return ' '.join(one() for _ in range(R.randint(2, 6)))
    return one() + ' ' + one() + '\n' + one()  # a run across lines


def sep_after_comma():
    r = R.random()
    lc, bc = (0.30, 0.45) if DENSE else (0.22, 0.30)
    if r < 0.15:
        return ',\n'
    if r < lc:
        return ', // %s\n' % mark()
    if r < bc:
        return ', /* %s */ ' % mark()
    return ', '


def after_open():
    r = R.random()
    lc, bc = (0.25, 0.40) if DENSE else (0.18, 0.25)
    if r < 0.12:
        return '\n'
    if r < lc:
        return ' // %s\n' % mark()
    if r < bc:
        return '/* %s */ ' % mark()
    return ''


def funclit(d):
    r = R.random()
    if r < 0.3:
        return 'func() int { return %s }' % expr(d + 1)
    body = []
    for _ in range(R.randint(1, 3)):
        s = R.random()
        if s < 0.3:
            body.append('// %s' % mark())
            if DENSE and s < 0.15:
                body.append('f(a, /* %s */ b, // %s\n c)' % (mark(), mark()))
        if s < 0.6:
            body.append('x := %s' % expr(d + 1))
        elif s < 0.8:
            body.append('g(%s) // %s' % (expr(d + 1), mark()))
        else:
            body.append('_ = %s // LONG-LINE ALLOWED' % expr(d + 1))
    body.append('return %s' % expr(d + 1))
    return 'func(y int) int {\n' + '\n'.join(body) + '\n}'


def args(d, k):
    out = after_open()
    parts = [expr(d + 1) for _ in range(k)]
    for i, p in enumerate(parts):
        if i > 0:
            out += sep_after_comma()
        out += (maybe_bc() + p) if DENSE else p
    return out


def expr(d):
    if d > 4:
        return R.choice([ident(), str(R.randint(0, 99999)), strlit()])
    r = R.random()
    if r < 0.15:
        return ident()
    if r < 0.25:
        return strlit()
    if r < 0.45:
        callee = R.choice(['f', 'g', 'longFunctionName', 'pkg.Call', 'x.m'])
        return callee + '(' + args(d, R.randint(0, 4)) + ')'
    if r < 0.52:
        return expr(d + 1) + R.choice([' + ', ' && ', ' * ', ' +\n']) + expr(d + 1)
    if r < 0.62:
        kv = R.random() < 0.5
        k = R.randint(0, 4)
        out = R.choice(['T', 'S', 'pkg.Rec', 'Pair[int, int]']) + '{' + after_open()
        for i in range(k):
            if i > 0:
                out += sep_after_comma()
            if kv:
                out += R.choice(['f', 'name', 'k' * R.randint(1, 20)]) + ': '
            out += expr(d + 1)
        return out + '}'
    if r < (0.72 if DENSE else 0.68):
        return funclit(d)
    if r < (0.74 if DENSE else 0.72):
        return expr(d + 1) + '[' + expr(d + 1) + ']'
    if r < 0.76:
        return 'f(' + args(d, R.randint(1, 3)) + ').' + R.choice(['x', 'longSelectorName'])
    if r < 0.80:
        return 'len(' + expr(d + 1) + ')'
    if r < 0.83:
        return 'cast(int, ' + expr(d + 1) + ')'
    if r < 0.86:
        return '__c_call("sym", int, ' + args(d, R.randint(1, 3)) + ')'
    if r < 0.89:
        return 'h(' + args(d, R.randint(1, 3)) + '...)'
    if r < 0.92:
        e = expr(d + 1)
        return '-(' + e + ')' if e.startswith('-') else '-' + e  # never `--`
    if r < 0.95:
        return 'f[int](' + args(d, R.randint(0, 2)) + ')'
    return '(' + expr(d + 1) + ')'


def stmt():
    r = R.random()
    e = expr(0)
    tail = ''
    if R.random() < 0.1:
        tail = ' // LONG-LINE ALLOWED'
    elif R.random() < 0.15:
        tail = ' // %s' % mark()
    if r < 0.3:
        return '_ = ' + e + tail
    if r < 0.5:
        return 'x := ' + e + tail
    if r < 0.6:
        return 'return ' + e + tail
    if r < 0.7:
        return 'if ok(' + e + ') {\n}'
    if r < 0.8:
        return 'switch v {\ncase %s, %s:\n_ = 1\n}' % (expr(1), expr(1))
    return 'f(' + args(0, R.randint(1, 4)) + ')' + tail


os.makedirs(OUT, exist_ok=True)
for n in range(COUNT):
    K[0] = 0
    lines = ['package "p"', '', 'func g() int {']
    for _ in range(R.randint(1, 3)):
        if R.random() < 0.2:
            lines.append('// %s' % mark())
        lines.append(stmt())
    lines.append('}')
    if R.random() < 0.3:
        lines.append('')
        lines.append('var v = ' + expr(0))
    with open(os.path.join(OUT, 'g%d_%d.bn' % (SEED, n)), 'w') as f:
        f.write('\n'.join(lines) + '\n')
