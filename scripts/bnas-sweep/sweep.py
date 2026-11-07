#!/usr/bin/env python3
"""Compare two bnas builds on lists of assembler cases.

usage: sweep.py <old bnas> <new bnas> [list ...]

Assembles each case of each list (by default every list in testdata/arm32) with
both builds, for arm32 linux, and reports each case the builds treat
differently:
  CHANGED <list> [<context>] <case>   one build assembles it and the other
                                      rejects it, or the objects differ: a
                                      section's contents, a relocation (offset,
                                      type, symbol), a symbol
  MESSAGE <list> [<context>] <case>   both reject it, with different errors
  CRASH <list> [<context>] <case>     the new build dies on it (a signal, a
                                      panic, no error line, no object) or runs
                                      past a minute, whatever the old does
each followed by the two builds' results, then a count per list and a total.
The exit status is 1 if anything was reported.  A change is what a bnas change
does to the instructions it did not mean to touch: a new mnemonic that changes
how an existing one splits into name, condition and `s`, an operand reader
other instructions share, an encoder tightened under another caller.

A list holds one case per line, an instruction, with `|` for a newline (a label
or a symbol's definition before it); a tab at the start is dropped.  A list
whose name ends in -ctx.txt holds `<context><TAB><instruction>` lines, the
context (`.arch armv6`, `|` for a newline too) put before the instruction's
section.  The arm32 lists are the A32 core's instructions, by class, and the
VFP's (vmov the moves): every mnemonic in every operand form with PC and SP in
each register, each immediate and shift at and past the ends of its range, the
operand spellings clang takes, conditions, `s`, case and the old pre-UAL names,
and in the -ctx lists each base architecture or FPU.  They hold no expected
results: the sweep compares two builds with each other, not a build with clang.
"""
import os
import struct
import subprocess
import sys
import tempfile

SHT_SYMTAB, SHT_STRTAB, SHT_RELA, SHT_NOBITS, SHT_REL = 2, 3, 4, 8, 9


def summarize(path):
    """Returns the ELF32 object at path as a dict of what a change can show up
    in: each section's type, flags, alignment and contents, by name; each
    relocation section's entries as (offset, type, symbol name, addend); each
    symbol table's symbols as (name, value, size, info, other, section),
    sorted -- no index into a table the object orders itself."""
    b = open(path, 'rb').read()
    if b[:5] != b'\x7fELF\x01':
        raise ValueError('not an ELF32 object')
    shoff = struct.unpack_from('<I', b, 0x20)[0]
    se, sn, si = struct.unpack_from('<HHH', b, 0x2E)
    secs = [struct.unpack_from('<10I', b, shoff + se * k) for k in range(sn)]

    def cstr(off):
        return b[off:b.index(b'\0', off)].decode()

    names = [cstr(secs[si][4] + s[0]) for s in secs]

    def symbols(k):
        tab, strs = secs[k], secs[secs[k][6]]
        out = []
        for off in range(0, tab[5], 16):
            nm, val, size, info, other, shndx = struct.unpack_from('<IIIBBH', b, tab[4] + off)
            sec = names[shndx] if 0 < shndx < sn else shndx
            out.append((cstr(strs[4] + nm), val, size, info, other, sec))
        return out

    out = {}
    for k, s in enumerate(secs):
        typ = s[1]
        if typ == SHT_SYMTAB:
            out['symbols ' + names[k]] = sorted(symbols(k)[1:])
        elif typ in (SHT_REL, SHT_RELA):
            syms = symbols(s[6])
            size = 8 if typ == SHT_REL else 12
            rels = []
            for off in range(0, s[5], size):
                r_off, r_info = struct.unpack_from('<II', b, s[4] + off)
                addend = struct.unpack_from('<i', b, s[4] + off + 8)[0] if typ == SHT_RELA else None
                rels.append((r_off, r_info & 0xff, syms[r_info >> 8][0], addend))
            out['relocations ' + names[k]] = rels
        elif k != 0 and typ != SHT_STRTAB:
            body = 'nobits %d' % s[5] if typ == SHT_NOBITS else b[s[4]:s[4] + s[5]].hex()
            out['section ' + names[k]] = (typ, s[2], s[8], body)
    return out


def cases(path):
    """Returns the (context, instruction) cases of the list at path."""
    ctx = path.endswith('-ctx.txt')
    out = []
    for line in open(path):
        line = line.rstrip('\n')
        if not line.strip():
            continue
        if ctx:
            out.append(tuple(line.split('\t', 1)))
        else:
            out.append(('', line.lstrip('\t')))
    return out


def describe(r, other):
    """Returns result r for a report, an object as the parts that differ from
    the other build's object (its .text and relocations, when the other build
    made none)."""
    kind, detail = r
    if kind != 'ok':
        return '%s: %s' % (kind, detail)
    keys = [k for k in sorted(detail) if k == 'section .text' or k.startswith('relocations ')]
    if other[0] == 'ok':
        keys = [k for k in sorted(set(detail) | set(other[1])) if detail.get(k) != other[1].get(k)]
    return 'ok: ' + '; '.join('%s %s' % (k, detail.get(k, 'absent')) for k in keys)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    old, new = sys.argv[1], sys.argv[2]
    lists = sys.argv[3:]
    if not lists:
        d = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'testdata', 'arm32')
        lists = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith('.txt'))
    with tempfile.TemporaryDirectory(prefix='bnas-sweep-') as work:
        src, obj = os.path.join(work, 'x.s'), os.path.join(work, 'x.o')

        def run(bnas, ctx, insn):
            open(src, 'w').write('.arch arm32\n' + ctx.replace('|', '\n') + '\n.section text\n' +
                                 insn.replace('|', '\n') + '\n')
            if os.path.exists(obj):
                os.remove(obj)
            try:
                r = subprocess.run([bnas, '-target', 'linux-arm32', '-o', obj, src],
                                   capture_output=True, text=True, errors='replace', timeout=60)
            except subprocess.TimeoutExpired:
                return ('crash', 'no exit within 60 s')
            lines = r.stderr.replace(src, 'x.s').splitlines()
            if r.returncode < 0:
                return ('crash', 'signal %d' % -r.returncode)
            if r.returncode != 0:
                errors = [l for l in lines if 'error:' in l]
                if not errors or any('panic' in l for l in lines):
                    return ('crash', lines[0] if lines else 'exit %d' % r.returncode)
                return ('error', errors[0])
            if not os.path.exists(obj):
                return ('crash', 'exit 0 with no object')
            try:
                return ('ok', summarize(obj))
            except (ValueError, IndexError, struct.error) as e:
                return ('crash', 'unreadable object: %s' % e)

        totals = [0, 0, 0, 0]
        for path in lists:
            name = os.path.basename(path)
            counts = [0, 0, 0, 0]
            for ctx, insn in cases(path):
                counts[0] += 1
                a, b = run(old, ctx, insn), run(new, ctx, insn)
                tag = None
                if b[0] == 'crash':
                    tag = 'CRASH'
                    counts[3] += 1
                elif a[0] != b[0] or (a[0] == 'ok' and a[1] != b[1]):
                    tag = 'CHANGED'
                    counts[1] += 1
                elif a[0] == 'error' and a[1] != b[1]:
                    tag = 'MESSAGE'
                    counts[2] += 1
                if tag:
                    print('%s %s [%s] %s' % (tag, name, ctx, insn.replace('\t', '\\t')))
                    print('    old %s' % describe(a, b))
                    print('    new %s' % describe(b, a))
            print('%s: %d cases, %d changed, %d messages, %d crashes' % (name, *counts))
            sys.stdout.flush()
            totals = [t + c for t, c in zip(totals, counts)]
        print('TOTAL %d cases, %d changed, %d messages, %d crashes' % tuple(totals))
        sys.exit(1 if any(totals[1:]) else 0)


main()
