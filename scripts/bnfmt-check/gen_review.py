#!/usr/bin/env python3
"""Generate small functions for checking bnfmt's list fill, postfix chains and
switch labels.

usage: gen_review.py <kind> <seed> <count> <out dir>

kind:
  calls        a call with two to four arguments (some after a line comment),
               a short var, or an array of composite literals with trailing
               comments; strings up to 150 bytes and comments up to 100
  calls-short  the same with strings up to 30 bytes and comments up to 15
  postfix      calls, selectors, slices, type assertions and function literals
               nested four levels in one statement
  switch       a switch of two to four cases: labels on one or several lines,
               statements after the colon, line and block comments, blank lines

Writes <out dir>/<c|c|d|e><seed>_<i>.bn for i < count.  The files depend only on
the arguments.
"""
import os
import random
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__.strip())
KIND, SEED, COUNT, OUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
R = random.Random(SEED)


def ident(lo=1, hi=30):
    return R.choice("abcdefghxyz") * R.randint(lo, hi)


def calls(strlens, cmtlens):
    def strlit():
        n = R.choice(strlens)
        n = max(1, n + R.randint(-8, 8))
        body = "".join(R.choice("abcdefgh") for _ in range(n))
        if R.random() < 0.2:
            body = body[:n // 2] + "\\n" + body[n // 2:]
        return '"' + body + '"'

    def comment():
        return "// " + "c" * R.choice(cmtlens)

    def expr(d=0):
        r = R.random()
        if d > 2 or r < 0.25:
            return ident()
        if r < 0.45:
            return strlit()
        if r < 0.65:
            args = [expr(d + 1) for _ in range(R.randint(0, 3))]
            return ident(1, 15) + "(" + ", ".join(args) + ")"
        if r < 0.72:
            return expr(d + 1) + "." + ident(1, 20)
        if r < 0.78:
            return (ident(1, 10) + "(" + expr(d + 1) + ")[" + ident(1, 20) + ":" + ident(1, 30)
                    + "]")
        if r < 0.83:
            return ident(1, 10) + "(" + expr(d + 1) + ").(" + ident(1, 20) + ")"
        if r < 0.88:
            return "(" + ident() + " + " + expr(d + 1) + ")." + ident(1, 10)
        if r < 0.94:
            return "func() int { return " + expr(d + 1) + " }"
        return "T{" + ", ".join(expr(d + 1) for _ in range(R.randint(1, 3))) + "}"

    k = R.random()
    if k < 0.5:
        args = [expr() for _ in range(R.randint(2, 4))]
        s = "\tg(" + args[0]
        for a in args[1:]:
            if R.random() < 0.4:
                s += ", " + comment() + "\n\t\t\t" + a
            else:
                s += ", " + a
        return s + ")"
    if k < 0.8:
        return "\tx := " + expr() + (" " + comment() if R.random() < 0.3 else "")
    elems = [expr() for _ in range(R.randint(2, 3))]
    s = "\tvar t = [3]T{\n"
    for e in elems:
        s += ("\t\tT{" + e + ", " + expr() + "}," + (" " + comment() if R.random() < 0.6 else "")
              + "\n")
    return s + "\t}"


def postfix():
    def expr(d=0):
        r = R.random()
        if d > 3 or r < 0.2:
            return ident()
        if r < 0.4:
            args = [expr(d + 1) for _ in range(R.randint(0, 3))]
            return ident(1, 15) + "(" + ", ".join(args) + ")"
        if r < 0.5:
            return expr(d + 1) + "." + ident(1, 20)
        if r < 0.6:
            return expr(d + 1) + "[" + ident(0, 20) + ":" + ident(0, 30) + "]"
        if r < 0.68:
            return expr(d + 1) + ".(" + ident(1, 20) + ")"
        if r < 0.75:
            return "(" + ident() + " + " + expr(d + 1) + ")." + ident(1, 10)
        if r < 0.88:
            return ("func() int { return " + expr(d + 1) + " }"
                    + R.choice(["", "()", "(" + ident() + ")"]))
        if r < 0.94:
            return expr(d + 1) + "()"
        return "T{" + ", ".join(expr(d + 1) for _ in range(R.randint(1, 3))) + "}"

    k = R.random()
    if k < 0.5:
        return "\tg(" + ", ".join(expr() for _ in range(R.randint(1, 3))) + ")"
    if k < 0.8:
        return "\tx := " + expr()
    return "\tvar r = " + expr() + R.choice(["", " // c"])


def switch():
    def ident20():
        return ident(1, 20)

    def cmt():
        r = R.random()
        if r < 0.4:
            return " // " + "k" * R.randint(1, 30)
        if r < 0.6:
            return " /* " + "b" * R.randint(1, 20) + " */"
        if r < 0.7:
            return " /* m\n\t" + "n" * R.randint(1, 10) + " */"
        return ""

    s = "\tswitch {\n"
    for _ in range(R.randint(2, 4)):
        labels = [ident(1, R.choice([5, 20, 40])) for _ in range(R.randint(1, 3))]
        lab = "\tcase "
        for j, label in enumerate(labels):
            if j > 0:
                lab += "," + ("\n\t\t" if R.random() < 0.4 else " ")
            lab += label
        if R.random() < 0.15:
            lab = "\tdefault"
        lab += ":"
        r = R.random()
        if r < 0.3:
            lab += cmt()
        elif r < 0.6:
            lab += " " + ident20() + "()" + cmt()
        s += lab + "\n"
        for _ in range(R.randint(0, 2)):
            s += "\t\t" + ident20() + "()" + cmt() + "\n"
            if R.random() < 0.2:
                s += "\n"
        if R.random() < 0.2:
            s += "\n"
    s += "\t}"
    return s + "\n\tx := 1" + cmt() + "\n" + ("\n" if R.random() < 0.5 else "") + "\ty := 2"


KINDS = {
    'calls': ('c', lambda: calls([5, 20, 40, 60, 80, 95, 110, 150], [3, 20, 40, 60, 85, 100])),
    'calls-short': ('c', lambda: calls([5, 10, 20, 30], [3, 8, 15])),
    'postfix': ('d', postfix),
    'switch': ('e', switch),
}
if KIND not in KINDS:
    sys.exit(__doc__.strip())
PREFIX, BODY = KINDS[KIND]
os.makedirs(OUT, exist_ok=True)
for n in range(COUNT):
    src = 'package "p"\n\nfunc f() {\n' + BODY() + "\n}\n"
    with open(os.path.join(OUT, "%s%d_%d.bn" % (PREFIX, SEED, n)), "w") as f:
        f.write(src)
