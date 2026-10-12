#!/usr/bin/env python3
# usage: count.py <native aa64 objdump -d text> <arm32 LLVM IR from bnc --emit-llvm>
# (run by perf/agg-copy-table.sh).
# Per function of the D-table probe: copies (c) and zero-fills (z) of at least 400
# bytes (Big, or its [100]int field once SROA splits a copy).
# native aa64: a backward-branch loop whose body has `ldp q` is a copy, `stp xzr` a zero-fill.
# LLVM arm32, in the IR bnc emits (before clang, whose own inlining blurs the shapes):
# a call to rt.MemCopy is a copy, to rt.MemZero a zero-fill.  A by-value argument's copy
# into r0-r3 + stack is the C ABI's, made by LLVM's lowering of `byval`: not counted.
import re, sys
FUNCS = ['sum', 'mk', 'sumDeref', 'viaLocal', 'direct', 'retDeref', 'retLocal', 'forward',
         'copyThen', 'field', 'global']
def split(path, header):
    out = {}; cur = None
    for line in open(path):
        m = re.match(header, line)
        if m:
            cur = m.group(1); out[cur] = []; continue
        if cur is not None and line.strip(): out[cur].append(line.rstrip('\n'))
    return out
def native(lines):
    addr = []
    for l in lines:
        m = re.match(r'\s*([0-9a-f]+):\s+(.*)', l)
        if m: addr.append((int(m.group(1), 16), m.group(2)))
    c = z = 0
    for i, (a, ins) in enumerate(addr):
        m = re.match(r'b\.\w+\s+0x([0-9a-f]+)', ins)
        if not m: continue
        t = int(m.group(1), 16)
        if t >= a: continue
        body = [x for (b, x) in addr if t <= b <= a]
        if any(x.startswith('ldp\tq') for x in body): c += 1
        elif any(x.startswith('stp\txzr') for x in body): z += 1
    return c, z
def arm(lines):
    def big(l):
        m = re.search(r'i(?:32|64) (\d+)\)\s*$', l)
        return m is not None and int(m.group(1)) >= 400
    c = sum(1 for l in lines if 'rt1_7_MemCopy(' in l and big(l))
    z = sum(1 for l in lines if 'rt1_7_MemZero(' in l and big(l))
    return c, z
N = split(sys.argv[1], r'^[0-9a-f]+ <_bn_F1_4_main1_\d+_(\w+)>:$')
A = split(sys.argv[2], r'^define .*@bn_F1_4_main1_\d+_(\w+)\(')
def fmt(cz):
    c, z = cz
    s = '%dc' % c if c else ''
    if z: s += ('+' if s else '') + '%dz' % z
    return s or '0'
print('| shape | native | LLVM |')
for f in FUNCS:
    print('| %s | %s | %s |' % (f, fmt(native(N.get(f, []))), fmt(arm(A.get(f, [])))))
