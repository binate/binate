#!/usr/bin/env python3
"""Compare two bnfmt builds on a list of files.

usage: check.py <new bnfmt> <old bnfmt> < file list

Formats each listed file with both builds, and each output again with the build
that made it, and reports, one line per finding:
  differs <file>                  the builds' outputs differ
  rejected <file>                 both builds reject the file
  fails new|old <file>            one build rejects a file the other formats
  nonidem L <file>                formatting the output changes it again
  refails L <file>                the build rejects its own output
  wider <file> <old> <new>        the new output has more lines over 100 bytes
                                  (not counting `// LONG-LINE ALLOWED` lines)
                                  than the old
  tokens L <file> at <k>: ...     the output's tokens differ from the input's,
                                  beyond what bnfmt changes on purpose: the
                                  build changed the program
  comments L <file> at <k>: ...   the output's comments, in order, differ from
                                  the input's: one was lost, added or moved
                                  past another
  program <file> at <k>: ...      the two builds' outputs differ in their
                                  tokens (parentheses included)
where L is new-only, old-only or both (which builds have the finding), and last
a summary line.  Tokens are
compared without comments, `;` and line breaks, with adjacent strings merged, a
comma before a close dropped, and -- against the input -- parentheses dropped
and imports sorted, which bnfmt does itself.  Pass the same build twice to
check one build alone: every finding is then `both`.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

if len(sys.argv) != 3:
    sys.exit(__doc__.strip())
NEW, OLD = sys.argv[1], sys.argv[2]
MAX = 100
MARKER = b'// LONG-LINE ALLOWED'


def lex(s):
    """Return s's tokens -- comments, `;` and white space dropped, adjacent
    strings merged (not an import group's paths), a comma before a close
    dropped -- and its comments, each with its white space collapsed.  The
    source ends at a NUL byte, as it does for the lexer."""
    out = []
    comments = []
    i = 0
    n = s.find('\0')
    n = len(s) if n < 0 else n
    group = False
    while i < n:
        c = s[i]
        if c in ' \t\r\n;':
            i += 1
            continue
        if s.startswith('//', i) or s.startswith('/*', i):
            if s[i + 1] == '/':
                j = s.find('\n', i)
                j = n if j < 0 else j
            else:
                j = s.find('*/', i)
                j = n if j < 0 else j + 2
            comments.append(' '.join(s[i:j].split()))
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == '\\':
                    j += 1
                j += 1
            body = s[i + 1:j]
            if out and out[-1][0] == 'S' and not group:
                out[-1] = ('S', out[-1][1] + body)
            else:
                out.append(('S', body))
            i = j + 1
            continue
        if c in '\'`':
            j = i + 1
            while j < n and s[j] != c:
                if s[j] == '\\':
                    j += 1
                j += 1
            out.append(('C', s[i:j + 1]))
            i = j + 1
            continue
        m = re.match(r'[A-Za-z_0-9]+(?:\.[A-Za-z_0-9]+)*', s[i:i + 300])
        if m and (c.isalnum() or c == '_'):
            out.append(('W', m.group(0)))
            i += len(m.group(0))
            continue
        if c in ')}]' and out and out[-1] == ('P', ','):
            out.pop()
        if c == '(' and out and out[-1] == ('W', 'import'):
            group = True
        elif c == ')':
            group = False
        out.append(('P', c))
        i += 1
    return out, comments


def annotation_end(t, i):
    """Return the index past the annotation `#[...]` at t[i], or i if none."""
    if i + 1 >= len(t) or t[i] != ('P', '#') or t[i + 1] != ('P', '['):
        return i
    depth = 0
    for j in range(i + 1, len(t)):
        if t[j] == ('P', '['):
            depth += 1
        elif t[j] == ('P', ']'):
            depth -= 1
            if depth == 0:
                return j + 1
    return i


def normalized(t):
    """Return tokens t with the import section rebuilt as one sorted entry per
    import spec (its annotation, `import`, alias, path), empty annotations
    (`#[]`) and parentheses dropped: the changes bnfmt makes to a program's
    tokens on purpose."""
    empty = [('P', '#'), ('P', '['), ('P', ']')]
    k = 0
    while k + 3 <= len(t):
        if t[k:k + 3] == empty:
            t = t[:k] + t[k + 3:]
        else:
            k += 1
    i = 2 if len(t) >= 2 and t[0] == ('W', 'package') else 0
    start = i
    entries = []
    while i < len(t):
        j = annotation_end(t, i)
        if j >= len(t) or t[j] != ('W', 'import'):
            break
        ann = t[i:j]
        k = j + 1
        grouped = k < len(t) and t[k] == ('P', '(')
        if grouped:
            k += 1
        while k < len(t):
            if t[k][0] == 'W' and k + 1 < len(t) and t[k + 1][0] == 'S':
                entries.append(tuple(ann) + (('W', 'import'), t[k], t[k + 1]))
                k += 2
            elif t[k][0] == 'S':
                entries.append(tuple(ann) + (('W', 'import'), t[k]))
                k += 1
            else:
                break
            if not grouped:
                break
        if grouped and k < len(t) and t[k] == ('P', ')'):
            k += 1
        i = k
    t = t[:start] + [x for e in sorted(entries) for x in e] + t[i:]
    return [x for x in t if x not in (('P', '('), ('P', ')'))]


def first_diff(a, b):
    k = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    return 'at %d: %s / %s' % (k, a[k:k + 4], b[k:k + 4])


def run(b, path):
    try:
        r = subprocess.run([b, path], capture_output=True, timeout=300)
    except subprocess.TimeoutExpired:
        return None
    return r.stdout if r.returncode == 0 else None


def over(text):
    return sum(1 for ln in text.split(b'\n') if len(ln) > MAX and MARKER not in ln)


def label(old_bad, new_bad):
    if old_bad and new_bad:
        return 'both'
    return 'new-only' if new_bad else 'old-only'


def one(job):
    """Check one file; return its finding lines and its counts."""
    tmp, i, path = job
    res = []
    counts = {}

    def find(kind, line):
        res.append(line)
        counts[kind] = counts.get(kind, 0) + 1

    o1, n1 = run(OLD, path), run(NEW, path)
    if o1 is None and n1 is None:
        find('rejected', 'rejected %s' % path)
        return res, counts
    if o1 is None or n1 is None:
        find('fails', 'fails %s %s' % ('new' if n1 is None else 'old', path))
        return res, counts
    if o1 != n1:
        find('differs', 'differs %s' % path)
    outs = {'old': o1, 'new': n1}
    changed, failed = {}, {}
    for name, b in (('old', OLD), ('new', NEW)):
        p = os.path.join(tmp, '%d.%s.bn' % (i, name))
        with open(p, 'wb') as f:
            f.write(outs[name])
        second = run(b, p)
        os.remove(p)
        failed[name] = second is None
        changed[name] = second is not None and second != outs[name]
    for kind, d in (('nonidem', changed), ('refails', failed)):
        if d['old'] or d['new']:
            lab = label(d['old'], d['new'])
            find(kind + ' ' + lab, '%s %s %s' % (kind, lab, path))
    wo, wn = over(o1), over(n1)
    if wn > wo:
        find('wider', 'wider %s %d %d' % (path, wo, wn))
    elif wn < wo:
        counts['narrower'] = 1
    with open(path, encoding='utf-8', errors='replace') as f:
        st, sc = lex(f.read())
    lexed = {name: lex(out.decode('utf-8', 'replace')) for name, out in outs.items()}
    tok = {name: normalized(lexed[name][0]) != normalized(st) for name in outs}
    cmt = {name: lexed[name][1] != sc for name in outs}
    for kind, d, which in (('tokens', tok, 0), ('comments', cmt, 1)):
        if d['old'] or d['new']:
            lab = label(d['old'], d['new'])
            name = 'new' if d['new'] else 'old'
            src = normalized(st) if which == 0 else sc
            got = normalized(lexed[name][0]) if which == 0 else lexed[name][1]
            find(kind + ' ' + lab, '%s %s %s %s' % (kind, lab, path, first_diff(src, got)))
    if lexed['old'][0] != lexed['new'][0]:
        find('program', 'program %s %s' % (path, first_diff(lexed['old'][0], lexed['new'][0])))
    return res, counts


def main():
    files = [ln.strip() for ln in sys.stdin if ln.strip()]
    tmp = tempfile.mkdtemp(prefix='bnfmt-check.')
    total = {}
    try:
        with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
            for res, counts in ex.map(one, [(tmp, i, f) for i, f in enumerate(files)]):
                for ln in res:
                    print(ln, flush=True)
                for k, v in counts.items():
                    total[k] = total.get(k, 0) + v
    finally:
        shutil.rmtree(tmp)

    def c(kind):
        return '%d/%d/%d' % tuple(total.get('%s %s' % (kind, lab), 0)
                                  for lab in ('new-only', 'old-only', 'both'))
    print('checked %d (rejected %d): differ %d, fail %d; new-only/old-only/both: nonidem %s, '
          'refails %s, tokens %s, comments %s; program %d; wider %d narrower %d' % (
              len(files), total.get('rejected', 0), total.get('differs', 0),
              total.get('fails', 0), c('nonidem'), c('refails'), c('tokens'), c('comments'),
              total.get('program', 0), total.get('wider', 0), total.get('narrower', 0)))


main()
