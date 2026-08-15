#!/usr/bin/env python3
"""Generate conformance/matrix/type-assert cells — the type-assertion / RTTI
matrix (spec §11.12 `iface.assert`, §14.10 type switch).  Part B of
explorations/plan-matrix-tests-generics-rtti.md.

The recent MAJOR/CRITICAL bug cluster lived in generics AND RTTI; the RTTI space
has ~99 POINT tests (998–1015, 1054/1055, 1074–1098, …) but no CROSS-AXIS matrix,
so a combination that only one point test happens to exercise is false-green
everywhere else.  This matrix crosses the axes the spec pins:

  * SOURCE — the interface-value operand: raw `*I` vs managed `@I` (satisfaction
    lookup + recovery), and the type-erased box `*any` vs `@any` (value recovery).
  * RECOVERY KIND × TARGET — `*T`/`@T` concrete pointer, `*J`/`@J` interface
    value (direct AND transitive-ancestor satisfaction), value `T` (scalar /
    struct / slice), gated by the §11.12 recovery-kind LEGALITY rules.
  * FORM — abort `x.(K T)`, comma-ok `v, ok := x.(K T)`, type switch.
  * OUTCOME — match · wrong-type miss · unset (null-vtable) miss.

The plan gated the type-switch cells on "Phase 6 IR-gen lowering" and the
cross-mode axis on "Slice 5 (VM RTTI)"; BOTH have since landed (gen_type_switch.bn,
vm/lower_typeinfo.bn), and every RTTI point test is green under the VM `int` and
native modes — so this whole matrix builds NOW across the default mode set, and
each cell's cross-mode agreement is enforced for free by run.sh running all modes.

Cell shapes (coordinate-addressed matrix/type-assert/<grid>/<cell>{.bn|.error}):
  * OK cells (.expected): one program packing abort-HIT + comma-ok-HIT +
    wrong-type-MISS + unset-MISS, each check emitting a value so a wrong recovery
    prints a distinct marker.
  * ABORT cells (.error): a failed abort-form assertion is a real §17.5 panic —
    the program must fail with `type assertion failed: <dyn> is not <T>`.
  * LEGALITY cells (.error): the §11.12 recovery-kind rules are COMPILE errors
    (`@T`/`@J` from a raw `*I`; value-recovery of an interface).
  * BALANCE cells (.expected): a mortal managed observable recovered via `@T`/`@J`
    (ownership transfer) or a value struct-with-managed-field returns to baseline
    refcount after the recovered value drops — no leak, no double-free.

Run: python3 conformance/gen-type-assert-matrix.py [--check].
"""

import os
import sys

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "matrix", "type-assert")

# --- shared decl blocks -----------------------------------------------------
# Dog implements Animal + Named (not Flyer); Cat implements Animal only.  So:
# a Dog-behind-*Animal HITs *Dog / *Named and MISSES *Flyer; a Cat-behind-*Animal
# MISSES *Dog (wrong concrete) and *Named (unsatisfied interface).  name() offsets
# by +100 so a recovered value is distinguishable from sound().
IFACE_DECLS = """interface Animal {
	sound() int
}

interface Named {
	name() int
}

interface Flyer {
	fly() int
}

type Dog struct {
	x int
}

func (d *Dog) sound() int {
	return d.x
}

func (d *Dog) name() int {
	return d.x + 100
}

type Cat struct {
	y int
}

func (c *Cat) sound() int {
	return c.y
}

impl *Dog : Animal
impl *Dog : Named
impl *Cat : Animal"""

# RC : Reader, Closer — a *Res behind *RC HITs its transitive ancestors *Reader /
# *Closer as well as *RC itself (the impl registry emits a satentry per ancestor).
# Writer is UNRELATED (Res does not implement it) — the wrong-type / abort MISS.
ANCESTOR_DECLS = """interface Reader {
	rd() int
}

interface Closer {
	cl() int
}

interface Writer {
	wr() int
}

interface RC : Reader, Closer {
}

type Res struct {
	x int
}

func (r *Res) rd() int {
	return r.x
}

func (r *Res) cl() int {
	return r.x + 1
}

impl *Res : RC"""


# --- interface-source assertion cells --------------------------------------
# ptr(k) spells the recovery-kind prefix: "*" (raw / borrow) or "@" (managed /
# retain).  A raw source uses value-type locals + `&`; a managed source uses
# make() + managed locals.
def iface_ok(src, rec, target, miss_target, hit_call, miss_val):
    # src: "raw" (*I) or "mgd" (@I).  rec: "*" or "@".  target/miss_target: type
    # names for the HIT and the unsatisfied MISS.  hit_call: method call on the
    # recovered value (e.g. ".name()").  miss_val: the sentinel a wrong-type /
    # unset comma-ok prints.
    if src == "raw":
        setup = ["var d Dog", "d.x = 5", "var a *Animal = &d"]
        cat = ["var c Cat", "c.y = 9", "var ac *Animal = &c"]
        unset = "var ua *Animal"
        p = "*"
    else:
        setup = ["var d @Dog = make(Dog)", "d.x = 5", "var a @Animal = d"]
        cat = ["var c @Cat = make(Cat)", "c.y = 9", "var ac @Animal = c"]
        unset = "var ua @Animal"
        p = "@"
    body = setup + [
        # abort-form HIT
        f"var h1 {p}{target} = a.({rec}{target})",
        f"testing.Println(h1{hit_call})",
        # comma-ok HIT
        f"h2, ok := a.({rec}{target})",
        f"if ok {{ testing.Println(h2{hit_call}) }} else {{ testing.Println(-1) }}",
    ] + cat + [
        # comma-ok wrong-type MISS: the Cat behind ac does not satisfy the target.
        f"_, ok2 := ac.({rec}{miss_target})",
        f"if ok2 {{ testing.Println(1000) }} else {{ testing.Println({miss_val}) }}",
        # comma-ok unset MISS: null-vtable source, no abort, no stray release.
        unset,
        f"ub, uok := ua.({rec}{target})",
        f"if uok {{ testing.Println(ub{hit_call}) }} else {{ testing.Println(1) }}",
    ]
    return body


def iface_abort(src, rec, target):
    # A Cat behind the *Animal / @Animal source fails the target assertion → the
    # abort form panics (§17.5).
    if src == "raw":
        setup = ["var c Cat", "c.y = 9", "var a *Animal = &c"]
        p = "*"
    else:
        setup = ["var c @Cat = make(Cat)", "c.y = 9", "var a @Animal = c"]
        p = "@"
    # The method call after the aborting assertion is never reached at run time,
    # but must still typecheck — name() exists on both *Dog and *Named.
    return setup + [f"var b {p}{target} = a.({rec}{target})", "testing.Println(b.name())"]


def ancestor_ok(src, rec):
    if src == "raw":
        setup = ["var t Res", "t.x = 10", "var rc *RC = &t"]
        unset = "var urc *RC"
        p = "*"
    else:
        setup = ["var t @Res = make(Res)", "t.x = 10", "var rc @RC = t"]
        unset = "var urc @RC"
        p = "@"
    return setup + [
        # transitive-ancestor + self HITs.
        f"var r {p}Reader = rc.({rec}Reader)",
        "testing.Println(r.rd())",
        f"cl, ok := rc.({rec}Closer)",
        "if ok { testing.Println(cl.cl()) } else { testing.Println(-1) }",
        f"var rc2 {p}RC = rc.({rec}RC)",
        "testing.Println(rc2.rd())",
        # wrong-type comma-ok MISS: Res does not implement the unrelated Writer.
        f"_, ok2 := rc.({rec}Writer)",
        "if ok2 { testing.Println(1000) } else { testing.Println(0) }",
        # unset MISS: null-vtable RC source, no abort, no stray release.
        unset,
        f"uw, uok := urc.({rec}Reader)",
        "if uok { testing.Println(uw.rd()) } else { testing.Println(1) }",
    ]


def ancestor_abort(src, rec):
    # Res (behind *RC / @RC) does not implement the unrelated Writer → the abort
    # form panics.  An interface TARGET names the target by its bare interface.
    if src == "raw":
        setup = ["var t Res", "t.x = 10", "var rc *RC = &t"]
        p = "*"
    else:
        setup = ["var t @Res = make(Res)", "t.x = 10", "var rc @RC = t"]
        p = "@"
    return setup + [f"var w {p}Writer = rc.({rec}Writer)", "testing.Println(w.wr())"]


# --- any-source value-recovery cells ---------------------------------------
def any_scalar(src):
    # src: "raw" (*any via &) or "mgd" (@any via box()).  int recovered by value in
    # all three forms + a wrong-type comma-ok miss.
    if src == "raw":
        mk = ["var n int = 42", "var a *any = &n"]
    else:
        mk = ["var n int = 42", "var a @any = box(n)"]
    return mk + [
        "var e int = a.(int)",
        'if e == 42 { testing.Println(1) } else { testing.Println(-1) }',
        "v, ok := a.(int)",
        'if ok && v == 42 { testing.Println(2) } else { testing.Println(-2) }',
        "_, ok2 := a.(bool)",
        'if ok2 { testing.Println(-3) } else { testing.Println(3) }',
        "switch x := a.(type) {",
        "case int:",
        '\tif x == 42 { testing.Println(4) } else { testing.Println(-4) }',
        "default:",
        "\ttesting.Println(-4)",
        "}",
    ]


# holdSlice recovers @[]int from the raw *any and, WHILE the recovered value is
# held, observes that the backing gained exactly one reference (before+1); the
# local drops at return, so the caller then sees the count back at `before`.  This
# is what makes the RefInc-acquire OBSERVABLE — a value-only check would pass even
# if recovery borrowed (no acquire), the miscompile iface.assert.slice guards.
HOLD_SLICE = '''func holdSlice(a *any, po *uint8, before int) int {
	var r @[]int = a.(@[]int)
	testing.Println(cast(int, rt.Refcount(po) == before + 1))
	return r[0]
}'''


def any_slice_raw():
    # §11.12 iface.assert.slice: a managed-slice `@[]int` recovers from a RAW
    # `*any`, RefInc-acquiring the still-live backing — a NEW reference (the raw
    # box owns none).  Relative refcount form: [held == before+1, value, dropped
    # == before] → [1, 42, 1].  pn[2] is word 2 (backing ptr) of the 4-word header.
    return [
        "var s @[]int = make_slice(int, 3)",
        "s[0] = 42",
        "var pn *int = bit_cast(*int, &s)",
        "var po *uint8 = bit_cast(*uint8, pn[2])",
        "var a *any = &s",
        "var before int = rt.Refcount(po)",
        "testing.Println(holdSlice(a, po, before))",
        "testing.Println(cast(int, rt.Refcount(po) == before))",
    ]


# --- balance cells ----------------------------------------------------------
# A helper recovers a managed value, uses it, and drops it at its own return; the
# observed box's refcount must return to baseline.  Relative form → [<value>, 0].
CONCRETE_BALANCE = '''func retainRelease(a @Animal) int {
	var d @Dog = a.(@Dog)
	return d.name()
}'''

IFACE_BALANCE = '''func retainReleaseNamed(a @Animal) int {
	var n @Named = a.(@Named)
	return n.name()
}'''


def balance_body(helper_call):
    return [
        "var d @Dog = make(Dog)",
        "d.x = 7",
        "var a @Animal = d",
        "var before int = rt.Refcount(bit_cast(*uint8, d))",
        f"testing.Println({helper_call})",
        "if before == rt.Refcount(bit_cast(*uint8, d)) { testing.Println(0) } else { testing.Println(1) }",
    ]


# A value struct with a MANAGED field recovered by value (switch / comma-ok / expr,
# each in a 100-iteration loop) must return the field backing's refcount to
# baseline — a leak grows it, a double-free drops it below (mirror 1093).
STRUCT_BALANCE_DECLS = '''type Named struct {
	name @[]char
}

// readBackingRC reads a managed-slice field's backing refcount from word 2 of its
// 4-word header (per conformance/130).
func readBackingRC(hdr *int) int {
	var backingPtr *uint8 = bit_cast(*uint8, hdr[2])
	if backingPtr == nil {
		return 0
	}
	return rt.Refcount(backingPtr)
}

func loopSwitch(v *any) {
	for i := 0; i < 100; i++ {
		switch n := v.(type) {
		case Named:
			_ = len(n.name)
		default:
		}
	}
}

func loopCommaOk(v *any) {
	for i := 0; i < 100; i++ {
		n, ok := v.(Named)
		if ok {
			_ = len(n.name)
		}
	}
}

func loopExpr(v *any) {
	for i := 0; i < 100; i++ {
		var n Named = v.(Named)
		_ = len(n.name)
	}
}'''

STRUCT_BALANCE_BODY = [
    "var nm Named",
    "nm.name = make_slice(char, 5)",
    "var pn *int = bit_cast(*int, &nm.name)",
    "var before int = readBackingRC(pn)",
    "var v *any = &nm",
    "loopSwitch(v)",
    "if before == readBackingRC(pn) { testing.Println(0) } else { testing.Println(1) }",
    "loopCommaOk(v)",
    "if before == readBackingRC(pn) { testing.Println(0) } else { testing.Println(1) }",
    "loopExpr(v)",
    "if before == readBackingRC(pn) { testing.Println(0) } else { testing.Println(1) }",
]


# --- legality (compile-error) cells -----------------------------------------
# §11.12 recovery-kind rules, enforced by the CHECKER (compile errors).
LEGALITY = [
    dict(rel="legality/mgd-concrete-from-raw",
         err="cannot recover @T from a raw interface value \\*I",
         decls=IFACE_DECLS,
         body=["var d Dog", "d.x = 5", "var a *Animal = &d",
               "var b @Dog = a.(@Dog)", "testing.Println(b.name())"]),
    dict(rel="legality/mgd-iface-from-raw",
         err="cannot recover @T from a raw interface value \\*I",
         decls=IFACE_DECLS,
         body=["var d Dog", "d.x = 5", "var a *Animal = &d",
               "var n @Named = a.(@Named)", "testing.Println(n.name())"]),
    dict(rel="legality/value-of-interface",
         err="value-recovery type assertion is only supported for scalar",
         decls=IFACE_DECLS,
         body=["var d Dog", "d.x = 5", "var a *Animal = &d",
               "var n Named = a.(Named)", "testing.Println(n.name())"]),
]


# --- assembly ---------------------------------------------------------------
INV = {
    "iface": "A concrete/interface type assertion off an interface-value operand HITs its dynamic type (and transitive ancestors), MISSES a wrong concrete type or unsatisfied interface (comma-ok → ok=false, no abort; unset source → miss, no stray release), across every mode.",
    "abort": "A failed abort-form `x.(K T)` is a real §17.5 panic `type assertion failed: <dyn> is not <T>` — not a silent nil.",
    "any": "A type-erased `*any`/`@any` box recovers a scalar BY VALUE in the expr / comma-ok / switch forms (HIT loads the value; wrong-type comma-ok → ok=false), across every mode.",
    "slice": "A managed-slice `@[]T` recovers from a RAW `*any` box (§11.12 iface.assert.slice): recovery RefInc-acquires the still-live backing — a NEW reference (the raw box owns none), OBSERVED via the relative form (held == before+1, dropped == before) so a borrow-miscompile is caught.",
    "balance": "A managed value recovered via `@T`/`@J` (ownership transfer) or a value struct-with-managed-field returns the observed box to baseline refcount after the recovered value drops — no leak, no double-free.",
    "legality": "The §11.12 recovery-kind rules are COMPILE errors: `@T`/`@J` needs a managed `@I` source (a raw `*I` has no reference to share); an interface recovers via `*J`/`@J`, never value.",
}

CELLS = []

# interface-source: raw/mgd × concrete/iface/ancestor, ok + abort.
for src in ("raw", "mgd"):
    rec = "*" if src == "raw" else "@"
    # concrete *T / @T
    CELLS.append(dict(rel=f"iface/{src}-concrete/ok", inv=INV["iface"], decls=IFACE_DECLS,
                      body=iface_ok(src, rec, "Dog", "Dog", ".name()", 0),
                      exp=[105, 105, 0, 1]))
    CELLS.append(dict(rel=f"iface/{src}-concrete/abort", inv=INV["abort"], decls=IFACE_DECLS,
                      body=iface_abort(src, rec, "Dog"),
                      err="type assertion failed: main.Cat is not main.Dog"))
    # interface *J / @J (direct satisfaction; MISS via unsatisfied Flyer)
    CELLS.append(dict(rel=f"iface/{src}-iface/ok", inv=INV["iface"], decls=IFACE_DECLS,
                      body=iface_ok(src, rec, "Named", "Named", ".name()", 0),
                      exp=[105, 105, 0, 1]))
    # An interface-TARGET miss names the target by its bare interface name
    # (`is not Named`), not a package-qualified concrete name (`is not main.Dog`).
    CELLS.append(dict(rel=f"iface/{src}-iface/abort", inv=INV["abort"], decls=IFACE_DECLS,
                      body=iface_abort(src, rec, "Named"),
                      err="type assertion failed: main.Cat is not Named"))
    # transitive-ancestor *J / @J (HITs + wrong-type / unset MISS + abort)
    CELLS.append(dict(rel=f"iface/{src}-ancestor/ok", inv=INV["iface"], decls=ANCESTOR_DECLS,
                      body=ancestor_ok(src, rec), exp=[10, 11, 10, 0, 1]))
    CELLS.append(dict(rel=f"iface/{src}-ancestor/abort", inv=INV["abort"], decls=ANCESTOR_DECLS,
                      body=ancestor_abort(src, rec),
                      err="type assertion failed: main.Res is not Writer"))

# any-source value recovery.
CELLS.append(dict(rel="any/raw-scalar/recover", inv=INV["any"], decls="",
                  body=any_scalar("raw"), exp=[1, 2, 3, 4]))
CELLS.append(dict(rel="any/mgd-scalar/recover", inv=INV["any"], decls="",
                  body=any_scalar("mgd"), exp=[1, 2, 3, 4]))
CELLS.append(dict(rel="any/raw-slice/recover", inv=INV["slice"], decls=HOLD_SLICE,
                  body=any_slice_raw(), exp=[1, 42, 1], rt=True))

# balance cells.  The @T / @J recovery helpers reference the Animal/Named/Dog decls.
CELLS.append(dict(rel="balance/concrete", inv=INV["balance"], decls=IFACE_DECLS + "\n\n" + CONCRETE_BALANCE,
                  body=balance_body("retainRelease(a)"), exp=[107, 0], rt=True))
CELLS.append(dict(rel="balance/iface", inv=INV["balance"], decls=IFACE_DECLS + "\n\n" + IFACE_BALANCE,
                  body=balance_body("retainReleaseNamed(a)"), exp=[107, 0], rt=True))
CELLS.append(dict(rel="balance/struct-value", inv=INV["balance"], decls=STRUCT_BALANCE_DECLS,
                  body=STRUCT_BALANCE_BODY, exp=[0, 0, 0], rt=True))

# legality compile-error cells.
for lc in LEGALITY:
    CELLS.append(dict(rel=lc["rel"], inv=INV["legality"], decls=lc["decls"],
                      body=lc["body"], err=lc["err"]))


HEADER = '''package "main"
import "pkg/builtins/testing"

// GENERATED by conformance/gen-type-assert-matrix.py — do not edit by hand.
// type-assert matrix cell — {desc}.
// {inv}
// See ../../README.md.
'''


def render(c):
    out = HEADER.format(desc=c["rel"], inv=c["inv"])
    # balance / struct cells observe a refcount → need pkg/builtins/rt.
    needs_rt = c.get("rt") or "rt.Refcount" in "".join(c["body"]) or "rt.Refcount" in c["decls"]
    if needs_rt:
        out += 'import "pkg/builtins/rt"\n'
    out += "\n"
    if c["decls"]:
        out += c["decls"] + "\n\n"
    # a helper decl (balance) already carries its own body; the driver goes in main.
    out += "func main() {\n"
    for ln in c["body"]:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def _write(path, content, changed, check):
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if old != content:
        changed.append(os.path.relpath(path, os.path.dirname(DIR)))
        if not check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(content)


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    for c in CELLS:
        base = os.path.join(DIR, c["rel"])
        _write(base + ".bn", render(c), changed, check)
        if "err" in c:
            _write(base + ".error", c["err"] + "\n", changed, check)
        else:
            _write(base + ".expected", "".join(str(x) + "\n" for x in c["exp"]), changed, check)
    if check:
        if changed:
            print("type-assert matrix out of date (run conformance/gen-type-assert-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("type-assert matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{len(CELLS)} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
