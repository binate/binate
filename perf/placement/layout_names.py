"""Binate symbol rules for layout.py: which text symbols are block labels,
which functions bnc puts placement filler before, the mangled-name grammar,
and the global symbols the tree's assembly sources define.

Block labels.  The native backends name every non-entry block of a function
L<sym>__<blk>, where <sym> is the function's mangled symbol; on ELF these are
local symbols.  Only that form is a block label.  Other local symbols in code
(an assembly source's own labels, data such as an inline message string) are
resolved per function as code labels or data.

Placement.  bnc's -fnative-place-seed puts filler before every function it
compiles from Binate source: the mangled functions, methods and generic
instantiations of a package (bn_F / bn_I) and bn_entry / bn_init.  The
decorated symbols the backends synthesize after a package's functions (the
func-value shims __shim / __shimP and the package descriptor __Package) get
none, and nor do Binate-mangled functions an assembly source defines.  The
filler is keyed by the symbol itself, so a function is checkable even when
its name falls outside the mangling grammar; binate_func parses the grammar
so that such names can be reported.

Python standard library only; the unit tests are in test_layout_names.py.
"""

import os
import re

# Suffixes of the shim symbols the backends synthesize for a function value.
SYNTH_SUFFIXES = ("__shimP", "__shim")


def block_label(name, funcs):
    """Whether name is a block label L<sym>__<blk> of a function whose symbol
    is in funcs.  The mangled symbol may itself contain '__', so every split
    point is tried."""
    if not name.startswith("L"):
        return False
    i = name.find("__", 2)
    while i >= 0:
        if name[1:i] in funcs:
            return True
        i = name.find("__", i + 1)
    return False


# --- the mangled-name grammar -------------------------------------------------

class _Cursor:
    def __init__(self, s, i):
        self.s, self.i = s, i

    def count(self):
        j = self.i
        while j < len(self.s) and self.s[j].isdigit():
            j += 1
        if j == self.i or j >= len(self.s) or self.s[j] != "_":
            raise ValueError
        digits = self.s[self.i:j]
        if len(digits) > 1 and digits[0] == "0":
            raise ValueError
        self.i = j + 1
        return int(digits)

    def ident(self):
        n = self.count()
        if self.i + n > len(self.s):
            raise ValueError
        self.i += n
        return self.s[self.i - n:self.i]

    def idents(self):
        return [self.ident() for _ in range(self.count())]

    def tag(self):
        if self.i >= len(self.s):
            raise ValueError
        self.i += 1
        return self.s[self.i - 1]

    def typearg(self):
        t = self.tag()
        if t in "pmsMrij":
            self.typearg()
        elif t == "a":
            self.count()
            self.typearg()
        elif t in "fFg":
            for want in "pr":
                if self.tag() != want:
                    raise ValueError
                for _ in range(self.count()):
                    self.typearg()
        elif t == "S":
            for _ in range(self.count()):
                self.ident()
                self.typearg()
        elif t == "N":
            self.idents()
            self.ident()
        else:
            raise ValueError


def _decode(name):
    """(package path, member names) of a mangled bn_F / bn_I function symbol,
    or None when the grammar does not parse all of it."""
    if not name.startswith("bn_") or len(name) < 5 or name[3] not in "FI":
        return None
    c = _Cursor(name, 4)
    try:
        pkg = c.idents()
        if name[3] == "F":
            members = c.idents()
        else:
            members = [c.ident()]
            for _ in range(c.count()):
                c.typearg()
    except ValueError:
        return None
    if c.i != len(name):
        return None
    return "/".join(pkg), members


def binate_func(name):
    """The package path of a function bnc puts placement filler before, when
    its name follows the mangling grammar; None for any other symbol."""
    if name in ("bn_entry", "bn_init"):
        return "main"
    d = _decode(name)
    if d is None or (name[3] == "F" and d[1] == ["__Package"]):
        return None
    return d[0]


def placed(name):
    """Whether bnc puts placement filler before the function whose mangled
    symbol (no object-format prefix) is name.  Unlike binate_func this does
    not require the name to parse: a bn_F / bn_I symbol other than the
    synthesized shims and package descriptor is a compiled function."""
    if name in ("bn_entry", "bn_init"):
        return True
    if not name.startswith(("bn_F", "bn_I")) or name.endswith(SYNTH_SUFFIXES):
        return False
    d = _decode(name)
    return d is None or d[1] != ["__Package"]


# --- assembly sources ---------------------------------------------------------

ASM_GLOBAL_RE = re.compile(r"^\s*\.(?:global|globl|global_c)\s+([A-Za-z_.$][\w.$]*)")
ASM_LABEL_RE = re.compile(r"^\s*([A-Za-z_.$][\w.$]*):")
BUILD_RE = re.compile(r"#\[build\((.*)\)\]")
BUILD_ARCH_RE = re.compile(r'is\(arch,\s*"([^"]+)"\)')
BUILD_ARCH = {"x86_64": "x64", "aarch64": "aarch64", "arm32": "arm32"}


def asm_defined(lines, arch=None):
    """Global symbols an assembly source defines (declared global and
    labeled in it; a global with no label is a reference).  Empty when the
    file's #[build(...)] constraint names architectures and arch is not one
    of them; a constraint with not(...) is not evaluated (the file counts)."""
    glob, labels = set(), set()
    for line in lines:
        m = BUILD_RE.search(line)
        if m and arch is not None and "not(" not in m.group(1):
            archs = BUILD_ARCH_RE.findall(m.group(1))
            if archs and BUILD_ARCH[arch] not in archs:
                return set()
        m = ASM_GLOBAL_RE.match(line)
        if m:
            glob.add(m.group(1))
        m = ASM_LABEL_RE.match(line)
        if m:
            labels.add(m.group(1))
    return glob & labels


def tree_asm_symbols(root, arch=None):
    """Global symbols defined by the *.s files under root (hidden directories
    skipped) whose build constraint admits arch.  bnc assembles these runtime
    sources rather than compiling them, so their Binate-mangled functions get
    no placement filler."""
    out = set()
    for dirpath, dirnames, files in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in files:
            if fn.endswith(".s"):
                with open(os.path.join(dirpath, fn), errors="replace") as fh:
                    out |= asm_defined(fh, arch)
    return out
