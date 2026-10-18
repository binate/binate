"""Binary reading for layout.py: object-format and architecture detection, the
disassembler to run, and parsers for its symbol-table and disassembly text.

Symbols come from the symbol table (`objdump -t`), not from the labels in the
disassembly, because GNU objdump prints only one label per address and so can
hide a function behind an alias that shares its entry.  The disassembly gives
the instruction stream: one Rec per instruction, data directive or run of
skipped zero bytes.  Three syntaxes are understood: llvm-objdump's default
layout, its --macho layout, and GNU objdump (whose x86 output wraps long
instructions onto continuation lines unless run with -w).

Python standard library only; the unit tests are in test_layout_disasm.py.
"""

import re
import shutil
import struct
import subprocess

from layout_names import block_label

# Instruction classes.  NOP is a no-op whose role (executed code or alignment
# pad) is decided per function; PAD is a NOP run so decided to be padding.
CODE, FILL, NOP, PAD, GAP, DATA = "code", "fill", "nop", "pad", "gap", "data"

# Symbol roles in an executable section.
FUNC, LABEL, MAPC, MAPD, OTHER = "func", "label", "mapc", "mapd", "other"


class Rec:
    """One disassembled item.  kind is the arch's branch kind (None for a
    non-branch); ft is whether execution can continue at the next item; tgt is
    a direct transfer's target address (calls included, with call=True); fuse
    is arch-specific (x86: a fusible ALU family, or a jcc's condition)."""
    __slots__ = ("addr", "size", "cls", "kind", "ft", "tgt", "call", "fuse")

    def __init__(self, addr, size, cls=CODE, kind=None, ft=True, tgt=None,
                 call=False, fuse=None):
        self.addr, self.size, self.cls, self.kind = addr, size, cls, kind
        self.ft, self.tgt, self.call, self.fuse = ft, tgt, call, fuse

    @property
    def end(self):
        return self.addr + self.size

    def __repr__(self):
        return "Rec(%#x,%d,%s,%s)" % (self.addr, self.size, self.cls, self.kind)


class Sym:
    """A symbol-table entry; flags are objdump's 7 flag characters (index 0
    binding, 5 debugging/section, 6 type: F function, f file, O object)."""
    __slots__ = ("addr", "name", "section", "flags")

    def __init__(self, addr, name, section, flags):
        self.addr, self.name, self.section, self.flags = addr, name, section, flags

    @property
    def is_func(self):
        return self.flags[6:7] == "F"

    @property
    def is_local(self):
        return self.flags[:1] == "l"


# --- format and architecture -------------------------------------------------

ELF_MACHINES = {62: "x86_64", 183: "aarch64", 40: "arm32"}
MACHO_CPUS = {0x01000007: "x86_64", 0x0100000C: "aarch64", 12: "arm32"}


def detect(head):
    """(format, arch) from the first bytes of a binary: format "elf" or
    "macho", arch "x86_64", "aarch64" or "arm32".  Raises ValueError (for a
    header too short to hold the fields read, too)."""
    if head[:4] == b"\x7fELF":
        if len(head) < 20:
            raise ValueError("truncated ELF header")
        if head[5] != 1:
            raise ValueError("big-endian ELF is not supported")
        machine = struct.unpack_from("<H", head, 18)[0]
        if machine not in ELF_MACHINES:
            raise ValueError("unsupported ELF machine %d" % machine)
        return "elf", ELF_MACHINES[machine]
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        if len(head) < 8:
            raise ValueError("truncated Mach-O header")
        cpu = struct.unpack_from("<I", head, 4)[0]
        if cpu not in MACHO_CPUS:
            raise ValueError("unsupported Mach-O CPU type %#x" % cpu)
        return "macho", MACHO_CPUS[cpu]
    raise ValueError("not an ELF or little-endian Mach-O file")


LLVM_NAMES = ["llvm-objdump"] + ["llvm-objdump-%d" % v for v in range(22, 13, -1)]
GNU_NAMES = {"x86_64": ["objdump"],
             "arm32": ["arm-linux-gnueabihf-objdump", "arm-none-eabi-objdump"],
             "aarch64": ["aarch64-linux-gnu-objdump"]}


def pick_tool(fmt, arch, which=shutil.which):
    """(path, flavor) of the disassembler: llvm-objdump when present, else the
    GNU objdump for the arch (ELF only).  Raises RuntimeError."""
    for name in LLVM_NAMES:
        path = which(name)
        if path:
            return path, "llvm"
    if fmt == "elf":
        for name in GNU_NAMES[arch]:
            path = which(name)
            if path:
                return path, "gnu"
    raise RuntimeError("no disassembler found: install llvm-objdump"
                       + (" or %s" % GNU_NAMES[arch][0] if fmt == "elf" else ""))


def symtab_cmd(tool, flavor, path):
    return [tool, "-t", path]


def headers_cmd(tool, flavor, path):
    return [tool, "-h", path]


def disasm_cmds(tool, flavor, fmt, path, arch=None, headers=None):
    """The disassembly commands, whose outputs are read one after another.
    On ELF one run covers every executable section.  On Mach-O the --macho
    layout (which prints words it cannot decode, such as a string in code,
    as .long) covers only __TEXT,__text, so the other executable sections
    parse_sections found in headers (the __stubs and __stub_helper linker
    stubs, the counterpart of ELF's .plt) get a second, plain run.
    llvm-objdump decodes an arm32 binary that carries no build attributes as
    an older architecture than the native backend's ARMv7-A target (without
    SDIV/UDIV, UXTB, ...), so arm32 is disassembled as armv7a with the
    integer-divide extension."""
    if flavor == "gnu":
        return [[tool, "-d", "-w", path]]
    if fmt == "macho":
        extra = [n for n in exec_sections(headers or {}) if n != "__text"]
        return [[tool, "-d", "--macho", path]] + (
            [[tool, "-d"] + ["--section=%s" % n for n in extra] + [path]] if extra else [])
    if arch == "arm32":
        return [[tool, "-d", "--triple=armv7a", "--mattr=+hwdiv-arm", path]]
    return [[tool, "-d", path]]


def run_lines(cmd):
    """Yield the stdout lines of cmd; raise RuntimeError if it fails."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, errors="replace", bufsize=1 << 20)
    for line in proc.stdout:
        yield line
    err = proc.stderr.read()
    if proc.wait() != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(cmd), err.strip()))


# --- symbol table --------------------------------------------------------------

SYM_RE = re.compile(r"^([0-9a-fA-F]+) (.{7}) (\S+)(?:\t([0-9a-fA-F]+))?\s+(.*)$")
VISIBILITY = (".hidden ", ".protected ", ".internal ")


def strip_prefix(name, fmt):
    """The symbol without the object-format prefix (Mach-O's leading '_')."""
    if fmt == "macho" and name.startswith("_"):
        return name[1:]
    return name


def parse_symtab(lines, fmt):
    """Syms defined in a section, from `objdump -t` text (llvm or GNU);
    section and file symbols (flags d and f) are skipped."""
    out = []
    for line in lines:
        m = SYM_RE.match(line.rstrip("\n"))
        if not m:
            continue
        sec = m.group(3)
        if sec.startswith("*") or sec == "UND":
            continue
        flags = m.group(2)
        if flags[5:6] == "d" or flags[6:7] == "f":
            continue
        name = m.group(5).strip()
        for v in VISIBILITY:
            if name.startswith(v):
                name = name[len(v):].strip()
        if not name:
            continue
        out.append(Sym(int(m.group(1), 16), strip_prefix(name, fmt), sec, flags))
    return out


MAP_RE = re.compile(r"^\$([atdx])(\..*)?$")


def sym_role(sym, typed, funcs):
    """FUNC, LABEL (a block label of a function in funcs, the set of
    function names), MAPC/MAPD (mapping symbols), or OTHER: a symbol that is
    neither typed as a function nor a block label, so it starts either data
    or a code label (decided per function).  Another local L symbol (an
    assembly source's local label) is OTHER even in a binary with no symbol
    types (typed false), where every remaining symbol is a function."""
    m = MAP_RE.match(sym.name)
    if m:
        return MAPD if m.group(1) == "d" else MAPC
    if sym.is_func:
        return FUNC
    if sym.is_local and sym.name.startswith("L"):
        return LABEL if block_label(sym.name, funcs) else OTHER
    return OTHER if typed else FUNC


def func_names(syms, typed):
    """The names sym_role treats as functions' (block labels name these)."""
    if typed:
        return {s.name for s in syms if s.is_func}
    return {s.name for s in syms if not (s.is_local and s.name.startswith("L"))
            and not MAP_RE.match(s.name)}


# --- disassembly -------------------------------------------------------------

ADDR_RE = re.compile(r"^\s*([0-9a-fA-F]+):[ \t]")
SECTION_RE = re.compile(r"^Disassembly of section (\S+):|^\((\S+)\) section")
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")
DIRECTIVE_SIZE = {".byte": 1, ".short": 2, ".hword": 2, ".2byte": 2, ".long": 4,
                  ".word": 4, ".4byte": 4, ".inst": 4, ".quad": 8, ".8byte": 8}
# Directives that print data; .inst is an instruction word GNU cannot decode.
DATA_DIRECTIVES = frozenset(DIRECTIVE_SIZE) - {".inst"}


def raw_bytes(field):
    """Bytes from an objdump raw-bytes field: 2-digit groups are bytes in
    address order, 4- and 8-digit groups little-endian halfwords and words.
    None when the field is empty or malformed."""
    groups = field.split()
    if groups and all(len(g) == 2 for g in groups):
        try:
            return bytes.fromhex(field)
        except ValueError:
            return None
    out = bytearray()
    for g in groups:
        if not HEX_RE.match(g) or len(g) not in (2, 4, 8):
            return None
        out += int(g, 16).to_bytes(len(g) // 2, "little")
    return bytes(out) if out else None


def split_line(line):
    """(addr, raw, text) for an instruction or data line, where text is None
    on a GNU continuation line (more raw bytes of the previous instruction);
    None for any other line."""
    m = ADDR_RE.match(line)
    if not m:
        return None
    rest = line[m.end():].rstrip("\n")
    tab = rest.find("\t")
    if tab < 0:
        raw = raw_bytes(rest)
        return (int(m.group(1), 16), raw, None) if raw else None
    field, text = rest[:tab], rest[tab + 1:].strip()
    raw = raw_bytes(field)
    if raw is None and field.strip():
        return None
    return int(m.group(1), 16), raw, text


def item_size(raw, text):
    if raw is not None:
        return len(raw)
    word = text.split(None, 1)[0] if text else ""
    return DIRECTIVE_SIZE.get(word)


TARGET_RE = re.compile(r"^(?:0x)?([0-9a-fA-F]+)$")
SYMOFF_RE = re.compile(r"^(\S+?)(?:\+(0x[0-9a-fA-F]+|\d+))?$")


def resolve_target(text, fmt, symaddr):
    """The address a branch operand names: hex with or without 0x (any
    trailing <symbol> annotation ignored), or a symbol name plus offset as
    llvm-objdump --macho prints calls.  None when unresolvable."""
    t = text.split("<", 1)[0].strip()
    if "," in t:
        t = t.rsplit(",", 1)[1].strip()
    m = TARGET_RE.match(t)
    if m:
        return int(m.group(1), 16)
    m = SYMOFF_RE.match(t)
    if m:
        base = symaddr.get(strip_prefix(m.group(1), fmt))
        if base is not None:
            off = m.group(2)
            return base + (int(off, 0) if off else 0)
    return None


def _make(addr, raw, text, decode, fmt, symaddr):
    size = item_size(raw, text)
    if size is None:
        return None
    cls, kind, ft, tgt, call, fuse = decode(text, raw)
    t = resolve_target(tgt, fmt, symaddr) if tgt else None
    return Rec(addr, size, cls, kind, ft, t, call, fuse)


def parse_disasm(lines, decode, fmt, symaddr):
    """Yield (section, Rec) for every item of the disassembly, in order.
    Bytes the disassembler skipped (its '...' zero runs) become GAP Recs.
    decode(text, raw) is the arch's classifier (see layout_x86/layout_arm)."""
    sec, pend, end = None, None, None
    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            if pend is not None:
                yield sec, pend
            sec, pend, end = m.group(1) or m.group(2), None, None
            continue
        parts = split_line(line)
        if parts is None or sec is None:
            continue
        addr, raw, text = parts
        if text is None:
            if pend is not None and pend.end == addr:
                rawp = pending_raw + raw
                pend = _make(pend.addr, rawp, pending_text, decode, fmt, symaddr)
                pending_raw = rawp
            continue
        rec = _make(addr, raw, text, decode, fmt, symaddr)
        if rec is None:
            continue
        if pend is not None:
            yield sec, pend
            end = pend.end
        if end is not None and addr > end:
            yield sec, Rec(end, addr - end, GAP, ft=True)
        elif end is not None and addr < end:
            pend = None
            continue
        pend, pending_raw, pending_text = rec, raw or b"", text
    if pend is not None:
        yield sec, pend


SECHDR_RE = re.compile(r"^\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\b(?:\s+(\S+))?")


def parse_sections(lines):
    """{name: (vma, size, type)} from `objdump -h` text (llvm or GNU), type
    being llvm-objdump's TEXT / DATA / BSS column (None in GNU's layout).
    Mach-O section names (__text) also answer for their segment-qualified
    spelling (__TEXT,__text) through section_extent."""
    out = {}
    for line in lines:
        m = SECHDR_RE.match(line)
        if m:
            kind = m.group(4) if m.group(4) and not HEX_RE.match(m.group(4)) else None
            out.setdefault(m.group(1), (int(m.group(3), 16), int(m.group(2), 16), kind))
    return out


def exec_sections(headers):
    """Names of the sections parse_sections typed TEXT, in address order."""
    return [n for n, v in sorted(headers.items(), key=lambda kv: kv[1][0]) if v[2] == "TEXT"]


def section_extent(headers, name):
    """(start, end) of a disassembled section from parse_sections' result."""
    hit = headers.get(name) or headers.get(name.rsplit(",", 1)[-1])
    return (hit[0], hit[0] + hit[1]) if hit else None
