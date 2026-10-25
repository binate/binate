#!/usr/bin/env python3
"""Generate a sweep of adjacent-string runs for checking bnfmt's string splits.

usage: gen_sweep.py <out dir>

Writes <out dir>/s<i>.bn: a run of two to four strings of 18 to 39 bytes each,
after each of four prefixes (`a, `, `a, b, `, a block comment, `someName, `), in
each of sixteen places -- a call's argument, a composite literal's value, an
index, a builtin's argument, a binary operand, a selector's operand, a function
literal's body, a case label, a call followed by a selector or spread by
`...`.
"""
import os
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__.strip())
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
N = [0]
# same takes two operands: the prefixes as a first operand
SAME_PRE = {'a, b, ': 'a + b, ', '/* c */ ': '/* c */ x, '}


def write(body):
    N[0] += 1
    with open(os.path.join(OUT, 's%d.bn' % N[0]), 'w') as f:
        f.write('package "p"\n\nfunc g() {\n' + body + '\n}\n')


for k in (2, 3, 4):
    for ln in range(18, 40):
        r = ' '.join(['"' + 'a' * ln + '"'] * k)
        for pre in ('a, ', 'a, b, ', '/* c */ ', 'someName, '):
            bare = pre.replace('/* c */ ', '')
            write('\tf(' + pre + r + ')')
            write('\t_ = T{key: ' + r + '}')
            write('\t_ = T{' + bare + r + '}')
            write('\t_ = T{kkkkkkkk: f(' + pre + r + ')}')
            write('\t_ = __c_call("sym", int, ' + pre + r + ')')
            write('\t_ = x[' + pre + r + ']')
            write('\t_ = same(' + SAME_PRE.get(pre, pre) + r + ')')
            write('\tf(' + pre + 'x + ' + r + ')')
            write('\tf(' + pre + r + ' + x)')
            write('\tf(' + pre + '-' + r + ')')
            write('\tf(' + pre + r + '.y)')
            write('\tf(' + pre + 'g(' + r + '))')
            write('\tf(' + pre + 'func() { _ = ' + r + ' })')
            write('\tswitch v {\n\tcase ' + bare + r + ':\n\t}')
            write('\tx := f(' + pre + r + ').z')
            write('\tg(f(' + pre + r + ')...)')
