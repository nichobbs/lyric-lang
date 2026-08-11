//! bare_func_ref_self_test.l — dual-target regression test for #5362/#5366
//! (MSIL) and their JVM counterpart, #6393.
//!
//! All three issues are the same subsystem: how each self-hosted backend
//! materializes and types a function-typed VALUE outside the strongly-typed-
//! lambda happy path (the closure-class ABI, docs/52/53, Epic #1877/D113).
//!
//!   • #5362 (MSIL) — a bare top-level named function used directly as a
//!     `(A,...) -> R`-typed value (`apply(double, 21)`, no wrapping closure
//!     literal) crashed at runtime with `NullReferenceException`: the
//!     `lowerExprMsil` EPath value-read fallback had no MethodDef whose
//!     PHYSICAL signature matched the uniform boxed `Func<object,...,object>`
//!     ABI to `ldftn` against.  Fixed by `synthesizeBareFuncRefThunksMsil`
//!     (`msil/codegen.l`), a pre-codegen AST pass that synthesizes one small
//!     forwarding thunk per distinct top-level function referenced bare
//!     anywhere in the file, shaped exactly like the equivalent hand-written
//!     closure literal (`{ x -> double(x) }`) so it flows through the
//!     existing, already-correct lambda-lifting/closure codegen unchanged.
//!   • #5366 (MSIL) — a function/closure value bound WITHOUT a literal
//!     `(T) -> U` type annotation at its declaration site silently stayed
//!     boxed, corrupting arithmetic performed on its call result with no
//!     exception — including the alias-annotated case (`val f: Handler =
//!     ...` where `alias Handler = (Int) -> Int`) and the fully-inferred
//!     case (`val f = adder(5)` where `adder`'s own declared return type is
//!     the alias `Handler`, not a literal `(Int) -> Int`).  Fixed by
//!     `resolveFuncTypeExprMsil` (`msil/codegen.l`), which follows a
//!     `TRef`-typed annotation/return through `cctx.aliasTargets` down to
//!     its underlying `TFunction` shape at every `funcValRetTypes`/
//!     `fieldFuncRetTypes` registration site (local bindings, params, record
//!     fields, and the same-package-call return-type inference `#5774`
//!     added) — exactly like a literal `(Int) -> Int` annotation already
//!     registered.
//!   • #6393 (JVM) — the same two gaps, JVM-shaped: (1) a bare top-level
//!     function reference had NO codegen path at all (a compile-time panic,
//!     "reference 'name' resolves to no local, ..."), fixed by synthesizing
//!     the equivalent forwarding closure INLINE at the point of use
//!     (`lowerBareFuncRefValue`, `jvm/codegen/02_exprs.l`) — no separate
//!     pre-codegen pass is needed on this target, since a JVM closure is a
//!     synthesised inner class built entirely at the point of use, with no
//!     MethodDef pre-scan to stabilise ahead of codegen; (2) an alias-typed
//!     function annotation (param/return/record-field/local) loaded the
//!     alias name itself as a nonexistent class
//!     (`NoClassDefFoundError: <Pkg>/<AliasName>`), fixed by the same
//!     alias-chain-to-`TFunction` resolution MSIL's `resolveFuncTypeExprMsil`
//!     performs, threaded through `FuncCtx.aliasTargets` to every erasure
//!     site (`jvm/codegen/06_items.l`, `05_stmts.l`).  The eligibility
//!     predicate (#6393's gap 1) and the alias-chain resolver (#6393's gap 2)
//!     are shared between both backends via `Lyric.BareFuncRef`
//!     (`lyric-compiler/lyric/bare_func_ref.l`); the codegen STRATEGY that
//!     consumes them stays backend-specific (a pre-codegen `IFunc`-synthesis
//!     pass on MSIL, an inline `lowerLambda` call on JVM) because the two
//!     targets' closure-construction models are structurally different.
//!
//! Run via native `lyric test` on both targets (wired in `ci.yml`):
//!
//!   lyric test --target dotnet lyric-compiler/lyric/bare_func_ref_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/bare_func_ref_self_test.l
@test_module
package Lyric.BareFuncRefSelfTest

import Std.Core
import Std.Testing

alias Handler = (Int) -> Int

func double(x: in Int): Int {
  x * 2
}

func triple(x: in Int): Int {
  x * 3
}

func apply(h: in Handler, x: in Int): Int {
  h(x)
}

// #5362 exact repro shape: a bare top-level function name passed directly
// where a function-typed value is expected.
test "bare top-level function passed as a call argument, invoked inside the callee" {
  assertEqualInt(apply(double, 21), 42, "apply(double, 21) == double(21) == 42")
}

// A different bare function, same call site shape — guards against the
// synthesized thunk being keyed wrong and forwarding to the wrong function.
test "a second bare top-level function passed as a call argument" {
  assertEqualInt(apply(triple, 7), 21, "apply(triple, 7) == triple(7) == 21")
}

// #5362's own "named function stored then called through a variable" shape.
func storeThenCall(): Int {
  val f = double
  f(20)
}

test "named function stored in a local, then invoked through the variable" {
  assertEqualInt(storeThenCall(), 40, "val f = double; f(20) == 40")
}

// #5362's record-field variant: a bare function stored as a record field,
// read back into a local, then invoked.
record Holder {
  h: Handler
}

func storeInRecordThenCall(): Int {
  val holder = Holder(h = double)
  val f = holder.h
  f(21)
}

test "bare top-level function stored in a record field, then invoked" {
  assertEqualInt(storeInRecordThenCall(), 42, "Holder(h = double).h invoked with 21 == 42")
}

// #5366: HOF returning a closure through a type ALIAS (not a literal
// `(Int) -> Int`), bound with NO annotation at all — the exact original repro.
func adder(n: in Int): Handler {
  { x: Int -> x + n }
}

func inferredAliasReturnArithmetic(): Int {
  val f = adder(5)
  val r1 = f(10)
  r1 + 1
}

test "unannotated local bound from an alias-returning HOF call, arithmetic on result (#5366)" {
  assertEqualInt(inferredAliasReturnArithmetic(), 16, "adder(5)(10) + 1 == 16")
}

// #5366: same shape, but with an explicit ALIAS-typed annotation (`: Handler`)
// rather than a literal `(Int) -> Int` annotation — also previously un-tracked.
func aliasAnnotatedArithmetic(): Int {
  val f: Handler = adder(5)
  val r1 = f(10)
  r1 + 1
}

test "alias-typed annotated local bound from an alias-returning HOF call, arithmetic on result (#5366)" {
  assertEqualInt(aliasAnnotatedArithmetic(), 16, "adder(5)(10) + 1 == 16 (alias-annotated)")
}

// #5366 via an alias-typed PARAMETER (registerParamsMsil / the lambda-param
// registration site): arithmetic on the call result of an alias-typed
// function value received as a parameter, not just a local.
func applyAndAddOne(h: in Handler, x: in Int): Int {
  h(x) + 1
}

test "alias-typed function parameter, arithmetic on the call result (#5366)" {
  assertEqualInt(applyAndAddOne(double, 10), 21, "double(10) + 1 == 21 via alias-typed param")
}

// #6389 addendum: `collectBareFuncValueRefsExpr`'s `EMatch` case never walked
// `MatchArm.guard`, so a bare top-level function referenced ONLY inside a
// match guard never got a synthesized thunk — reproducing #5362's
// `NullReferenceException` at the guard's `EPath` value read.
func classifyByGuard(n: in Int): Int {
  match n {
    case x if apply(double, x) > 5 -> 42
    case _ -> 0
  }
}

test "bare top-level function referenced only inside a match guard (#6389 addendum)" {
  assertEqualInt(classifyByGuard(5), 42, "apply(double, 5) == 10 > 5, guard selects the first arm")
}

// #6389 addendum: `allReferencedNamesMsil`'s `IRecord` case never walked
// `RMField(field).dflt`, so a bare top-level function referenced ONLY as a
// record field's default value never got a synthesized thunk either.  Reads
// the defaulted field into a local before invoking (mirroring
// `storeInRecordThenCall` above) rather than chain-calling it directly
// (`holder.h(10)`) — that dot-call-chain shape hits a separate, pre-existing
// method-dispatch gap unrelated to this addendum's thunk-synthesis fix.
record GuardHolder {
  h: Handler = double
}

func callViaDefaultedField(): Int {
  val holder = GuardHolder()
  val f = holder.h
  f(10)
}

test "bare top-level function referenced only as a record field default (#6389 addendum)" {
  assertEqualInt(callViaDefaultedField(), 20, "GuardHolder().h defaults to double; double(10) == 20")
}

// #6406: a UNION case field typed via a function-type alias must resolve to
// the underlying TFunction before descriptor erasure, exactly like the record
// field twin above — pre-fix, `lowerUnion`/`collectFileCasesExtern`'s IUnion
// branch embedded the nonexistent alias class in the case-field descriptor
// (NoClassDefFoundError on --target jvm).
union Carrier6406 {
  case Wrapped(h: Handler)
  case Empty
}

test "union case field typed via a function-type alias round-trips (#6406)" {
  val c = Wrapped(h = double)
  match c {
    case Wrapped(h) -> assertEqualInt(h(21), 42, "alias-typed union payload invokes: double(21) == 42")
    case Empty -> assertTrue(false, "wrong arm")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// #6404: `typeExprToJvm`'s `TRef` fallback treats ANY unrecognized name as
// "user-defined type in the same package" — before this fix, that included
// NON-function alias targets (`alias Meters = Long`), not just the
// function-shaped ones #6393/#6406 above cover, and every alias reference in
// an instance-method-shaped signature (record method params/return here;
// `impl`-for-`interface` methods and `protected type` entries also hit the
// same class of bug, but both independently panicked/crashed on THIS
// SELF-HOSTED COMPILER even with a plain, non-aliased `Long` param — see
// docs/03-decision-log.md D-progress-748 — so they couldn't be exercised in a
// dual-target regression test here without failing for an unrelated,
// pre-existing reason; tracked in #6407/#6408.  `protected type` entries'
// crash (#6407, an unrelated `self`-param receiver-arity bug, NOT an alias
// bug) is now fixed — see D-progress-749 and the new §6 in
// `synthesized_method_self_test.l` — and the alias-typed-param-through-a-
// protected-entry case is covered below (`MeterTally`).  The `impl` HEADER positions
// (`target`/`iface` through an alias, #6414) are covered at the unit level
// in `type_alias_resolve_self_test.l` instead; runtime impl-block coverage
// (#6408, D-progress-750) is covered below (`MeterCalc6408`/`MeterAccum6408`)
// — an alias-typed param/return/self-field through an `impl`-for-`interface`
// method with an EXPLICIT `self` receiver, dispatched BOTH directly on the
// record value (the axis that actually crashed on MSIL pre-#6408-fix) and
// through the interface type (which was unaffected, both before and after).
//
// Fixed by `Lyric.TypeAliasResolve` (`lyric-compiler/lyric/
// type_alias_resolve.l`): a whole-file AST pre-pass, run once before any JVM
// codegen function sees the file, that resolves EVERY `alias X = ...`
// reference (not just function-shaped ones) to its underlying `TypeExpr` —
// see that module's doc comment for the full design.
alias Meters = Long

func addOneMeter(m: in Meters): Meters {
  m + 1i64
}

test "non-function alias as a top-level function's param AND return type (#6404)" {
  assertEqualLong(addOneMeter(41i64), 42i64, "addOneMeter(41) == 42 via non-function alias Meters")
}

func localAliasAnnotated(): Long {
  val d: Meters = 42i64
  d
}

// The last #6404-axis-2 position with no runtime coverage: an alias-typed
// param AND return routed through a `protected type` entry (canonical
// implicit-receiver spelling), unblocked by #6407's fix (D-progress-749).
protected type MeterTally {
  var total: Meters = 0i64
  entry addMeters(m: Meters): Meters {
    total = total + m
    total
  }
}

test "non-function alias as a protected-type entry's param and return type (#6404/#6407)" {
  val t = MeterTally()
  assertEqualLong(t.addMeters(30i64), 30i64, "first addMeters(30) == 30 via alias Meters")
  assertEqualLong(t.addMeters(12i64), 42i64, "second addMeters(12) accumulates to 42")
}

test "non-function alias as a local `val` annotation (#6404)" {
  assertEqualLong(localAliasAnnotated(), 42i64, "val d: Meters = 42 round-trips as a plain Long")
}

record Distance {
  d: Meters
}

func readAliasedField(): Long {
  val box = Distance(d = 9i64)
  box.d
}

test "non-function alias as a record field type (#6404)" {
  assertEqualLong(readAliasedField(), 9i64, "Distance(d = 9).d round-trips as a plain Long")
}

record Scaler {
  base: Meters

  func scaled(self: in Scaler, factor: Meters): Meters {
    self.base * factor
  }
}

test "non-function alias as a record instance method's param, return, AND self field (#6404)" {
  val s = Scaler(base = 10i64)
  assertEqualLong(s.scaled(3i64), 30i64, "Scaler(base = 10).scaled(3) == 30 via non-function alias")
}

record Applier {
  seed: Int

  func run(self: in Applier, f: Handler): Int {
    f(self.seed) + self.seed
  }
}

test "function-type alias as a record instance method's parameter (#6404)" {
  val a = Applier(seed = 4)
  assertEqualInt(a.run(double), 12, "Applier(seed = 4).run(double) == double(4) + 4 == 12")
}

// #6408: an `impl`-for-`interface` method with an alias-typed param/return
// AND an explicit `self` receiver (D037 `self: in Self` / `self: in
// <Target>`).  MSIL's `addPackageTokens` IImpl pre-pass registered the
// direct-record-dispatch key (`"<Target>/<method>"`, consulted when a call
// resolves against the record's OWN type rather than the interface) from the
// impl method's raw, unstripped param list, so the registered per-index
// parameter types disagreed with the real (self-stripped) emitted MethodDef
// — `InvalidProgramException` on the direct-dispatch axis only; interface-
// typed dispatch used a separately-registered, already-correctly-stripped
// key and was unaffected. See D-progress-750.
interface MeterCalc6408 {
  func addMeters(self: in Self, m: Meters): Meters
}

record MeterAccum6408 {
  base: Meters
}

impl MeterCalc6408 for MeterAccum6408 {
  func addMeters(self: in MeterAccum6408, m: Meters): Meters {
    self.base + m
  }
}

test "alias-typed impl method param/return/self-field, direct record dispatch (#6404/#6408)" {
  val a = MeterAccum6408(base = 10i64)
  assertEqualLong(a.addMeters(5i64), 15i64, "direct dispatch: 10 + 5 via alias Meters, explicit self")
}

test "alias-typed impl method param/return/self-field, interface-typed dispatch (#6404/#6408)" {
  val a: MeterCalc6408 = MeterAccum6408(base = 10i64)
  assertEqualLong(a.addMeters(5i64), 15i64, "interface dispatch: 10 + 5 via alias Meters, explicit self")
}

// #6410 review round: an alias used as a bare GENERIC-APPLICATION HEAD
// (`alias L6410 = List` then `L6410[Int]`) substitutes the head path when the
// alias bottoms out in a plain TRef; and an alias inside a CONTRACT clause
// resolves too (contract clauses lower into real runtime asserts in
// @runtime_checked modules, so they are JVM-compiled like any other code).
alias L6410 = List

func sum6410(xs: L6410[Int]): Int
  requires: xs.count >= 0
{
  var t = 0
  var i = 0
  while i < xs.count {
    t = t + xs[i]
    i = i + 1
  }
  t
}

test "alias as generic-application head and in a contract clause (#6410)" {
  val xs: L6410[Int] = newList()
  xs.add(20)
  xs.add(22)
  assertEqualInt(sum6410(xs), 42, "L6410[Int] head resolves; requires: compiles")
}

// #6412: a DISTINCT type whose underlying representation names an alias
// (`type Distance6412 = Meters6412`) must resolve the underlying before
// codegen — pre-fix, merely DECLARING this crashed `--target jvm` at build
// time with NoClassDefFoundError on the alias name (the distinct type's own
// name stays nominal; only its representation resolves).
alias Meters6412 = Long

type Distance6412 = Meters6412

test "distinct type over a non-function alias compiles on both targets (#6412)" {
  // The declaration above IS the regression: pre-fix the file failed to
  // build on jvm before any test ran.  Assert something trivial so the
  // case registers.
  assertTrue(true, "Distance6412 declaration lowered without crashing")
}

// #6417/#6423: an interface method whose receiver is spelled `self: in Self`
// (rather than `self: in <ConcreteTarget>`), implemented verbatim on a
// record, invoked through an interface-typed binding.  This file already
// runs dual-target in CI (unlike `impl_method_self_test.l`'s dotnet-only
// coverage of the same #6417 fix), so this case gives the Self-receiver
// impl shape automated JVM signal too.
interface Tagger6417 {
  func tag(self: in Self): Int
}

record Applier6417 {
  seed: Int
}

impl Tagger6417 for Applier6417 {
  func tag(self: in Self): Int {
    self.seed
  }
}

test "interface-typed binding dispatch on a Self-receiver impl (#6417, dual-target)" {
  val a: Tagger6417 = Applier6417(seed = 42)
  assertEqualInt(a.tag(), 42, "Self-receiver impl dispatches through interface-typed binding")
}

// #6426: a non-receiver `Self`-typed impl-method parameter (`other: in
// Self`) now resolves field READ and WRITE correctly on `--target jvm`, via
// a real `checkcast` emitted at method entry (`emitSelfParamChecksJvm`,
// `jvm/codegen/06_items.l`) — the JVM analog of MSIL's D-progress-753 fix
// (#6421), which was bookkeeping-only (sound on MSIL because the CLR JIT
// never verifies CIL type-safety at load time) and could not port as-is: the
// JVM classfile verifier IS a mandatory load-time gate, so the erased
// `Object`-descriptor parameter needs a REAL cast, not just internal
// static-type bookkeeping.  Two same-package records share the field name
// `base` (mirroring D-progress-751's own minimal repro and this file's own
// pre-existing `Scaler`/`MeterAccum6408` `base` fields above), so a
// wrong-type guess through the package-wide name-only fallback this fix
// bypasses would misresolve to the wrong record's field token.
record TwinA6426 {
  base: Int
}

record TwinB6426 {
  var base: Int
}

interface Combiner6426 {
  func combine(self: in Self, other: in Self): Int
}

impl Combiner6426 for TwinA6426 {
  func combine(self: in TwinA6426, other: in Self): Int {
    self.base + other.base
  }
}

interface Setter6426 {
  func put(self: in Self, other: in Self, v: Int): Int
}

impl Setter6426 for TwinB6426 {
  func put(self: in Self, other: in Self, v: Int): Int {
    other.base = v
    other.base
  }
}

test "non-receiver Self-typed param field READ, two same-package records sharing a field name (#6426, dual-target)" {
  val x = TwinA6426(base = 20)
  val y = TwinA6426(base = 22)
  assertEqualInt(x.combine(y), 42, "self.base + other.base resolves TwinA6426's own field, not any other record's")
}

test "non-receiver Self-typed param field WRITE, reference semantics observed by the caller (#6426, dual-target)" {
  val p = TwinB6426(base = 1)
  val q = TwinB6426(base = 2)
  assertEqualInt(p.put(q, 42), 42, "the store lands and reads back through the checkcast-narrowed param")
  assertEqualInt(q.base, 42, "the caller observes the mutation (reference semantics), not a silent no-op")
}

// The lowerRecordMethod call site of emitSelfParamChecksJvm (#6432 review):
// a method declared directly in the record BODY (D037, no impl block) with a
// non-receiver `Self` param exercises the second of the two wiring points
// (lowerImplMethod covers the impl cases above).  The interface-DEFAULT-
// method path lowerImplMethod also serves is NOT pinned here: default-method
// inheritance without an override crashes at runtime on both targets today
// (pre-existing, #6433), so no checker-legal program can reach a Self param
// inside an inherited default body yet.
record Pair6432 {
  base: Int

  func plus(self: in Pair6432, other: in Self): Int {
    self.base + other.base
  }
}

test "non-receiver Self-typed param on a record BODY method, no impl block (#6432 review, dual-target)" {
  val a = Pair6432(base = 40)
  val b = Pair6432(base = 2)
  assertEqualInt(a.plus(b), 42, "lowerRecordMethod's Self-param checkcast wiring resolves the field correctly")
}

// #6434/#6435 (D-progress-757): `Self`-typed method RETURN call-site
// substitution on MSIL — the PARAM-position twin of #6426/#6432 just above,
// applied to the RETURN position instead. Before this fix MSIL had NO
// return-position `Self` handling at all: `typeExprToMsilCtx`'s
// `TSelf -> MObject` erasure was unconditional, and the erased type is what
// `registerMethodRetTy`/`registerMethodRetTyMsil` recorded, so a member
// access through a `dup(): Self` call result fell into the package-wide,
// field-NAME-only `fieldTokensByName` fallback (#6434,
// `System.InvalidCastException` when two same-package records share a field
// name — the RETURN-side analog of D-progress-753's PARAM-side bug) and a
// SECOND method call chained off the result had no class-directed dispatch
// entry at all (#6435, an unhandled runtime `unsupported method` exception,
// not even a diagnostic). Originally pinned JVM-only
// (`self_return_call_site_jvm_self_test.l`, #6431/#6437) because JVM's
// call-site-substitution mechanism (`narrowSelfCallResult`,
// `jvm/codegen/04_calls.l`) had no MSIL counterpart; ported here (and the
// JVM-only file deleted) now that `narrowSelfCallResultMsil`
// (`msil/codegen.l`) closes the same gap on this target, using a
// `methodRetIsSelf` side table (paralleling `methodRetTypes`) consulted at
// each of MSIL's two reachable instance-call-with-tracked-receiver dispatch
// sites (the explicit-receiver `MClass(cls)` branch of `lowerMethodCallMsil`,
// and the bare intra-impl sibling-call branch of `lowerGeneralStaticCall`) —
// MSIL needs no THIRD, holder-path-specific site the way JVM's
// `lowerVirtualCallWithHolders` did: an MSIL `out`/`inout` argument is
// handled INLINE in the same `MClass(cls)` dispatch block, not a separate
// function, so the `Tagged6435`/`dupTagged` case below already exercises the
// fixed path without any additional wiring. Unlike JVM's `checkcast`, no IL
// is emitted at these call sites at all — the CLR JIT does not enforce CIL
// type-safety verification at load time for ordinary trusted assemblies
// (D-progress-753), so narrowing the CODEGEN-INTERNAL tracked type to
// `MClass(cls)` is sufficient; a later field read through the narrowed
// receiver already emits its own `MCastclassByName` at the existing
// `case MClass(cls) ->` field-lowering arms.
record TwinC6434 {
  n: Int
}

record TwinD6434 {
  n: Int
}

interface Cloner6434 {
  func dup(self: in Self): Self
}

impl Cloner6434 for TwinC6434 {
  func dup(self: in Self): Self {
    TwinC6434(n = self.n + 1000)
  }
}

impl Cloner6434 for TwinD6434 {
  func dup(self: in Self): Self {
    TwinD6434(n = self.n + 1)
  }
}

test "direct call with a Self return type, val-bound (#6434/#6435, dual-target)" {
  val b = TwinD6434(n = 41)
  val b2 = b.dup()
  assertEqualInt(b2.n, 42, "val-bound b2.n resolves TwinD6434's own field via the narrowed call result")
}

test "Self-return call-site substitution, two same-package records sharing a field name (#6434, dual-target)" {
  val d = TwinD6434(n = 41)
  val d2 = d.dup()
  assertEqualInt(d2.n, 42, "d2.n resolves TwinD6434's own field, not TwinC6434's (guards against a name-only fallback)")
}

test "chained Self-returning calls narrow the receiver class at each call site (#6435, dual-target)" {
  val d = TwinD6434(n = 40)
  val d3 = d.dup().dup()
  assertEqualInt(
    d3.n,
    42,
    "each .dup() call re-narrows the result to TwinD6434 so the second call's field read resolves"
  )
}

// A single-record shape (no field-name collision) as an additional guard:
// the collision cases above already imply this passes, but pinning it
// separately documents the simplest possible repro alongside the harder one.
record Box6434 {
  n: Int
}

interface SimpleCloner6434 {
  func dup(self: in Self): Self
}

impl SimpleCloner6434 for Box6434 {
  func dup(self: in Self): Self {
    Box6434(n = self.n + 1)
  }
}

test "direct call with a Self return type, single record, no field-name collision (#6434, dual-target)" {
  val b = Box6434(n = 41)
  val b2 = b.dup()
  assertEqualInt(b2.n, 42, "single-record baseline: the narrowed call result resolves n correctly")
}

// A Self-returning method that ALSO carries an `inout` (holder) param — on
// JVM this pinned a THIRD, separately-wired dispatch path
// (`lowerVirtualCallWithHolders`, #6437); on MSIL the same `case MClass(cls)`
// dispatch block already handles `out`/`inout` args inline, so this case is
// a regression guard confirming that inline handling composes with the
// return-narrowing fix rather than a sign a second MSIL fix was needed.
record Tagged6435 {
  n: Int
}

interface TagCloner6435 {
  func dupTagged(self: in Self, tag: inout Int): Self
}

impl TagCloner6435 for Tagged6435 {
  func dupTagged(self: in Tagged6435, tag: inout Int): Self {
    tag = tag + 1
    Tagged6435(n = self.n + 1)
  }
}

test "Self return through the holder (inout-param) call path (#6435, dual-target)" {
  val b = Tagged6435(n = 41)
  var t = 7
  val b2 = b.dupTagged(t)
  assertEqualInt(b2.n, 42, "holder-path call result narrows to the receiver class and resolves n")
  assertEqualInt(t, 8, "the inout write-back still lands after the narrowing")
}

// The bare intra-impl sibling call (`lowerGeneralStaticCall`'s
// `ctx.selfClass` branch on MSIL, `#1722`'s dispatch site reused here):
// `dup()` without a `self.` prefix inside a sibling method of the SAME impl
// dispatches on the implicit receiver; the result narrows against the
// enclosing method's own class.
interface Duo6435 {
  func dup(self: in Self): Self
  func bumpViaSibling(self: in Self): Int
}

record Pair6435 {
  n: Int
}

impl Duo6435 for Pair6435 {
  func dup(self: in Pair6435): Self {
    Pair6435(n = self.n + 1)
  }
  func bumpViaSibling(self: in Pair6435): Int {
    val d = dup()
    d.n
  }
}

test "Self return through a bare sibling call inside the same impl (#6435, dual-target)" {
  val p = Pair6435(n = 41)
  assertEqualInt(p.bumpViaSibling(), 42, "bare dup() narrows against the enclosing impl's own class")
}
