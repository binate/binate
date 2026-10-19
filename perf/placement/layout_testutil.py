"""Test fixtures for the layout.py tests: a tiny program builder that lays
out instructions, symbols and placement filler the way bnc's native backends
do, and renders them as `objdump -t` and `objdump -d` text in the llvm-objdump
ELF, llvm-objdump --macho and GNU objdump syntaxes.

Used by test_layout.py and test_layout_formats.py; not a test module itself.
"""

import placehash

STYLES = ("llvm", "gnu", "macho")


class Prog:
    """Instructions as (addr, raw bytes, text, target, data); text uses {t}
    where a branch target goes, rendered per syntax."""

    def __init__(self, arch, base=0x1000, section=".text"):
        self.arch, self.pc, self.section = arch, base, section
        self.items, self.syms, self.obj = [], [], base
        self.unit = placehash.UNIT[arch]

    # --- building ---

    def sym(self, name, flags="g     F"):
        self.syms.append((self.pc, name, flags))
        return self.pc

    def label(self, name):
        return self.sym(name, "l      ")

    def op(self, raw, text, target=None):
        if isinstance(raw, int):
            raw = raw.to_bytes(4, "little")
        self.items.append((self.pc, bytes(raw), text, target, False))
        self.pc += len(raw)

    def data(self, raw, text):
        self.items.append((self.pc, bytes(raw), text, None, True))
        self.pc += len(raw)

    def skip(self, n):
        """Zero bytes the disassembler elides ('...')."""
        self.pc += n

    def fill(self, nbytes):
        insn = placehash.FILL_INSN[self.arch]
        text = {"x86_64": "int3", "aarch64": "brk\t#0x5eed", "arm32": "bkpt\t#0x5eed"}
        for _ in range(nbytes // len(insn)):
            self.op(insn, text[self.arch])

    def nops_to(self, align, raw=b"\x90"):
        while self.pc % align:
            if self.arch == "x86_64":
                self.op(raw, "nop")
            else:
                self.op((0xD503201F if self.arch == "aarch64" else 0xE320F000), "nop")

    def int3_to(self, align):
        while self.pc % align:
            self.op(b"\xcc", "int3")

    def start_object(self, align=64, gap="nop"):
        """Begin a new object's text at the next align boundary, padding with
        NOPs (GNU ld), INT3 (lld on x86-64) or zero bytes."""
        if gap == "zero":
            self.skip(-self.pc % align)
        else:
            (self.int3_to if gap == "int3" else self.nops_to)(align)
        self.obj = self.pc

    def placed(self, key, seed, mode, extra=0, zero=False, probe=None, post=0):
        """Filler before the Binate function keyed key, as EmitObject puts it
        (offset within the current object), then x86-64's entry alignment;
        returns the filler placehash predicts.  post is the trailing filler of
        a probed function the previous one was, which comes first; extra adds
        that many bytes of filler, as a broken backend might, and zero writes
        zero bytes in the filler's place."""
        pre = placehash.fill_before(seed, mode, key, self.unit, self.pc - self.obj + post, probe)
        n = extra + post + pre
        if zero:
            self.skip(n)
        else:
            self.fill(n)
        if self.arch == "x86_64":
            self.nops_to(16)
        return pre

    # --- rendering ---

    def _names_at(self):
        """Labels the disassembler prints (mapping symbols are not printed)."""
        out = {}
        for addr, name, flags in self.syms:
            if not name.startswith("$"):
                out.setdefault(addr, []).append(name)
        return out

    def _target(self, t, style, names):
        n = names.get(t)
        if style == "macho":
            return "_" + n[0] if n and not n[0].startswith("L") else "0x%x" % t
        hexa = ("0x%x" if style == "llvm" else "%x") % t
        return "%s <%s>" % (hexa, n[0]) if n else hexa

    def _raw(self, raw, style, data):
        if self.arch == "x86_64" or style == "macho" or (data and style == "llvm"):
            return " ".join("%02x" % b for b in raw)
        step = len(raw) if len(raw) in (2, 4) else 1
        return " ".join("%0*x" % (2 * step, int.from_bytes(raw[i:i + step], "little"))
                        for i in range(0, len(raw), step))

    def symtab(self, style="llvm"):
        lines = ["SYMBOL TABLE:"]
        for addr, name, flags in self.syms:
            if style == "macho":
                lines.append("%016x %s __TEXT,__text _%s" % (addr, flags, name))
            elif style == "gnu":
                lines.append("%016x %s %s\t%016x              %s" % (addr, flags, self.section,
                                                                    0, name))
            else:
                lines.append("%016x %s %s\t%016x %s" % (addr, flags, self.section, 0, name))
        return "\n".join(lines) + "\n"

    def disasm(self, style="llvm"):
        names = self._names_at()
        if style == "macho":
            out = ["prog:", "(__TEXT,__text) section"]
        else:
            out = ["", "prog:\tfile format", "", "Disassembly of section %s:" % self.section]
        prev_end = None
        for addr, raw, text, tgt, data in self.items:
            if prev_end is not None and addr > prev_end:
                out.append("\t\t...")
            for n in names.get(addr, []) if style != "gnu" else names.get(addr, [])[:1]:
                out.append("_%s:" % n if style == "macho" else "\n%016x <%s>:" % (addr, n))
            body = text.replace("{t}", self._target(tgt, style, names)) if tgt is not None \
                else text
            if style == "gnu" and self.arch == "x86_64" and "\t" in body:
                m, rest = body.split("\t", 1)
                body = "%-6s %s" % (m, rest)
            raw_s = self._raw(raw, style, data)
            if style == "macho":
                out.append("%x:\t%s\t%s" % (addr, raw_s, body))
            elif style == "gnu":
                out.append("%8x:\t%-20s \t%s" % (addr, raw_s, body))
            else:
                out.append("%8x: %-28s\t%s" % (addr, raw_s, body))
            prev_end = addr + len(raw)
        if prev_end is not None and self.pc > prev_end:
            out.append("\t\t...")
        return "\n".join(out) + "\n"

    def headers(self, style="llvm"):
        lo = self.items[0][0]
        name = "__text" if style == "macho" else self.section
        return ["Idx Name          Size     VMA              Type",
                "  1 %s %08x %016x TEXT" % (name, self.pc - lo, lo)]


# --- the x86-64 program the end-to-end tests share ----------------------------

F1 = "bn_F1_4_main1_2_f1"
F2 = "bn_F1_4_main1_2_f2"
F3 = "bn_F1_4_main1_2_f3"
PKG_A = "bn_F1_4_main1_9___Package"
G1 = "bn_F1_1_p1_2_g1"
G2 = "bn_I1_1_p1_h1_N0_3_int"
PKG_B = "bn_F1_1_p1_9___Package"
LOOP = "Lbn_F1_4_main1_2_f1__for.cond.1"


def x86_program(seed, mode="phase", gap="nop", extra=None, zero=(), probe=None, post=True):
    """Two objects.  main: f1 (a loop), f2, f3 behind a #[c_export] alias
    `cexp` with a C-entry normalization, then the package descriptor.  p:
    g1, a generic instantiation g2, its descriptor, then a C helper.  extra
    maps a function to bytes of filler added beyond the prediction; the
    functions in zero get zero bytes in place of their filler.  probe is the
    build's (SYM, PHASE) or None; post False leaves out the probed
    function's trailing filler, as a broken backend might."""
    extra = extra or {}
    p = Prog("x86_64", 0x1000)
    trail = [0]

    def place(key):
        pre = p.placed(key, seed, mode, extra.get(key, 0), key in zero, probe, trail[0])
        trail[0] = placehash.fill_after(key, pre, probe) if post else 0

    def unplaced():
        p.fill(trail[0])
        trail[0] = 0

    place(F1)
    p.sym(F1)
    p.op(b"\x55", "pushq\t%rbp")
    p.op(b"\x48\x89\xe5", "movq\t%rsp, %rbp")
    p.op(b"\xe9\x01\x00\x00\x00", "jmp\t{t}", None)
    jmp_at = len(p.items) - 1
    p.nops_to(16)
    head = p.label(LOOP)
    p.items[jmp_at] = p.items[jmp_at][:3] + (head, False)
    p.op(b"\x4d\x39\xd1", "cmpq\t%r10, %r9")
    p.op(b"\x0f\x8c\x05\x00\x00\x00", "jl\t{t}", head + 14)
    p.op(b"\xe9\x05\x00\x00\x00", "jmp\t{t}", head + 23)
    p.label("Lbn_F1_4_main1_2_f1__for.body.2")
    p.op(b"\x48\x83\xc7\x01", "addq\t$0x1, %rdi")
    p.op(b"\xe9\xe7\xff\xff\xff", "jmp\t{t}", head)
    p.label("Lbn_F1_4_main1_2_f1__for.exit.3")
    p.op(b"\x5d", "popq\t%rbp")
    p.op(b"\xc3", "retq")
    place(F2)
    p.sym(F2)
    p.op(b"\x48\xc7\xc0\x07\x00\x00\x00", "movq\t$0x7, %rax")
    p.op(b"\xc3", "retq")
    place(F3)
    p.sym("cexp")
    p.op(b"\x48\x63\xff", "movslq\t%edi, %rdi")
    p.op(b"\xe9\x08\x00\x00\x00", "jmp\t{t}", None)
    alias_jmp = len(p.items) - 1
    p.nops_to(16)
    f3 = p.sym(F3)
    p.items[alias_jmp] = p.items[alias_jmp][:3] + (f3, False)
    p.op(b"\xe8\x00\x01\x00\x00", "callq\t{t}", 0x1000)
    p.op(b"\xc3", "retq")
    unplaced()
    p.nops_to(16)
    p.sym(PKG_A)
    p.op(b"\x48\x8d\x05\x10\x00\x00\x00", "leaq\t0x10(%rip), %rax")
    p.op(b"\xc3", "retq")
    p.start_object(64, gap)
    place(G1)
    p.sym(G1)
    p.op(b"\x31\xc0", "xorl\t%eax, %eax")
    p.op(b"\xc3", "retq")
    place(G2)
    p.sym(G2, " w    F")
    p.op(b"\x48\x85\xff", "testq\t%rdi, %rdi")
    p.op(b"\x74\x01", "je\t{t}", p.pc + 2 + 1)
    p.op(b"\xc3", "retq")
    p.op(b"\xc3", "retq")
    unplaced()
    p.nops_to(16)
    p.sym(PKG_B)
    p.op(b"\xc3", "retq")
    p.nops_to(16)
    p.sym("helper")
    p.op(b"\x0f\x0b", "ud2")
    return p
