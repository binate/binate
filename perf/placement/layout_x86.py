"""x86-64 rules for layout.py: instruction classes, branch kinds, macro-fusion
and the JCC erratum.

The JCC erratum (Skylake through Cascade Lake / Comet Lake, after Intel's
microcode update): a 32-byte chunk of code holding a jump that crosses a
32-byte boundary or ends on one is not served from the decoded-uop cache.
Every jump counts (jcc, jmp, call, ret and indirect transfers), and a
macro-fused cmp/test/add/sub/and/inc/dec + jcc pair counts as one unit from
the first instruction's start to the jcc's end.  A unit starting at s with
length n is hit when (s mod 32) + n >= 32.

The uop cache holds at most 18 uops per 32-byte window (3 ways of 6), so a
window holding more than DENSE_LIMIT instructions is flagged as a rough
capacity proxy.

Disassembly is AT&T syntax as llvm-objdump and GNU objdump print it.  An
encoding the disassembler cannot decode ((bad), <unknown>) is counted as a
non-branch instruction; data directives are DATA.
"""

import layout_disasm as ld
from layout_disasm import CODE, FILL, NOP, GAP, DATA

ARCH = "x86_64"
ERRATUM_WINDOW = 32
DENSE_LIMIT = 18
# --window default: the 32-byte window the decoded-uop cache works in.
DEFAULT_WINDOW = 32
BRANCH_KINDS = ("jcc", "jmp", "call", "ret", "ijmp", "icall")
HAS_ERRATUM = True
# lld fills the gaps between x86-64 input sections with INT3, the placement
# filler's own encoding, so a filler run can hold linker fill.
GAP_FILL_IS_FILLER = True

PREFIXES = {"rep", "repz", "repe", "repne", "repnz", "lock", "bnd", "notrack",
            "data16", "data32", "addr32", "cs", "ds", "es", "ss", "fs", "gs",
            "rex", "rex.w", "rex64", "xacquire", "xrelease"}

# Condition suffixes of jcc mnemonics, by their canonical flag test.
JCC_CONDS = {"o": "o", "no": "no", "b": "b", "c": "b", "nae": "b", "ae": "ae",
             "nb": "ae", "nc": "ae", "e": "e", "z": "e", "ne": "ne", "nz": "ne",
             "be": "be", "na": "be", "a": "a", "nbe": "a", "s": "s", "ns": "ns",
             "p": "p", "pe": "p", "np": "np", "po": "np", "l": "l", "nge": "l",
             "ge": "ge", "nl": "ge", "le": "le", "ng": "le", "g": "g", "nle": "g"}

FAMILIES = ("cmp", "test", "add", "sub", "and", "inc", "dec")

# The jcc conditions each ALU family macro-fuses with (Intel Skylake rules):
# TEST and AND with every jcc; CMP, ADD and SUB not with the overflow, sign or
# parity tests; INC and DEC only with the zero and signed-compare tests.
_ALL = set(JCC_CONDS.values())
FUSES = {"test": _ALL, "and": _ALL,
         "cmp": _ALL - {"o", "no", "s", "ns", "p", "np"},
         "inc": {"e", "ne", "l", "ge", "le", "g"}}
FUSES["add"] = FUSES["sub"] = FUSES["cmp"]
FUSES["dec"] = FUSES["inc"]

RETS = {"ret", "retq", "retl", "retw", "lret", "lretq", "lretl", "iret", "iretq"}
JMPS = {"jmp", "jmpq", "jmpl", "jmpw"}
CALLS = {"call", "callq", "calll", "callw"}
TRAPS = {"ud2", "ud1", "ud0", "hlt"}
LOOPS = {"loop", "loope", "loopz", "loopne", "loopnz", "jcxz", "jecxz", "jrcxz"}


def is_nop(raw):
    """Whether raw encodes a NOP: 0x90 or 0F 1F, after any 66 / 2E prefixes."""
    i = 0
    while i < len(raw) and raw[i] in (0x66, 0x2E):
        i += 1
    rest = raw[i:]
    return rest == b"\x90" or rest[:2] == b"\x0f\x1f"


def split_operands(ops):
    """AT&T operands split at commas outside parentheses."""
    out, depth, cur = [], 0, []
    for ch in ops:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur and "".join(cur).strip():
        out.append("".join(cur).strip())
    return out


def _is_mem(op):
    """Whether an AT&T operand addresses memory: anything but an immediate
    or a register, a segment-override absolute address (%fs:0x10) included."""
    return "(" in op or ":" in op or not op.startswith(("$", "%"))


def fusion_family(mnem, ops):
    """The macro-fusion family of an ALU instruction that can fuse with a
    following jcc, else None.  It cannot when it has both a memory operand and
    an immediate, uses RIP-relative addressing, or (ADD/SUB/AND/INC/DEC)
    writes memory."""
    fam = mnem if mnem in FAMILIES else None
    if fam is None and len(mnem) > 1 and mnem[-1] in "bwlq" and mnem[:-1] in FAMILIES:
        fam = mnem[:-1]
    if fam is None:
        return None
    operands = split_operands(ops)
    if "%rip" in ops:
        return None
    mem = any(_is_mem(o) for o in operands)
    if mem and any(o.startswith("$") for o in operands):
        return None
    if fam not in ("cmp", "test") and operands and _is_mem(operands[-1]):
        return None
    return fam


def fuses(family, cond):
    return family in FUSES and cond in FUSES[family]


def decode(text, raw):
    """(cls, kind, ft, target text, call, fuse) for one item.  fuse is the
    fusion family of a fusible ALU instruction, or a jcc's canonical
    condition (None for the jcxz/loop forms, which never fuse)."""
    if raw == b"\xcc":
        return FILL, None, True, None, False, None
    if raw and is_nop(raw):
        return NOP, None, True, None, False, None
    if raw and not any(raw):
        return GAP, None, True, None, False, None
    text = text.split("#", 1)[0]
    toks = text.split()
    while toks and toks[0].lower() in PREFIXES:
        toks = toks[1:]
    if toks and toks[0] in ld.DATA_DIRECTIVES:
        return DATA, None, True, None, False, None
    if not toks or toks[0].startswith(("(bad)", "<")):
        return CODE, None, True, None, False, None
    mnem, ops = toks[0].lower(), " ".join(toks[1:])
    if mnem in RETS:
        return CODE, "ret", False, None, False, None
    if mnem in JMPS or mnem == "ljmp":
        if ops.startswith("*") or mnem == "ljmp":
            return CODE, "ijmp", False, None, False, None
        return CODE, "jmp", False, ops, False, None
    if mnem in CALLS or mnem == "lcall":
        if ops.startswith("*") or mnem == "lcall":
            return CODE, "icall", True, None, True, None
        return CODE, "call", True, ops, True, None
    if mnem in LOOPS:
        return CODE, "jcc", True, ops, False, None
    if mnem[0] == "j" and mnem[1:] in JCC_CONDS:
        return CODE, "jcc", True, ops, False, JCC_CONDS[mnem[1:]]
    if mnem in TRAPS:
        return CODE, None, False, None, False, None
    return CODE, None, True, None, False, fusion_family(mnem, ops)


def units(recs):
    """JCC-erratum units of a run of items in address order, as
    (start, length, fused) for every branch; a jcc directly after a fusible
    ALU instruction forms one unit with it."""
    out, prev = [], None
    for r in recs:
        if r.cls != CODE:
            prev = None
            continue
        if r.kind is not None:
            if (r.kind == "jcc" and prev is not None and prev.kind is None
                    and prev.end == r.addr and prev.fuse in FAMILIES
                    and fuses(prev.fuse, r.fuse)):
                out.append((prev.addr, prev.size + r.size, True))
            else:
                out.append((r.addr, r.size, False))
        prev = r
    return out


def hit(start, length, window=ERRATUM_WINDOW):
    """Whether a unit crosses or ends on a window boundary."""
    return start % window + length >= window


def hit_windows(start, length, window=ERRATUM_WINDOW):
    """Indexes of the windows a hit unit occupies."""
    return range(start // window, (start + length - 1) // window + 1)
