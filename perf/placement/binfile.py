"""Executable-section facts of a linked binary, read straight from its headers.

text_facts(path) gives what a placement A/B build log needs without running a
disassembler: the SHA-256 of the main code section (.text on ELF, __TEXT,__text
on Mach-O), whose bytes are what placement filler changes, and the total size
of the executable sections (ELF SHF_EXECINSTR; Mach-O sections holding
instructions), the "text bytes" layout.py's summary reports for the same
binary.  Little-endian ELF (32- and 64-bit) and thin little-endian Mach-O
(32- and 64-bit) are understood.

Python standard library only.  The tests are in test_binfile.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import hashlib
import struct
from collections import namedtuple

SHF_EXECINSTR = 0x4
SHT_NOBITS = 8
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
S_ATTR_SOME_INSTRUCTIONS = 0x00000400
S_ZEROFILL_TYPES = (0x1, 0xC, 0x12)
LC_SEGMENT, LC_SEGMENT_64 = 0x1, 0x19
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe": 64, b"\xce\xfa\xed\xfe": 32}

Section = namedtuple("Section", "name offset size exec nobits")


def _cstr(raw):
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def elf_sections(data):
    """The section headers of a little-endian ELF image."""
    if data[5] != 1:
        raise ValueError("big-endian ELF is not supported")
    if data[4] == 2:
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        fmt, fields = "<IIQQQQ", 6
    elif data[4] == 1:
        shoff = struct.unpack_from("<I", data, 0x20)[0]
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
        fmt, fields = "<IIIIII", 6
    else:
        raise ValueError("unknown ELF class %d" % data[4])
    if shoff == 0:
        raise ValueError("ELF file has no section headers")
    raw = []
    for i in range(shnum):
        raw.append(struct.unpack_from(fmt, data, shoff + i * shentsize)[:fields])
    if not raw or shstrndx >= len(raw):
        raise ValueError("ELF section-name table missing")
    stroff = raw[shstrndx][4]
    out = []
    for name, typ, flags, _addr, off, size in raw:
        end = data.index(b"\0", stroff + name)
        out.append(Section(data[stroff + name:end].decode("ascii", "replace"), off, size,
                           bool(flags & SHF_EXECINSTR), typ == SHT_NOBITS))
    return out


def macho_sections(data):
    """The sections of a thin little-endian Mach-O image, named SEG,sect."""
    bits = MACHO_MAGIC[bytes(data[:4])]
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32 if bits == 64 else 28
    out = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd in (LC_SEGMENT, LC_SEGMENT_64):
            wide = cmd == LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, off + (64 if wide else 48))[0]
            p = off + (72 if wide else 56)
            for _ in range(nsects):
                sect, seg = _cstr(data[p:p + 16]), _cstr(data[p + 16:p + 32])
                if wide:
                    _addr, ssize, soff = struct.unpack_from("<QQI", data, p + 32)
                    flags = struct.unpack_from("<I", data, p + 64)[0]
                    p += 80
                else:
                    _addr, ssize, soff = struct.unpack_from("<III", data, p + 32)
                    flags = struct.unpack_from("<I", data, p + 56)[0]
                    p += 68
                exe = bool(flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))
                out.append(Section("%s,%s" % (seg, sect), soff, ssize, exe,
                                   (flags & 0xFF) in S_ZEROFILL_TYPES))
        off += size
    return out


def sections(data):
    """(format, sections) of an ELF or Mach-O image; ValueError otherwise."""
    if bytes(data[:4]) == b"\x7fELF":
        return "elf", elf_sections(data)
    if bytes(data[:4]) in MACHO_MAGIC:
        return "macho", macho_sections(data)
    raise ValueError("not a little-endian ELF or thin Mach-O file")


TEXT_NAME = {"elf": ".text", "macho": "__TEXT,__text"}


def text_facts(path):
    """{'text_sha256': SHA-256 hex of the main code section's bytes,
    'text_size': total bytes of the executable sections} for the binary at
    path.  Raises ValueError for an unreadable format or no code section."""
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        fmt, secs = sections(data)
    except (struct.error, IndexError, KeyError, ValueError) as e:
        raise ValueError("%s: %s" % (path, e or "truncated headers"))
    main = [s for s in secs if s.name == TEXT_NAME[fmt]]
    if not main:
        raise ValueError("%s: no %s section" % (path, TEXT_NAME[fmt]))
    t = main[0]
    body = b"" if t.nobits else data[t.offset:t.offset + t.size]
    return {"text_sha256": hashlib.sha256(body).hexdigest(),
            "text_size": sum(s.size for s in secs if s.exec)}
