#!/usr/bin/env python3
"""Static code-placement report for programs built by bnc's native backends.

  layout.py BIN [--arch auto] [--func RE]... [--hot PERF_REPORT] [--loops]
            [--compare OTHER]
            [--expect-seed S [--mode phase|shift] [--probe SYM --probe-phase P]]
            [--window N --line N] [--tsv|--json]

Reads ELF (x86-64, aarch64, arm32, arm32 bare metal) and Mach-O (x86-64,
aarch64) binaries through llvm-objdump (GNU objdump as a fallback on ELF)
and reports where code landed: a whole-binary summary, a per-function
table, the x86 JCC-erratum and dense-window checks, and with --loops each
natural loop's footprint.  --compare diffs two builds; --expect-seed checks
the function-placement filler bnc's -fnative-place-seed / -fnative-place-mode
put before each Binate function against placehash.py's prediction and exits
1 on a mismatch (or when there is no Binate function to check), and with
--probe SYM --probe-phase P checks a build that also had
-fnative-place-probe=SYM -fnative-place-probe-phase=P: SYM's first entry at
phase P and the filler around it, exiting 3 when no function that receives
placement filler has the symbol SYM (the probe matched nothing); --hot reads
`perf report --stdio` text, credits each reported symbol (block labels
included) to the function and loops holding it, and orders both tables by
that overhead.

A function's extent runs to the next function symbol (the backends emit
st_size 0); symbols outside the extent of their section (Mach-O's
__mh_execute_header) are ignored.  Block labels (local L<sym>__<blk>
symbols) are never functions.  After the last instruction of a function
come, in order: placement filler (INT3, BRK #0x5EED or BKPT #0x5EED), then
on x86-64 a NOP pad to the next 16-byte entry; between objects the linker
adds gap fill (NOPs, zeros, or on lld 0xCC / 0xD4D4D4D4).  On x86-64 lld's
0xCC is the filler's own encoding, so the summary counts as gap an INT3 run
before a function that receives no filler and, of any other run, the bytes
beyond whole 16-byte filler units: lld's fill between objects merges with
the filler of an object's first function.  The seed predicts that filler, so
with a passing --expect-seed the split is exact; without it, a phase-mode
link (objects 64-aligned) may still count up to 48 bytes of linker fill per
object as filler.  A function's trimmed size stops at its last instruction
or data item.  Inside an extent, a symbol that is neither a function nor a
block label starts data (rodata a bare-metal link places in .text, a string
in an assembly function) unless code falls or branches into it; the data
runs up to the trailing material.  Code the function cannot reach (a weak
definition whose symbol the link bound to another object's copy) is counted
as code outside any function.  Binate-mangled functions that the tree's
assembly sources define get no filler and are not checked.

Modules: layout_disasm (formats, objdump text), layout_names (Binate
symbols), layout_span (extents and trailing material), layout_x86 /
layout_arm (arch rules), layout_loops (CFG and loops), layout_seed
(--expect-seed), layout_hot (--hot), layout_report (output).  Nothing runs
their tests (test_layout*.py) automatically; run them after a change:
  python3 -m unittest discover perf/placement

Python standard library only.
"""

import argparse
import bisect
import itertools
import os
import re
import sys
from collections import Counter

import layout_arm
import layout_disasm as ld
import layout_hot
import layout_loops
import layout_names as names
import layout_seed
import layout_x86
import placehash
from layout_disasm import CODE, FILL, NOP, PAD, GAP, DATA, FUNC, LABEL, OTHER
from layout_span import Tail, cut_spans, classify_nops, owned_end, pieces, trail_start

ROLE_ORDER = {FUNC: 0, ld.MAPC: 1, ld.MAPD: 1, LABEL: 2, OTHER: 3}
BODY_TRAIL = (FILL, PAD, GAP)


def rules_for(arch):
    return layout_x86 if arch == "x86_64" else layout_arm.Rules(arch)


class Func:
    """Per-function summary.  addr is the symbol, end the trimmed end and
    span_end where the next function symbol starts; placed is whether bnc
    puts placement filler before it, and pkg its package when its name
    parses (None otherwise); cut is set when data follows the function
    inside its extent."""
    __slots__ = ("name", "names", "sec", "addr", "end", "span_end", "insns", "br",
                 "maxbr", "hits", "jccw", "dense", "placed", "pkg", "xfer_end", "cut",
                 "loops", "hot")

    def __init__(self, fnames, sec, addr, asm=frozenset()):
        self.names, self.sec, self.addr = fnames, sec, addr
        placed = [n for n in fnames if n not in asm and names.placed(n)]
        plain = [n for n in fnames if not n.startswith("L")]
        self.name = placed[0] if placed else (plain or fnames)[0]
        self.placed = bool(placed)
        self.pkg = names.binate_func(self.name) if placed else None
        self.end = self.span_end = addr
        self.insns = self.br = self.maxbr = self.hits = self.jccw = self.dense = 0
        self.xfer_end, self.cut, self.loops, self.hot = False, False, [], None

    @property
    def size(self):
        return self.end - self.addr


def make_marks(syms, headers=None):
    """Per section, sorted (addr, order, role, name) for every symbol inside
    its section's extent (all of them when headers gives no extent)."""
    typed = any(s.is_func for s in syms)
    funcs = ld.func_names(syms, typed)
    out = {}
    for s in syms:
        ext = ld.section_extent(headers or {}, s.section)
        if ext is not None and not ext[0] <= s.addr < ext[1]:
            continue
        role = ld.sym_role(s, typed, funcs)
        out.setdefault(s.section, []).append((s.addr, ROLE_ORDER[role], role, s.name))
    for v in out.values():
        v.sort()
    return out


class Layout:
    """The analysis of one binary."""

    def __init__(self, arch, fmt, window=None, line=64, loops=False, path="",
                 asm=frozenset()):
        self.arch, self.fmt, self.path, self.asm = arch, fmt, path, asm
        self.rules = rules_for(arch)
        self.unit = placehash.UNIT[arch]
        self.window = window or self.rules.DEFAULT_WINDOW
        self.line, self.want_loops = line, loops
        self.tool = ""
        self.sections, self.funcs, self.tails = {}, [], {}
        self.bytes, self.kinds = Counter(), Counter()
        self.insns = self.units = self.hits = self.unnamed = 0
        self.hit_windows, self.dense = set(), Counter()
        self.headers, self.defined, self.symaddrs, self.hot = {}, 0, {}, None
        self.fill_runs, self.known_fill = {}, {}

    # --- building ---

    def load(self, sym_lines, dis_lines, header_lines=()):
        """Analyze from objdump -t, -d (and optionally -h) text; section
        extents come from the headers when given, else from the items."""
        self.headers = ld.parse_sections(header_lines)
        syms = ld.parse_symtab(sym_lines, self.fmt)
        self.defined = len(syms)
        marks = make_marks(syms, self.headers)
        symaddr = {s.name: s.addr for s in syms}
        self.symaddrs = {}
        for s in syms:
            self.symaddrs.setdefault(s.name, []).append(s.addr)
        stream = ld.parse_disasm(dis_lines, self.rules.decode, self.fmt, symaddr)
        for sec, group in itertools.groupby(stream, key=lambda t: t[0]):
            self._section(sec, (rec for _, rec in group), marks.get(sec, []))
        self._finish()
        return self

    def _section(self, sec, recs, marks):
        lo = hi = None
        for span in cut_spans(recs, marks):
            if span.recs:
                lo = span.recs[0].addr if lo is None else lo
                hi = span.recs[-1].end
            self._span(sec, span)
        ext = ld.section_extent(self.headers, sec)
        if ext is not None and lo is not None:
            # Zero runs the disassembler elides at either end of a section
            # print no address line after them.
            self.bytes[GAP] += max(0, lo - ext[0]) + max(0, ext[1] - hi)
        if ext is not None or lo is not None:
            self.sections[sec] = ext or (lo, hi)

    def _span(self, sec, span):
        recs = span.recs
        if span.names is None:
            classify_nops(recs, set())
            self._account(recs)
            self.tails[span.end] = Tail(recs, span.end)
            return
        f = Func(span.names, sec, span.addr, self.asm)
        f.span_end = span.end
        labels = dict(span.labels)
        cut = self._resolve_others(span, labels)
        code = recs[:cut]
        if cut < len(recs):
            # Data runs up to the trailing material, whose filler and pad
            # belong to the next function.
            t = max(cut, trail_start(recs))
            for r in recs[cut:t]:
                r.cls, r.kind, r.tgt = DATA, None, None
            for r in recs[t:]:
                if r.cls == NOP:
                    r.cls = PAD
            f.cut = True
        starts = {span.addr} | set(labels)
        starts.update(r.tgt for r in code if r.tgt is not None and not r.call)
        classify_nops(code, starts)
        prefixes = tuple("L%s__" % n for n in span.names)
        own = {a for a, n in labels.items() if n.startswith(prefixes)}
        k = owned_end(code, span.addr, own)
        self.unnamed += sum(r.size for r in code[k:] if r.cls == CODE)
        code = code[:k]
        while k > 0 and code[k - 1].cls in BODY_TRAIL:
            k -= 1
        body = code[:k]
        f.end = body[-1].end if body else span.addr
        f.xfer_end = any(r.tgt == span.end for r in recs if r.tgt is not None)
        self._account(recs, f, body)
        if self.want_loops:
            hits = [u[0] for u in self._units(body) if layout_x86.hit(u[0], u[1])] \
                if self.rules.HAS_ERRATUM else None
            f.loops = layout_loops.analyze(body, [span.addr], labels, self.window,
                                           self.line, hits)
            layout_loops.loop_keys(f.loops, labels, prefixes)
        self.funcs.append(f)
        self.tails[span.end] = Tail(recs, span.end, f, pieces(recs, len(body), trail_start(recs)))

    def _resolve_others(self, span, labels):
        """Index where the span's data begins: a symbol that is neither a
        function nor a block label starts data unless a branch targets it or
        the code before it falls through into it (then it is a code label)."""
        recs = span.recs
        if not span.others:
            return len(recs)
        targets = {r.tgt for r in recs if r.tgt is not None}
        addrs = [r.addr for r in recs]
        for addr, name in sorted(span.others):
            i = bisect.bisect_left(addrs, addr)
            prev = recs[i - 1] if i > 0 else None
            if (addr <= span.addr or addr in targets
                    or (prev is not None and prev.cls in (CODE, NOP) and prev.ft)):
                labels[addr] = name
            else:
                return i
        return len(recs)

    def _units(self, recs):
        return layout_x86.units(recs) if self.rules.HAS_ERRATUM else []

    def _account(self, recs, f=None, body=()):
        run = None
        for r in recs:
            self.bytes[r.cls] += r.size
            if r.cls == FILL:
                run = r.addr if run is None else run
                self.fill_runs[r.end] = r.end - run
                self.fill_runs.pop(r.addr, None)
            else:
                run = None
            if r.cls == CODE:
                self.insns += 1
                if r.kind is not None:
                    self.kinds[r.kind] += 1
                if self.rules.HAS_ERRATUM:
                    self.dense[r.addr // layout_x86.ERRATUM_WINDOW] += 1
        units = self._units(recs)
        hits = [u for u in units if layout_x86.hit(u[0], u[1])]
        self.units += len(units)
        self.hits += len(hits)
        for s, n, _ in hits:
            self.hit_windows.update(layout_x86.hit_windows(s, n))
        if f is None:
            return
        units = self._units(body)
        hits = [u for u in units if layout_x86.hit(u[0], u[1])]
        brs = [r for r in body if r.cls == CODE and r.kind is not None]
        f.insns = sum(1 for r in body if r.cls == CODE)
        f.br, f.hits = len(brs), len(hits)
        per_win = Counter(r.addr // self.window for r in brs)
        f.maxbr = max(per_win.values()) if per_win else 0

    def _finish(self):
        if not self.rules.HAS_ERRATUM:
            return
        w = layout_x86.ERRATUM_WINDOW
        for f in self.funcs:
            if f.end > f.addr:
                wins = range(f.addr // w, (f.end - 1) // w + 1)
                f.dense = sum(1 for i in wins if self.dense[i] > layout_x86.DENSE_LIMIT)
                f.jccw = sum(1 for i in wins if i in self.hit_windows)
            for lp in f.loops:
                wins = {i for s, e in lp["_iv"] for i in range(s // w, (e - 1) // w + 1)}
                lp["jccw"] = len(wins & self.hit_windows)

    # --- queries ---

    def dense_windows(self):
        return sorted(i for i, n in self.dense.items() if n > layout_x86.DENSE_LIMIT)

    def entry_index(self, i):
        """See layout_seed.entry_index."""
        return layout_seed.entry_index(self, i)

    def placed_entries(self):
        """Addresses of the first entry points of the functions that receive
        placement filler."""
        return {self.funcs[self.entry_index(i)].addr
                for i, f in enumerate(self.funcs) if f.placed}

    def byte_counts(self):
        """Bytes by class, with the linker's part of each filler run counted
        as gap where the linker's gap fill can be the filler's encoding
        (lld's INT3 on x86-64): a run before a function that receives no
        filler is all gap (except a probed function's trailing filler, once
        a passing expect_seed has settled it), and of any other run only
        whole filler units are filler, or exactly the predicted filler of an
        object's first function once a passing expect_seed has settled it."""
        out = Counter(self.bytes)
        if not self.rules.GAP_FILL_IS_FILLER:
            return out
        entries = self.placed_entries()
        before_entry = {t.start + t.fill: t.entry for t in self.tails.values() if t.fill}
        moved = 0
        for end, n in self.fill_runs.items():
            entry = before_entry.get(end)
            if entry is not None and entry not in entries:
                # All gap, unless a passing expect_seed found a probed
                # function's trailing filler here.
                filler = self.known_fill.get(end, 0)
            else:
                filler = self.known_fill.get(end, n - n % self.unit)
            moved += n - filler
        out[FILL] -= moved
        out[GAP] += moved
        return out

    def expect_seed(self, seed, mode, probe=None):
        """--expect-seed rows (with --probe, probe is (SYM, PHASE)); see
        layout_seed."""
        return layout_seed.expect_seed(self, seed, mode, probe)


def analyze(path, arch=None, window=None, line=64, loops=False, tool=None):
    """Disassemble and analyze the binary at path; tool forces a (path,
    flavor) disassembler instead of ld.pick_tool's choice.  The assembly
    sources are looked up in the tree this file is in."""
    with open(path, "rb") as fh:
        head = fh.read(64)
    try:
        fmt, detected = ld.detect(head)
    except ValueError as e:
        raise ValueError("%s: %s" % (path, e))
    if arch and arch != detected:
        print("layout.py: %s: header says %s, analyzing as %s" % (path, detected, arch),
              file=sys.stderr)
    arch = arch or detected
    tool, kind = ld.pick_tool(fmt, arch) if tool is None else tool
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    lay = Layout(arch, fmt, window, line, loops, path, names.tree_asm_symbols(root, arch))
    lay.tool = tool
    headers = list(ld.run_lines(ld.headers_cmd(tool, kind, path)))
    cmds = ld.disasm_cmds(tool, kind, fmt, path, arch, ld.parse_sections(headers))
    lay.load(ld.run_lines(ld.symtab_cmd(tool, kind, path)),
             itertools.chain.from_iterable(ld.run_lines(c) for c in cmds), headers)
    return require_functions(lay)


def require_functions(lay):
    """lay, or a RuntimeError saying why it holds no functions."""
    if lay.funcs:
        return lay
    why = ("the symbol table defines no symbols at all: the binary is stripped, or its "
           "linker wrote symbols only for undefined imports" if not lay.defined
           else "a stripped binary")
    if not lay.headers:
        why += "; objdump also lists no sections"
    raise RuntimeError("%s: no function symbols in executable sections, so functions "
                       "cannot be located (%s)" % (lay.path, why))


def main(argv=None):
    import layout_report
    ap = argparse.ArgumentParser(prog="layout.py", description=__doc__.split("\n\n")[2])
    ap.add_argument("bin", help="the executable to analyze")
    ap.add_argument("--arch", default="auto", choices=["auto", "x86_64", "aarch64", "arm32"],
                    help="override the architecture the file header gives")
    ap.add_argument("--func", action="append", default=[], metavar="RE",
                    help="list only functions with a name RE matches (repeatable)")
    ap.add_argument("--hot", metavar="PERF_REPORT",
                    help="`perf report --stdio` text: add overhead and sort by it")
    ap.add_argument("--loops", action="store_true", help="add the natural-loop table")
    ap.add_argument("--compare", metavar="OTHER",
                    help="add per-function and per-loop deltas from BIN to OTHER")
    ap.add_argument("--expect-seed", type=int, metavar="S",
                    help="check the placement filler of a -fnative-place-seed=S build; "
                         "exit 1 on a mismatch")
    ap.add_argument("--mode", choices=sorted(placehash.MODES),
                    help="the -fnative-place-mode of that build (default phase)")
    ap.add_argument("--probe", metavar="SYM",
                    help="the -fnative-place-probe of that build; exit 3 when no function "
                         "that receives placement filler has this symbol")
    ap.add_argument("--probe-phase", type=int, metavar="P",
                    help="the -fnative-place-probe-phase of that build")
    ap.add_argument("--window", type=int,
                    help="window size in bytes (default 32 on x86-64, 16 on Arm)")
    ap.add_argument("--line", type=int, default=64, help="cache-line size in bytes")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--tsv", action="store_true", help="tab-separated tables")
    out.add_argument("--json", action="store_true", help="one JSON document")
    args = ap.parse_args(argv)
    if args.mode and args.expect_seed is None:
        ap.error("--mode needs --expect-seed")
    if (args.probe is None) != (args.probe_phase is None):
        ap.error("--probe and --probe-phase go together")
    if args.probe is not None and args.expect_seed is None:
        ap.error("--probe needs --expect-seed")
    if args.probe is not None and not args.probe:
        ap.error("--probe needs a symbol")
    if args.probe_phase is not None and not 0 <= args.probe_phase < placehash.PLACE_SPAN:
        ap.error("--probe-phase must be in 0..%d" % (placehash.PLACE_SPAN - 1))
    if args.expect_seed is not None and not 0 <= args.expect_seed <= placehash.PLACE_SEED_MAX:
        ap.error("--expect-seed must be in 0..%d" % placehash.PLACE_SEED_MAX)
    for n, v in (("--window", args.window), ("--line", args.line)):
        if v is not None and (v < 4 or v & (v - 1)):
            ap.error("%s must be a power of two >= 4" % n)
    try:
        funcs = [re.compile(r) for r in args.func]
    except re.error as e:
        ap.error("bad --func pattern: %s" % e)
    arch = None if args.arch == "auto" else args.arch
    try:
        lay = analyze(args.bin, arch, args.window, args.line, args.loops)
        other = None
        if args.compare:
            other = analyze(args.compare, arch, args.window, args.line, args.loops)
            if other.arch != lay.arch:
                raise RuntimeError("cannot compare %s with %s binaries" % (lay.arch, other.arch))
        if args.hot:
            with open(args.hot, errors="replace") as fh:
                rows, event = layout_hot.parse_perf(fh, args.hot)
            lay.hot = dict(layout_hot.apply_hot(lay, rows), file=args.hot, event=event)
    except (OSError, ValueError, RuntimeError) as e:
        print("layout.py: %s" % e, file=sys.stderr)
        return 2
    seed_rows = None
    probe = None if args.probe is None else (args.probe, args.probe_phase)
    if args.expect_seed is not None:
        try:
            seed_rows = lay.expect_seed(args.expect_seed, args.mode or "phase", probe)
        except ValueError as e:
            print("layout.py: %s" % e, file=sys.stderr)
            return 2
    try:
        layout_report.emit(lay, other, seed_rows, funcs, args, sys.stdout)
        sys.stdout.flush()
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    if probe is not None and layout_seed.probe_row(seed_rows) is None:
        print("layout.py: --probe %s: no function that receives placement filler has this "
              "symbol" % args.probe, file=sys.stderr)
        return 3
    if seed_rows is not None and (not seed_rows or not all(r["ok"] for r in seed_rows)):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
