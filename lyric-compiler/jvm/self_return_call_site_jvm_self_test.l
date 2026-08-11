//! self_return_call_site_jvm_self_test.l — executable regression test for
//! `Self`-typed impl/record-method RETURN call-site substitution on the
//! self-hosted JVM backend (#6431).
//!
//! Before this fix, a method declared `func dup(self: in Self): Self`
//! (docs/01's `Cloneable`-style shape) always erased its return to
//! `java/lang/Object` at every call site — the JVM analog of `Self` in a
//! non-receiver PARAM position (#6421/#6426, D-progress-753/755), but for
//! the RETURN position, which #6426's own investigation explicitly scoped
//! out (D-progress-755 "Scope boundary" section) and #6431 tracked as a
//! follow-up.  A subsequent member access through the call result
//! (`b.dup().n`) hit the erased-receiver refusal (`error[J007]`,
//! `02_exprs.l`).
//!
//! The fix (`narrowSelfCallResult`, `jvm/codegen/04_calls.l`) emits a
//! `checkcast` to the receiver's own known concrete class right after the
//! `invokevirtual`, narrowing the tracked call-result type from the erased
//! `Object` to that class, whenever the callee's registered sig carries
//! `retIsSelf` (set for an interface/impl/record method whose declared
//! return is bare `Self` — `registerInstanceSigErased`, `06_items.l`) AND
//! the dispatch is non-interface (`not sig.isIface`).  Sound because
//! `checkImplConformance` guarantees a `Self`-declared return yields exactly
//! the receiver's own concrete type.  An interface-typed receiver
//! (`Cloner`-typed local calling `.dup()`) is unreachable here: the type
//! checker already types such a call's result as the INTERFACE ITSELF
//! (T0113) before codegen ever sees it, so it stays correctly erased.
//!
//! JVM-only (not dual-target): this module is deliberately NOT added to
//! `bare_func_ref_self_test.l` (dual-target, #6426's param-fix home).
//! Investigating this fix found MSIL's PRE-EXISTING Self-return handling is
//! not actually a call-site substitution mechanism at all — despite
//! `impl_method_self_test.l`'s existing (single-record, non-chained)
//! Self-return cases passing, a two-record field-name-collision repro shows
//! MSIL's return-position field read falls through the same package-wide,
//! field-NAME-only `fieldTokensByName` fallback D-progress-753 fixed for the
//! PARAM case — and throws `System.InvalidCastException` when two
//! same-package records share a field name. A chained call
//! (`b.dup().dup()`) fails even WITHOUT a field-name collision: MSIL's
//! `methodRetTypes` registration erases a `Self`-declared return's tracked
//! type to `MObject` unconditionally (`typeExprToMsilCtx`'s `TSelf -> MObject`
//! arm, `msil/codegen.l:6233`, with no return-position analog of
//! `registerParamsMsil`'s Self-narrowing), so a SECOND `.dup()` call
//! dispatches against an untracked `MObject` receiver and fails at RUNTIME
//! with an unhandled `System.Exception: unsupported method 'dup' on the
//! receiver type at this call site` — not even a diagnostic. Both are real,
//! previously-undocumented MSIL gaps (out of THIS task's JVM-only scope);
//! see docs/03-decision-log.md D-progress-756 for the full writeup and
//! before/after repro transcripts. Placing these cases here (rather than in
//! `bare_func_ref_self_test.l`) keeps that dual-target file green on BOTH
//! targets while still pinning the JVM fix in CI.
//!
//! Run in CI via the native `lyric test --target jvm`: the runnable program
//! synthesised from the `test` blocks is compiled IN-PROCESS through the
//! self-hosted `Jvm.Bridge` (`compileToJarBundled` bundles the user package
//! plus its transitive stdlib-import closure into one runnable JAR), run
//! under `java`, and every embedded assertion is checked. Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/self_return_call_site_jvm_self_test.l
@test_module
package Lyric.SelfReturnCallSiteJvmSelfTest

import Std.Core
import Std.Testing

// Two same-package records share the field name `n` (mirroring
// D-progress-751's own minimal collision repro and #6426's
// `bare_func_ref_self_test.l` param cases) so a val-bound read through the
// checkcast-narrowed call result cannot silently resolve the wrong record's
// field via a package-wide name-only fallback — pinning that this fix is
// genuinely call-site-class-keyed, not a disguised repeat of MSIL's fragile
// mechanism.
record TwinC6431 {
  n: Int
}

record TwinD6431 {
  n: Int
}

interface Cloner6431 {
  func dup(self: in Self): Self
}

impl Cloner6431 for TwinC6431 {
  func dup(self: in Self): Self {
    TwinC6431(n = self.n + 1000)
  }
}

impl Cloner6431 for TwinD6431 {
  func dup(self: in Self): Self {
    TwinD6431(n = self.n + 1)
  }
}

test "direct call with a Self return type, val-bound (#6431)" {
  val b = TwinD6431(n = 41)
  val b2 = b.dup()
  assertEqualInt(b2.n, 42, "val-bound b2.n resolves TwinD6431's own field via the checkcast-narrowed call result")
}

test "Self-return call-site substitution, two same-package records sharing a field name (#6431)" {
  val d = TwinD6431(n = 41)
  val d2 = d.dup()
  assertEqualInt(d2.n, 42, "d2.n resolves TwinD6431's own field, not TwinC6431's (guards against a name-only fallback)")
}

test "chained Self-returning calls narrow the receiver class at each call site (#6431)" {
  val d = TwinD6431(n = 40)
  val d3 = d.dup().dup()
  assertEqualInt(
    d3.n,
    42,
    "each .dup() call re-narrows the result to TwinD6431 so the second call's field read resolves"
  )
}

// A single-record shape (no field-name collision) as an additional guard:
// the collision cases above already imply this passes, but pinning it
// separately documents the simplest possible repro alongside the harder one.
record Box6431 {
  n: Int
}

interface SimpleCloner6431 {
  func dup(self: in Self): Self
}

impl SimpleCloner6431 for Box6431 {
  func dup(self: in Self): Self {
    Box6431(n = self.n + 1)
  }
}

test "direct call with a Self return type, single record, no field-name collision (#6431)" {
  val b = Box6431(n = 41)
  val b2 = b.dup()
  assertEqualInt(b2.n, 42, "single-record baseline: the checkcast-narrowed call result resolves n correctly")
}

// #6437 (review of the first #6431 draft): the narrowing was wired into only
// one of the three reachable instance-call dispatch paths. These two cases
// pin the other two.
//
// Path 2 — `lowerVirtualCallWithHolders`: a Self-returning method that ALSO
// carries an `inout` (holder) param routes through the holder call path
// BEFORE the non-holder branch's narrowing is ever reached; the checkcast
// must land right after the invoke, while the return value is top-of-stack,
// ahead of the holder write-backs.
record Tagged6437 {
  n: Int
}

interface TagCloner6437 {
  func dupTagged(self: in Self, tag: inout Int): Self
}

impl TagCloner6437 for Tagged6437 {
  func dupTagged(self: in Tagged6437, tag: inout Int): Self {
    tag = tag + 1
    Tagged6437(n = self.n + 1)
  }
}

test "Self return through the holder (inout-param) call path (#6437)" {
  val b = Tagged6437(n = 41)
  var t = 7
  val b2 = b.dupTagged(t)
  assertEqualInt(b2.n, 42, "holder-path call result narrows to the receiver class and resolves n")
  assertEqualInt(t, 8, "the inout write-back still lands after the narrowing checkcast")
}

// Path 3 — the bare intra-impl sibling call (`lowerGeneralStaticCall`'s
// `ctx.selfClass` branch, #1722): `dup()` without a `self.` prefix inside a
// sibling method of the SAME impl dispatches on the implicit receiver; the
// result narrows against the enclosing method's own class.
interface Duo6437 {
  func dup(self: in Self): Self
  func bumpViaSibling(self: in Self): Int
}

record Pair6437 {
  n: Int
}

impl Duo6437 for Pair6437 {
  func dup(self: in Pair6437): Self {
    Pair6437(n = self.n + 1)
  }
  func bumpViaSibling(self: in Pair6437): Int {
    val d = dup()
    d.n
  }
}

test "Self return through a bare sibling call inside the same impl (#6437)" {
  val p = Pair6437(n = 41)
  assertEqualInt(p.bumpViaSibling(), 42, "bare dup() narrows against the enclosing impl's own class")
}
