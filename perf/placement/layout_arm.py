"""aarch64 and arm32 rules for layout.py: instruction classes and branch kinds.

Function-placement filler is BRK #0x5EED (aarch64) or A32 BKPT #0x5EED
(arm32), told apart from the backends' own traps by its immediate.  Linker
gap fill is zero words or lld's 0xD4D4D4D4 trap pattern; NOP runs are pad.
arm32 data in the code stream (literal pools, marked by $d mapping symbols)
appears as .word / .short / .byte directives and is classified DATA.  A word
the disassembler cannot decode (<unknown>, GNU's <UNDEFINED> or .inst) is
counted as a non-branch instruction.

Branch kinds, aarch64: b, b.cond, bl, br, blr, ret, cbz/cbnz, tbz/tbnz.
arm32 (A32 and Thumb): b, b<cc>, bl, blx, bx, pop{pc}, cbz/cbnz, and
pc-write for any other instruction that writes pc (ldr pc, ldm {..pc} off
another base, mov pc, tbb/tbh).  bx lr, pop {..pc} and mov pc, lr return.
A conditional form (bxeq, popne, ldmeq, moveq pc, ldrne pc, ...) falls
through when its condition fails.

There is no erratum check on these arches; the tables show branch density
instead (branches per instruction).
"""

import layout_disasm as ld
import placehash
from layout_disasm import CODE, FILL, NOP, GAP, DATA

# --window default: 16 bytes (4 instructions), the fetch block of many Arm
# cores; wider front ends fetch 32, and 64 is the usual cache line.
DEFAULT_WINDOW = 16
HAS_ERRATUM = False
# No linker fills a gap with BRK / BKPT #0x5EED: a filler run is all filler.
GAP_FILL_IS_FILLER = False
BRANCH_KINDS = {"aarch64": ("b", "b.cond", "bl", "br", "blr", "ret", "cbz/cbnz",
                            "tbz/tbnz"),
                "arm32": ("b", "b<cc>", "bl", "blx", "bx", "pop{pc}", "cbz/cbnz",
                          "pc-write")}

GAP_WORDS = (b"\x00\x00\x00\x00", b"\xd4\xd4\xd4\xd4")

A64_FILL = placehash.FILL_INSN["aarch64"]
A64_NOP = (0xD503201F).to_bytes(4, "little")
A64_BR = {"br", "braa", "brab", "braaz", "brabz"}
A64_BLR = {"blr", "blraa", "blrab", "blraaz", "blrabz"}
A64_RET = {"ret", "retaa", "retab", "eret", "eretaa", "eretab"}
A64_TRAPS = {"brk", "udf", "hlt"}

A32_FILL = placehash.FILL_INSN["arm32"]
A32_NOPS = {(0xE320F000).to_bytes(4, "little"), (0xE1A00000).to_bytes(4, "little"),
            (0xBF00).to_bytes(2, "little"), (0x46C0).to_bytes(2, "little"),
            bytes([0xAF, 0xF3, 0x00, 0x80])}
CONDS = {"eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc", "hi", "ls",
         "ge", "lt", "gt", "le", "al"}
A32_TRAPS = {"bkpt", "udf"}
A32_REGS = {"r%d" % i for i in range(16)} | {"sb", "sl", "fp", "ip", "sp", "lr", "pc"}


def _common(text, raw, fill, nops):
    """The class of filler, pad, gap and data items, else None (code)."""
    if raw == fill:
        return FILL
    if raw in nops:
        return NOP
    if raw is not None and (not any(raw) or raw in GAP_WORDS):
        return GAP
    if text and text.split(None, 1)[0] in ld.DATA_DIRECTIVES:
        return DATA
    return None


def _strip(text, marks):
    for m in marks:
        text = text.split(m, 1)[0]
    toks = text.split(None, 1)
    if not toks:
        return "", ""
    return toks[0].lower(), (toks[1].strip() if len(toks) > 1 else "")


def decode_aarch64(text, raw):
    """(cls, kind, ft, target text, call, fuse) for one A64 item."""
    cls = _common(text, raw, A64_FILL, (A64_NOP,))
    if cls is not None:
        return cls, None, True, None, False, None
    mnem, ops = _strip(text, ("//", ";"))
    if mnem == "b":
        return CODE, "b", False, ops, False, None
    if mnem.startswith(("b.", "bc.")):
        return CODE, "b.cond", True, ops, False, None
    if mnem == "bl":
        return CODE, "bl", True, ops, True, None
    if mnem in A64_BR:
        return CODE, "br", False, None, False, None
    if mnem in A64_BLR:
        return CODE, "blr", True, None, True, None
    if mnem in A64_RET:
        return CODE, "ret", False, None, False, None
    if mnem in ("cbz", "cbnz"):
        return CODE, "cbz/cbnz", True, ops, False, None
    if mnem in ("tbz", "tbnz"):
        return CODE, "tbz/tbnz", True, ops, False, None
    if mnem in A64_TRAPS:
        return CODE, None, False, None, False, None
    return CODE, None, True, None, False, None


def _cond_of(suffix):
    """(is a condition suffix, conditional) for what follows a base mnemonic."""
    if suffix == "":
        return True, False
    if suffix in CONDS:
        return True, suffix != "al"
    return False, False


def _reglist(ops):
    i, j = ops.find("{"), ops.find("}")
    if i < 0 or j < i:
        return []
    return [r.strip().lower() for r in ops[i + 1:j].split(",")]


def _writes_pc(mnem, ops):
    first = ops.split(",", 1)[0].strip().lower()
    return first == "pc" and not mnem.startswith(("str", "cmp", "tst", "teq", "cmn"))


# Mnemonics that can write pc, longest first so that a prefix does not hide
# a longer base, with the modifiers that may sit next to their condition:
# the S flag of a data-processing instruction, a load-multiple's addressing
# mode, a load's size or privilege suffix.
PC_BASES = sorted([(b, ("s",)) for b in ("mov", "mvn", "add", "adc", "sub", "sbc", "rsb", "rsc",
                                          "and", "orr", "eor", "bic", "lsl", "lsr", "asr",
                                          "ror", "rrx")]
                  + [("ldm", ("ia", "ib", "da", "db", "fd", "fa", "ed", "ea")),
                     ("ldr", ("t",)), ("pop", ())], key=lambda b: -len(b[0]))


def _conditional(mnem):
    """Whether a pc-writing mnemonic carries a condition other than al, in
    UAL (condition after the modifier: ldmiaeq, movseq) or the older order
    (ldmeqia, moveqs).  An unrecognized spelling counts as unconditional."""
    for base, mods in PC_BASES:
        if not mnem.startswith(base):
            continue
        rest = mnem[len(base):]
        for mod in ("",) + mods:
            for tail in (rest[len(mod):] if rest.startswith(mod) else None,
                         rest[:-len(mod)] if mod and rest.endswith(mod) else None):
                if tail is not None and _cond_of(tail)[0]:
                    return _cond_of(tail)[1]
    return False


def decode_arm32(text, raw):
    """(cls, kind, ft, target text, call, fuse) for one A32 or Thumb item."""
    cls = _common(text, raw, A32_FILL, A32_NOPS)
    if cls is not None:
        return cls, None, True, None, False, None
    mnem, ops = _strip(text, ("@", ";"))
    for width in (".n", ".w"):
        if mnem.endswith(width):
            mnem = mnem[:-2]
    if mnem.startswith("b"):
        ok, cond = _cond_of(mnem[1:])
        if ok:
            return CODE, ("b<cc>" if cond else "b"), cond, ops, False, None
        for base in ("blx", "bl", "bx"):
            ok, cond = _cond_of(mnem[len(base):]) if mnem.startswith(base) else (False, 0)
            if not ok:
                continue
            reg = ops.split()[0].lower() if ops else ""
            if base == "bl" or (base == "blx" and reg not in A32_REGS):
                return CODE, base, True, ops, True, None
            if base == "blx":
                return CODE, "blx", True, None, True, None
            return CODE, "bx", cond, None, False, None
    if mnem in ("cbz", "cbnz"):
        return CODE, "cbz/cbnz", True, ops, False, None
    if mnem.startswith("pop") and _cond_of(mnem[3:])[0] and "pc" in _reglist(ops):
        return CODE, "pop{pc}", _cond_of(mnem[3:])[1], None, False, None
    if mnem.startswith("ldm") and "pc" in _reglist(ops):
        ret = ops.lower().startswith("sp!")
        return CODE, ("pop{pc}" if ret else "pc-write"), _conditional(mnem), None, False, None
    if mnem in ("tbb", "tbh"):
        return CODE, "pc-write", False, None, False, None
    if _writes_pc(mnem, ops):
        return CODE, "pc-write", _conditional(mnem), None, False, None
    if mnem[:4] in A32_TRAPS or mnem[:3] in A32_TRAPS:
        return CODE, None, False, None, False, None
    return CODE, None, True, None, False, None


class Rules:
    """The per-arch interface layout.py uses (layout_x86 is the module itself)."""

    def __init__(self, arch):
        self.ARCH = arch
        self.BRANCH_KINDS = BRANCH_KINDS[arch]
        self.DEFAULT_WINDOW = DEFAULT_WINDOW
        self.HAS_ERRATUM = HAS_ERRATUM
        self.GAP_FILL_IS_FILLER = GAP_FILL_IS_FILLER
        self.decode = decode_aarch64 if arch == "aarch64" else decode_arm32
