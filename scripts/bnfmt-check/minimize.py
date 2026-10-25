#!/usr/bin/env python3
"""Collect and shrink the files a second bnfmt format changes.

usage: minimize.py collect <bnfmt> <dir> < file list
       minimize.py shrink <bnfmt> <dir>
       minimize.py one <bnfmt> <src> <out>

collect formats each listed file twice; for each whose second format differs,
or is rejected (bnfmt cannot parse its own output), it writes <dir>/<n>.src (the
file's path), <n>.1.bn and <n>.2.bn (the two formats; no <n>.2.bn when rejected)
and prints `nonidem <n> <path>` or `refails <n> <path>`, replacing what an
earlier collect left in <dir>.  shrink minimizes each collected file into
<dir>/min/<n>.min.bn.  one minimizes a single file: it deletes lines, then
tokens (delta debugging), while formatting the result twice still gives two
different outputs -- or, for a file whose output bnfmt rejects, still does.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor


def fmt(b, path):
    try:
        r = subprocess.run([b, path], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None
    return r.stdout if r.returncode == 0 else None


def collect(b, out, files):
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if re.fullmatch(r'[0-9]+\.(src|1\.bn|2\.bn)', f):
            os.remove(os.path.join(out, f))
    shutil.rmtree(os.path.join(out, 'min'), ignore_errors=True)

    def check(job):
        i, path = job
        o1 = fmt(b, path)
        if o1 is None:
            return None
        p1 = os.path.join(out, '%d.1.bn' % i)
        with open(p1, 'wb') as f:
            f.write(o1)
        o2 = fmt(b, p1)
        if o2 == o1:
            os.remove(p1)
            return None
        if o2 is not None:
            with open(os.path.join(out, '%d.2.bn' % i), 'wb') as f:
                f.write(o2)
        with open(os.path.join(out, '%d.src' % i), 'w') as f:
            f.write(path + '\n')
        return '%s %d %s' % ('nonidem' if o2 is not None else 'refails', i, path)
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for r in ex.map(check, enumerate(files)):
            if r:
                print(r, flush=True)
    print('checked', len(files))


def ddmin(parts, join, bad):
    n = 2
    while len(parts) >= 2:
        chunk = max(1, len(parts) // n)
        reduced = False
        i = 0
        while i < len(parts):
            cand = parts[:i] + parts[i + chunk:]
            if cand and bad(join(cand)):
                parts = cand
                reduced = True
                n = max(n - 1, 2)
            else:
                i += chunk
        if not reduced:
            if chunk == 1:
                break
            n = min(n * 2, len(parts))
    return parts


TOK = re.compile(r'"(?:[^"\\\n]|\\.)*"|/\*.*?\*/|//[^\n]*|\s+|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|.',
                 re.S)


def one(b, src, out):
    tmp = tempfile.mkdtemp(prefix='bnfmt-min.')
    p = os.path.join(tmp, 'x.bn')

    def second(text):
        """Return (first format, second format) of text; None for a rejected one."""
        with open(p, 'w') as f:
            f.write(text)
        a = fmt(b, p)
        if a is None:
            return None, None
        with open(p, 'wb') as f:
            f.write(a)
        return a, fmt(b, p)
    try:
        with open(src) as f:
            text = f.read()
        a, c = second(text)
        if a is None or c == a:
            sys.exit('%s: a second format does not change it' % src)
        rejects = c is None

        def bad(t):
            a, c = second(t)
            return a is not None and c != a and (c is None) == rejects
        text = '\n'.join(ddmin(text.split('\n'), '\n'.join, bad))
        toks = TOK.findall(text)
        head = []
        while toks and not toks[0].startswith('package'):
            head.append(toks.pop(0))
        toks = ddmin(toks, lambda t: ''.join(head + t), bad)
        text = ''.join(head + toks)
        text = '\n'.join(ddmin(text.split('\n'), '\n'.join, bad))
        with open(out, 'w') as f:
            f.write(text)
    finally:
        shutil.rmtree(tmp)


def shrink(b, d):
    os.makedirs(os.path.join(d, 'min'), exist_ok=True)
    ids = sorted(int(f[:-4]) for f in os.listdir(d) if f.endswith('.src'))

    def job(i):
        with open(os.path.join(d, '%d.src' % i)) as f:
            src = f.read().strip()
        r = subprocess.run([sys.executable, '-I', os.path.abspath(__file__), 'one', b, src,
                            os.path.join(d, 'min', '%d.min.bn' % i)],
                           capture_output=True, text=True)
        return '%d %s' % (i, 'ok' if r.returncode == 0 else r.stderr.strip())
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for r in ex.map(job, ids):
            print(r, flush=True)


if len(sys.argv) >= 2 and sys.argv[1] == 'collect' and len(sys.argv) == 4:
    collect(sys.argv[2], sys.argv[3], [ln.strip() for ln in sys.stdin if ln.strip()])
elif len(sys.argv) >= 2 and sys.argv[1] == 'shrink' and len(sys.argv) == 4:
    shrink(sys.argv[2], sys.argv[3])
elif len(sys.argv) >= 2 and sys.argv[1] == 'one' and len(sys.argv) == 5:
    one(sys.argv[2], sys.argv[3], sys.argv[4])
else:
    sys.exit(__doc__.strip())
