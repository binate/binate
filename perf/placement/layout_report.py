"""Output for layout.py: the whole-binary summary, the function, loop,
compare and expect-seed tables, as text, --tsv (one table per '# name'
block, a header row first) or --json.

Columns: m16/m32/m64 are the address modulo 16/32/64 (hdr_m32/hdr_m64 for
a loop header); windows and lines count the --window-byte windows and
--line-byte lines a function's trimmed extent or a loop's footprint spans
(none for an empty extent).  x86-64 adds jcc (JCC-erratum hit units inside
the function or the loop's member blocks), jccw (its 32-byte windows that
some hit unit affects, wherever in the binary that unit lies: the erratum
keeps a whole window out of the decoded-uop cache) and, for functions,
dense (32-byte windows over the instruction limit); aarch64 and arm32 add
brden (branches per 100 instructions) and maxbr (most branches in one
window).  With --hot, hot is the perf overhead in percent credited to a
function or loop, and both tables are sorted by it.  In --compare, dm64 is
the function's move modulo 64 (its b address minus its a address), a loop
is matched by its function and key (see layout_loops.loop_keys), and functions
and loops found in one build only are counted (only_a / only_b,
loops_only_a / loops_only_b).
"""

import json
from collections import Counter

import layout_x86

SEED_TEXT_ROWS = 50


def _match(f, funcs):
    return not funcs or any(r.search(n) for r in funcs for n in f.names)


def summary(lay):
    secs = {n: {"start": s, "end": e, "bytes": e - s} for n, (s, e) in lay.sections.items()}
    placed = [i for i, f in enumerate(lay.funcs) if f.placed]
    hist_all = Counter(f.addr % 64 for f in lay.funcs)
    hist_bn = Counter(lay.funcs[lay.entry_index(i)].addr % 64 for i in placed)
    nbytes = lay.byte_counts()
    s = {"binary": lay.path, "format": lay.fmt, "arch": lay.arch, "tool": lay.tool,
         "window": lay.window, "line": lay.line, "sections": secs,
         "text_bytes": sum(v["bytes"] for v in secs.values()),
         "bytes": {k: nbytes.get(k, 0) for k in ("code", "fill", "pad", "gap", "data")},
         "unnamed_code": lay.unnamed,
         "functions": len(lay.funcs), "binate_functions": len(placed),
         "unparsed_names": [lay.funcs[i].name for i in placed if lay.funcs[i].pkg is None],
         "instructions": lay.insns,
         "branches": {k: lay.kinds.get(k, 0) for k in lay.rules.BRANCH_KINDS},
         "start_mod_64": {p: [hist_bn.get(p, 0), hist_all.get(p, 0)]
                          for p in sorted(set(hist_all) | set(hist_bn))}}
    s["branches"]["total"] = sum(lay.kinds.values())
    if lay.hot is not None:
        s["hot"] = lay.hot
    if lay.rules.HAS_ERRATUM:
        dense = lay.dense_windows()
        w = layout_x86.ERRATUM_WINDOW
        s["erratum"] = {"units": lay.units, "hits": lay.hits,
                        "pct": round(100.0 * lay.hits / lay.units, 2) if lay.units else 0.0,
                        "windows": len(lay.hit_windows)}
        s["dense_windows"] = {"limit": layout_x86.DENSE_LIMIT, "count": len(dense),
                              "list": [{"addr": i * w, "insns": lay.dense[i]} for i in dense]}
    return s


def func_rows(lay, funcs):
    rows = []
    for f in lay.funcs:
        if not _match(f, funcs):
            continue
        r = {"name": f.name, "addr": f.addr, "m16": f.addr % 16, "m32": f.addr % 32,
             "m64": f.addr % 64, "size": f.size,
             "windows": _spanned(f.addr, f.end, lay.window),
             "lines": _spanned(f.addr, f.end, lay.line),
             "insns": f.insns, "br": f.br}
        if lay.rules.HAS_ERRATUM:
            r["jcc"], r["jccw"], r["dense"] = f.hits, f.jccw, f.dense
        else:
            r["brden"] = round(100.0 * f.br / f.insns, 1) if f.insns else 0.0
            r["maxbr"] = f.maxbr
        if lay.hot is not None:
            r["hot"] = round(f.hot, 2) if f.hot else None
        if len(f.names) > 1:
            r["aliases"] = [n for n in f.names if n != f.name]
        rows.append(r)
    return _by_hot(lay, rows, "addr")


def _spanned(start, end, size):
    """size-aligned blocks [start, end) touches."""
    return (end - 1) // size - start // size + 1 if end > start else 0


def _by_hot(lay, rows, key):
    if lay.hot is not None:
        rows.sort(key=lambda r: (-(r["hot"] or 0.0), r[key]))
    return rows


def loop_rows(lay, funcs):
    rows = []
    for f in lay.funcs:
        if not _match(f, funcs):
            continue
        for lp in f.loops:
            r = {k: v for k, v in lp.items() if not k.startswith("_") and k != "hot"}
            if lay.hot is not None:
                r["hot"] = round(lp["hot"], 2) if lp.get("hot") else None
            r["func"] = f.name
            rows.append(r)
    return _by_hot(lay, rows, "header")


def _loop_key(r):
    return (r["func"], r["key"])


def compare_rows(a, b, funcs):
    """Per-function and per-loop deltas, b minus a, for functions in both."""
    fb = {r["name"]: r for r in func_rows(b, funcs)}
    frows, only_a = [], 0
    for r in func_rows(a, funcs):
        o = fb.pop(r["name"], None)
        if o is None:
            only_a += 1
            continue
        c = {"name": r["name"], "addr_a": r["addr"], "addr_b": o["addr"],
             "m64_a": r["m64"], "m64_b": o["m64"], "dm64": (o["addr"] - r["addr"]) % 64,
             "size_a": r["size"], "size_b": o["size"], "dsize": o["size"] - r["size"],
             "windows_a": r["windows"], "windows_b": o["windows"],
             "lines_a": r["lines"], "lines_b": o["lines"]}
        for k in ("jcc", "jccw"):
            if k in r:
                c[k + "_a"], c[k + "_b"] = r[k], o[k]
        frows.append(c)
    lb = {_loop_key(r): r for r in loop_rows(b, funcs)}
    lrows, loops_only_a = [], 0
    for r in loop_rows(a, funcs):
        o = lb.pop(_loop_key(r), None)
        if o is None:
            loops_only_a += 1
            continue
        c = {"func": r["func"], "loop": r["key"],
             "hdr_m64_a": r["hdr_m64"], "hdr_m64_b": o["hdr_m64"],
             "windows_a": r["windows"], "windows_b": o["windows"],
             "dwindows": o["windows"] - r["windows"],
             "lines_a": r["lines"], "lines_b": o["lines"],
             "dlines": o["lines"] - r["lines"], "windows_min": r["windows_min"]}
        for k in ("jcc", "jccw", "brden", "maxbr"):
            if k in r:
                c[k + "_a"], c[k + "_b"] = r[k], o[k]
        lrows.append(c)
    stats = {"matched": len(frows), "only_a": only_a, "only_b": len(fb),
             "phase_changed": sum(c["m64_a"] != c["m64_b"] for c in frows),
             "size_changed": sum(c["dsize"] != 0 for c in frows),
             "windows_a": sum(c["windows_a"] for c in frows),
             "windows_b": sum(c["windows_b"] for c in frows),
             "lines_a": sum(c["lines_a"] for c in frows),
             "lines_b": sum(c["lines_b"] for c in frows),
             "loops_matched": len(lrows), "loops_only_a": loops_only_a,
             "loops_only_b": len(lb),
             "loop_windows_a": sum(r["windows_a"] for r in lrows),
             "loop_windows_b": sum(r["windows_b"] for r in lrows),
             "loop_lines_a": sum(r["lines_a"] for r in lrows),
             "loop_lines_b": sum(r["lines_b"] for r in lrows)}
    for k in ("jcc", "jccw"):
        if frows and k + "_a" in frows[0]:
            stats[k + "_a"] = sum(c[k + "_a"] for c in frows)
            stats[k + "_b"] = sum(c[k + "_b"] for c in frows)
        if lrows and k + "_a" in lrows[0]:
            stats["loop_%s_a" % k] = sum(c[k + "_a"] for c in lrows)
            stats["loop_%s_b" % k] = sum(c[k + "_b"] for c in lrows)
    return frows, lrows, stats


def seed_stats(rows):
    st = Counter(r["status"] for r in rows)
    return {"checked": len(rows), "failed": sum(not r["ok"] for r in rows),
            "unparsed": sum(not r["parsed"] for r in rows), "status": dict(st)}


# --- text --------------------------------------------------------------------

def _fmt(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "y" if v else "n"
    if isinstance(v, float):
        return "%.2f" % v
    if isinstance(v, list):
        return ",".join(v)
    return str(v)


def _hex(v):
    return "0x%x" % v if isinstance(v, int) else _fmt(v)


HEX_COLS = {"addr", "addr_a", "addr_b", "header", "entry", "parent"}


def table(rows, cols, out, last=None):
    """Columns right-aligned, then the free-width column last."""
    cells = [[(_hex(r.get(c)) if c in HEX_COLS else _fmt(r.get(c))) for c in cols]
             for r in rows]
    widths = [max([len(c)] + [len(x[i]) for x in cells]) for i, c in enumerate(cols)]
    out.write("  ".join(c.rjust(w) for c, w in zip(cols, widths))
              + ("  " + last if last else "") + "\n")
    for r, x in zip(rows, cells):
        out.write("  ".join(v.rjust(w) for v, w in zip(x, widths))
                  + ("  " + _fmt(r.get(last)) if last else "") + "\n")


def text_summary(s, out):
    w = out.write
    w("%s: %s %s (%s); windows of %d bytes, lines of %d bytes\n"
      % (s["binary"], s["format"], s["arch"], s["tool"], s["window"], s["line"]))
    for n, v in s["sections"].items():
        w("  section %-14s 0x%x-0x%x  %d bytes\n" % (n, v["start"], v["end"], v["bytes"]))
    b = s["bytes"]
    w("text bytes %d: code %d, filler %d, pad %d, gap %d, data %d\n"
      % (s["text_bytes"], b["code"], b["fill"], b["pad"], b["gap"], b["data"]))
    w("functions %d (Binate %d), instructions %d, code bytes outside any function %d\n"
      % (s["functions"], s["binate_functions"], s["instructions"], s["unnamed_code"]))
    if s["unparsed_names"]:
        w("Binate functions whose names the mangling grammar does not parse: %d\n"
          % len(s["unparsed_names"]))
        for n in s["unparsed_names"][:10]:
            w("  %s\n" % n)
    w("branches: " + "  ".join("%s %d" % kv for kv in s["branches"].items()) + "\n")
    if "hot" in s:
        h = s["hot"]
        w("perf overhead from %s (%s): %.2f%% credited to functions, %.2f%% ambiguous, "
          "%.2f%% unmatched, %.2f%% in other files\n"
          % (h["file"], h.get("event") or "the report's event", h["credited"], h["ambiguous"],
             h["unmatched"], h["other_dso"]))
    if "erratum" in s:
        e, d = s["erratum"], s["dense_windows"]
        w("JCC erratum (32-byte boundaries): %d of %d units hit (%.2f%%), %d windows affected\n"
          % (e["hits"], e["units"], e["pct"], e["windows"]))
        w("32-byte windows with more than %d instructions: %d\n" % (d["limit"], d["count"]))
        for x in sorted(d["list"], key=lambda x: -x["insns"])[:10]:
            w("  0x%x: %d instructions\n" % (x["addr"], x["insns"]))
    w("function start mod 64 (Binate first entries / all functions):\n")
    for p, (bn, al) in s["start_mod_64"].items():
        w("  %2d: %6d %6d\n" % (p, bn, al))


def emit(lay, other, seed_rows, funcs, args, out):
    s = summary(lay)
    frows = func_rows(lay, funcs)
    fcols = [c for c in ("addr", "m16", "m32", "m64", "size", "windows", "lines", "insns", "br",
                         "jcc", "jccw", "dense", "brden", "maxbr", "hot")
             if frows and c in frows[0]]
    lrows = loop_rows(lay, funcs) if args.loops else None
    lcols = (["header", "depth", "innermost", "blocks", "insns", "branches", "bytes",
              "ranges", "hdr_m32", "hdr_m64", "windows", "windows_min", "lines", "lines_min"]
             + (["jcc", "jccw"] if lay.rules.HAS_ERRATUM else ["brden", "maxbr"])
             + ["pad", "pad_ft"] + (["hot"] if lay.hot is not None else []) + ["key"])
    cmp = compare_rows(lay, other, funcs) if other is not None else None
    data = {"summary": s, "functions": frows}
    if lrows is not None:
        data["loops"] = lrows
    if cmp is not None:
        data["compare"] = {"binary": other.path, "stats": cmp[2], "functions": cmp[0],
                           "loops": cmp[1]}
    if seed_rows is not None:
        data["expect_seed"] = {"seed": args.expect_seed, "mode": args.mode or "phase",
                               "stats": seed_stats(seed_rows), "rows": seed_rows}
        if getattr(args, "probe", None) is not None:
            data["expect_seed"]["probe"] = {"sym": args.probe, "phase": args.probe_phase}
    if args.json:
        json.dump(data, out, indent=1)
        out.write("\n")
    elif args.tsv:
        _tsv(data, out)
    else:
        _text(data, fcols, lcols, out)


def _tsv_pairs(name, pairs, out):
    out.write("# %s\nkey\tvalue\n" % name)
    for k, v in pairs:
        out.write("%s\t%s\n" % (k, json.dumps(v) if isinstance(v, (dict, list)) else v))


def _tsv(data, out):
    _tsv_pairs("summary", data["summary"].items(), out)
    if "compare" in data:
        c = data["compare"]
        out.write("\n")
        _tsv_pairs("compare", [("binary", c["binary"])] + list(c["stats"].items()), out)
    if "expect_seed" in data:
        e = data["expect_seed"]
        out.write("\n")
        probe = [("probe", e["probe"])] if "probe" in e else []
        _tsv_pairs("expect-seed-stats", [("seed", e["seed"]), ("mode", e["mode"])] + probe
                   + list(e["stats"].items()), out)
    blocks = [("functions", data["functions"]), ("loops", data.get("loops")),
              ("compare-functions", data.get("compare", {}).get("functions")),
              ("compare-loops", data.get("compare", {}).get("loops")),
              ("expect-seed", data.get("expect_seed", {}).get("rows"))]
    for name, rows in blocks:
        if rows is None:
            continue
        out.write("\n# %s\n" % name)
        cols = list(dict.fromkeys(k for r in rows for k in r))
        out.write("\t".join(cols) + "\n")
        for r in rows:
            out.write("\t".join(_hex(r.get(c)) if c in HEX_COLS else _fmt(r.get(c))
                                for c in cols) + "\n")


def _text(data, fcols, lcols, out):
    text_summary(data["summary"], out)
    out.write("\nfunctions:\n")
    table(data["functions"], fcols, out, "name")
    if "loops" in data:
        out.write("\nloops (footprint = union of member blocks):\n")
        table(data["loops"], lcols, out, "func")
    if "compare" in data:
        c = data["compare"]
        st = c["stats"]
        out.write("\ncompare with %s (b - a):\n" % c["binary"])
        out.write("  " + ", ".join("%s %s" % kv for kv in st.items()) + "\n")
        if c["functions"]:
            table(c["functions"], [k for k in c["functions"][0] if k != "name"], out, "name")
        if c["loops"]:
            out.write("\nloop deltas:\n")
            table(c["loops"], [k for k in c["loops"][0] if k != "func"], out, "func")
    if "expect_seed" in data:
        e = data["expect_seed"]
        st = e["stats"]
        if not st["checked"]:
            out.write("\nexpect-seed %d (%s): FAILED, no function that receives placement "
                      "filler was found to check\n" % (e["seed"], e["mode"]))
            return
        out.write("\nexpect-seed %d (%s): %d functions checked, %d failed; %s\n"
                  % (e["seed"], e["mode"], st["checked"], st["failed"],
                     ", ".join("%s %d" % kv for kv in sorted(st["status"].items()))))
        if st["unparsed"]:
            out.write("  %d checked by symbol whose names the mangling grammar does not "
                      "parse\n" % st["unparsed"])
        if "probe" in e:
            _text_probe(e["probe"], e["rows"], out)
        bad = [r for r in e["rows"] if not r["ok"] or r["status"] == "inexact"]
        if bad:
            cols = ["entry", "phase", "want_phase", "dphase", "fill", "want_fill", "gap",
                    "first", "least_fill", "status"]
            table(bad[:SEED_TEXT_ROWS], cols, out, "name")
            if len(bad) > SEED_TEXT_ROWS:
                out.write("  ... %d more\n" % (len(bad) - SEED_TEXT_ROWS))


def _text_probe(probe, rows, out):
    """The probe line of the expect-seed text: where the probed function's
    first entry landed, its filler before and after it, and the whole filler
    run after it (its own trailing filler, then the next function's when a
    Binate function or unsymbolized code follows)."""
    r = next((r for r in rows if r["probe"]), None)
    if r is None:
        out.write("  probe %s: FAILED, no function that receives placement filler has this "
                  "symbol\n" % probe["sym"])
        return
    want = _fmt(r.get("want_after"))
    if r.get("after_code"):
        want += " and then the leading filler of the unsymbolized code after it"
    out.write("  probe %s: entry 0x%x at phase %d (want %d), filler %s before and %s after; "
              "the filler run after it %s bytes (want %s); %s\n"
              % (probe["sym"], r["entry"], r["phase"], probe["phase"], _fmt(r.get("pre")),
                 _fmt(r.get("post")), _fmt(r.get("after")), want, r["status"]))
