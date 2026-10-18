"""Tests for binfile.py on synthetic ELF and Mach-O images.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import hashlib
import os
import struct
import tempfile
import unittest

import binfile

TEXT = bytes(range(64)) * 3
INIT = b"\xc3" * 7


def elf(sections, bits=64):
    """An ELF image with sections [(name, flags, type, data)] after a null
    section, and a .shstrtab last."""
    secs = [("", 0, 0, b"")] + list(sections) + [(".shstrtab", 0, 3, None)]
    strtab = b"".join(n.encode() + b"\0" for n, _, _, _ in secs)
    ehsize = 64 if bits == 64 else 52
    body, offs = b"", []
    for n, _, typ, data in secs:
        data = strtab if data is None else data
        offs.append(ehsize + len(body))
        if typ != 8:
            body += data
    shoff = ehsize + len(body)
    shent = 64 if bits == 64 else 40
    shdrs, name_off = b"", 0
    for (n, flags, typ, data), off in zip(secs, offs):
        size = len(strtab if data is None else data)
        if bits == 64:
            shdrs += struct.pack("<IIQQQQIIQQ", name_off, typ, flags, 0, off, size, 0, 0, 1, 0)
        else:
            shdrs += struct.pack("<IIIIIIIIII", name_off, typ, flags, 0, off, size, 0, 0, 1, 0)
        name_off += len(n) + 1
    ident = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1, 1]) + b"\0" * 9
    if bits == 64:
        hdr = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 0, shoff, 0, ehsize, 0, 0,
                                  shent, len(secs), len(secs) - 1)
    else:
        hdr = ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0, 0, shoff, 0, ehsize, 0, 0,
                                  shent, len(secs), len(secs) - 1)
    return hdr + body + shdrs


def macho(sections):
    """A 64-bit Mach-O image with one segment command per segment name, its
    sections [(segname, sectname, flags, data)]."""
    segs = {}
    for seg, sect, flags, data in sections:
        segs.setdefault(seg, []).append((sect, flags, data))
    sizeofcmds = sum(72 + 80 * len(v) for v in segs.values())
    data_off = 32 + sizeofcmds
    cmds, blob = b"", b""
    for seg, ss in segs.items():
        cmds += struct.pack("<II16sQQQQiiII", 0x19, 72 + 80 * len(ss), seg.encode(), 0, 0, 0, 0,
                            7, 5, len(ss), 0)
        for sect, flags, data in ss:
            cmds += struct.pack("<16s16sQQIIIIIIII", sect.encode(), seg.encode(), 0, len(data),
                                data_off + len(blob), 4, 0, 0, flags, 0, 0, 0)
            blob += data
    hdr = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x01000007, 3, 2, len(segs), sizeofcmds, 0, 0)
    return hdr + cmds + blob


class BinfileTest(unittest.TestCase):
    def facts(self, image):
        with tempfile.NamedTemporaryFile(delete=False) as fh:
            fh.write(image)
        try:
            return binfile.text_facts(fh.name)
        finally:
            os.remove(fh.name)

    def test_elf64(self):
        img = elf([(".init", 6, 1, INIT), (".text", 6, 1, TEXT), (".data", 3, 1, b"dd"),
                   (".bss", 3, 8, b"\0" * 100)])
        got = self.facts(img)
        self.assertEqual(got["text_sha256"], hashlib.sha256(TEXT).hexdigest())
        self.assertEqual(got["text_size"], len(TEXT) + len(INIT))

    def test_elf32(self):
        got = self.facts(elf([(".text", 6, 1, TEXT), (".fini", 6, 1, INIT)], bits=32))
        self.assertEqual(got["text_sha256"], hashlib.sha256(TEXT).hexdigest())
        self.assertEqual(got["text_size"], len(TEXT) + len(INIT))

    def test_macho(self):
        img = macho([("__TEXT", "__text", 0x80000400, TEXT),
                     ("__TEXT", "__stubs", 0x80000408, b"\xff" * 12),
                     ("__TEXT", "__cstring", 0x2, b"abc\0"),
                     ("__DATA", "__data", 0, b"xyz")])
        got = self.facts(img)
        self.assertEqual(got["text_sha256"], hashlib.sha256(TEXT).hexdigest())
        self.assertEqual(got["text_size"], len(TEXT) + 12)

    def test_text_change_changes_hash_only_there(self):
        a = self.facts(elf([(".text", 6, 1, TEXT), (".data", 3, 1, b"1")]))
        b = self.facts(elf([(".text", 6, 1, TEXT), (".data", 3, 1, b"2")]))
        c = self.facts(elf([(".text", 6, 1, TEXT[:-1] + b"\xcc"), (".data", 3, 1, b"1")]))
        self.assertEqual(a["text_sha256"], b["text_sha256"])
        self.assertNotEqual(a["text_sha256"], c["text_sha256"])

    def test_errors(self):
        for img in (b"not a binary at all", elf([(".data", 3, 1, b"x")]), b"\x7fELF\x02\x01"):
            with self.assertRaises(ValueError):
                self.facts(img)


if __name__ == "__main__":
    unittest.main()
