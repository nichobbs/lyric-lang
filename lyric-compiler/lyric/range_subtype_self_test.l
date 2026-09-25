//! range_subtype_self_test.l — executable regression test for distinct- and
//! range-subtype construction in the **self-hosted** MSIL and JVM backends
//! (#1501, JVM parity in #5956). `UInt`/`ULong`-backed cases (#6756, moved
//! here from the formerly JVM-only `range_subtype_unsigned_jvm_self_test.l`
//! once MSIL gained a real `UInt`/`ULong` representation) run on both
//! targets — see the `Population`/`BigId` section below. The final section
//! (#6913) extends this UInt/ULong test home to BARE (not range-/distinct-
//! type-wrapped) `UInt`/`ULong` scalar comparison/division/stringification —
//! the general `fctx.unsignedSlots` side-channel #6756 deliberately left out
//! of scope (see that section's own header comment).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: those
//! `_tests.l` files are compiled and run by the **F# stage-0** emitter, which
//! has always synthesised the distinct/range construction API (`from`,
//! `tryFrom`, `toInt`).  Neither self-hosted backend did, at first — a
//! `Type.from(x)` / `Type.tryFrom(x)` / `value.toInt()` call compiled to invalid
//! IL under `Msil.Bridge` (InvalidProgramException at run time, #1501) or
//! failed to compile at all under `Jvm.Bridge` ("reference 'Age' resolves to
//! no local, parameter, ...", #5956), and range bounds were dropped entirely
//! (`rangeClause` was never read by either emitter).  This file is run by
//! native `lyric test`, which compiles it in-process through the self-hosted
//! pipeline (lexer → parser → type-checker → mode-checker → codegen → MSIL PE
//! or JVM class files) and executes it, so it exercises the path the
//! `_tests.l` files cannot.
//!
//!   lyric test lyric-compiler/lyric/range_subtype_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/range_subtype_self_test.l
//!
//! Most cases below consume `match` rather than the `isOk`/`isErr` stdlib
//! helpers: a generic stdlib function applied to a `Result` over a *user*
//! type still erases its type arguments in the self-hosted backend (the
//! cross-package generic-function monomorphization gap, #1498), which is
//! orthogonal to the construction API this test covers.  Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! The final section (`isOk`/`isErr`/`unwrapResult` directly over a
//! `Result[Age, String]`/`Result[DiceRoll, String]`) exercises the #5841
//! slice of #1498: `Lyric.Mono` now recognises `Type.tryFrom(x)` /
//! `Type.from(x)` as returning the real `Result[Type, String]` /  `Type`
//! instantiation (rather than defaulting the unresolved type argument(s) to
//! `Object`), so these calls monomorphise correctly instead of throwing
//! "match not exhaustive" at runtime.  Runs on both `--target dotnet` and
//! `--target jvm` (#5956): `Lyric.Mono`'s `Type.tryFrom`/`Type.from`
//! return-type recognition is shared front-end logic, so once the JVM
//! backend gained the construction API this monomorphization slice worked
//! unmodified on both targets.
@test_module
package Lyric.RangeSubtypeSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Range subtypes under test.
// ─────────────────────────────────────────────────────────────────────────────
type Age = Int range 0 ..= 150

// closed range
type Idx = Int range 0 ..< 10

// half-open range
type Cents = Long range 0 ..= 1000000000000

type UserId = Int

// plain distinct type (no range)
// match-based Ok/Err predicates (see header: `isOk` over a user type erases).
func ageIsOk(r: in Result[Age, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func idxIsOk(r: in Result[Idx, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func centsIsOk(r: in Result[Cents, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

func ageValue(r: in Result[Age, String]): Int {
  match r {
    case Ok(a) -> a.toInt()
    case Err(_) -> -1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// tryFrom — in-range yields Ok, out-of-range yields Err.
// ─────────────────────────────────────────────────────────────────────────────
test "tryFrom accepts in-range and rejects out-of-range (closed)" {
  assertTrue(ageIsOk(Age.tryFrom(25)), "25 in [0,150]")
  assertTrue(ageIsOk(Age.tryFrom(0)), "0 lower bound inclusive")
  assertTrue(ageIsOk(Age.tryFrom(150)), "150 upper bound inclusive")
  assertFalse(ageIsOk(Age.tryFrom(151)), "151 above upper bound")
  assertFalse(ageIsOk(Age.tryFrom(-1)), "-1 below lower bound")
  assertFalse(ageIsOk(Age.tryFrom(1000)), "1000 well above range")
}

test "tryFrom round-trips the wrapped value via toInt" {
  assertEqualInt(ageValue(Age.tryFrom(42)), 42, "Ok(42).toInt() == 42")
  assertEqualInt(ageValue(Age.tryFrom(151)), -1, "Err carries no value")
}

test "tryFrom honours a half-open upper bound" {
  assertTrue(idxIsOk(Idx.tryFrom(0)), "0 in [0,10)")
  assertTrue(idxIsOk(Idx.tryFrom(9)), "9 in [0,10)")
  assertFalse(idxIsOk(Idx.tryFrom(10)), "10 excluded by half-open upper bound")
  assertFalse(idxIsOk(Idx.tryFrom(11)), "11 above range")
}

test "tryFrom validates a Long-backed range" {
  assertTrue(centsIsOk(Cents.tryFrom(0)), "0 lower bound")
  assertTrue(centsIsOk(Cents.tryFrom(999999999999)), "just inside upper bound")
  assertTrue(centsIsOk(Cents.tryFrom(1000000000000)), "upper bound inclusive")
  assertFalse(centsIsOk(Cents.tryFrom(1000000000001)), "one over upper bound")
}

// ─────────────────────────────────────────────────────────────────────────────
// from — in-range constructs, out-of-range throws (caught here as a value-level
// distinction via tryFrom; `from` shares the identical bounds check).  We assert
// the in-range construction and projection round-trip directly.
// ─────────────────────────────────────────────────────────────────────────────
test "from constructs in-range and projects back via toInt" {
  assertEqualInt(Age.from(0).toInt(), 0, "from(0).toInt()")
  assertEqualInt(Age.from(75).toInt(), 75, "from(75).toInt()")
  assertEqualInt(Age.from(150).toInt(), 150, "from(150).toInt()")
}

// docs/01 §2.2: `from`'s panic message carries "<TypeName>.from: value out of
// range [lo, hi]" on both backends, though not byte-identically — on
// `--target jvm` that text IS the caught `.message` verbatim; on
// `--target dotnet` the emitter's single-`String` `ArgumentOutOfRangeException`
// constructor is interpreted by .NET as the `paramName` overload, so the
// caught `.message` wraps the same text in .NET's default boilerplate
// ("Specified argument was out of the range of valid values. (Parameter
// '...')"). Assert the substring both targets actually share.
test "from panics with the documented cross-target message shape (docs/01 §2.2)" {
  assertPanicsWith(
    "Age.from(151) panics out of range",
    "Age.from: value out of range [0, 150]",
    { -> val _ = Age.from(151) }
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Plain distinct types (no range) get the same construction/projection API.
// ─────────────────────────────────────────────────────────────────────────────
test "plain distinct type constructs and projects" {
  assertEqualInt(UserId.from(42).toInt(), 42, "UserId.from(42).toInt()")
  assertEqualInt(UserId.from(0).toInt(), 0, "UserId.from(0).toInt()")
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline refined types (docs/59 §3 F2): an inline `T range lo ..= hi`
// annotation must be represented as its UNDERLYING type — the emitter used to
// hard-wire every inline refinement to Int, truncating Long and Double bases.
// ─────────────────────────────────────────────────────────────────────────────
func addBig(a: in Long, b: in Long): Long {
  val total: Long range 0 ..= 10000000000 = a + b
  total
}

test "inline Long range binding preserves values beyond Int32.Max" {
  assertEqualLong(
    addBig(3000000000i64, 2000000000i64),
    5000000000i64,
    "inline Long-range local must keep the full 64-bit value"
  )
}

func halveRatio(x: in Double): Double {
  val r: Double range 0.0 ..= 1.0 = x / 2.0
  r
}

test "inline Double range binding preserves the floating-point value" {
  val h = halveRatio(0.5)
  assertTrue(h > 0.2499 and h < 0.2501, "inline Double-range local must stay a Double (0.25)")
}

// ─────────────────────────────────────────────────────────────────────────────
// #5841 — the stdlib `isOk`/`isErr`/`unwrapResult` generics applied DIRECTLY to
// `Age.tryFrom(...)` / a second, differently-shaped range subtype
// (`DiceRoll`).  Before the fix, `Lyric.Mono` could not infer `Age.tryFrom`'s
// return type and defaulted both `T` and `E` to `Object`, producing an
// `isOk__Object__Object` specialisation whose match arms did not match the
// real `Result[Age, String]` runtime value ("match not exhaustive").  Two
// distinct range subtypes (`Age`, `DiceRoll`) confirm each call site
// specialises against its OWN payload type rather than colliding.
// ─────────────────────────────────────────────────────────────────────────────
type DiceRoll = Int range 1 ..= 6

test "isOk/isErr over Age.tryFrom specialise against the real payload type (#5841)" {
  val ok = Age.tryFrom(25)
  assertTrue(isOk(ok), "Age.tryFrom(25) is Ok")
  assertFalse(isErr(ok), "Age.tryFrom(25) is not Err")
  assertEqualInt(unwrapResult(ok).toInt(), 25, "unwrapResult(ok).toInt() round-trips")

  val tooOld = Age.tryFrom(200)
  assertTrue(isErr(tooOld), "Age.tryFrom(200) is Err")
  assertFalse(isOk(tooOld), "Age.tryFrom(200) is not Ok")

  val neg = Age.tryFrom(-1)
  assertTrue(isErr(neg), "Age.tryFrom(-1) is Err")
}

test "isOk/isErr over a second range subtype specialise independently (#5841)" {
  val ok = DiceRoll.tryFrom(6)
  assertTrue(isOk(ok), "DiceRoll.tryFrom(6) is Ok")
  assertEqualInt(unwrapResult(ok).toInt(), 6, "unwrapResult(ok).toInt() round-trips")

  val zero = DiceRoll.tryFrom(0)
  assertTrue(isErr(zero), "DiceRoll.tryFrom(0) is Err")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6661 — every OTHER numeric primitive `docs/01-language-reference.md`
// §2.1 permits as a range-subtype base type (`isNumericPrimitiveName`,
// `typechecker_checker.l`): `Byte`, `UInt`, `ULong`, `Float`, and a NAMED
// (not just inline) `Double`.  The original #5956 landing only exercised
// `Int`/`Long`/inline-`Double` — the JVM backend's range-bound fold
// (`Jvm.Codegen.mkJvmDistinctRanged`) miscategorised `Float` as an integer
// bound (`isFloatInner` matched only `JDouble`), producing unverifiable
// bytecode (a `fload`-loaded 32-bit float argument compared via plain `int`
// opcodes), and had NO representation at all for `UInt`/`ULong`
// (`Jvm.Codegen.typeExprToJvm` fell through to "user type in this package",
// a nonexistent class). `argSatisfiesParam`'s numeric-widening rules
// (`typechecker_exprs.l`) never widen a bare (`PtInt`/`PtDouble`-typed)
// literal DOWN into a narrower `Byte`/`Float` parameter, so every
// `Byte`/`UInt`/`ULong`/`Float` call argument below carries its exact
// literal suffix (`u8`/`u32`/`u64`/`f32`) — `Nat` is excluded from this
// section for the same reason: no literal suffix produces `PtNat` and
// `PtNat` participates in neither the signed nor unsigned widening family
// (`signedIntRank`/`unsignedIntRank`), so a `Nat`-typed parameter cannot be
// satisfied by ANY integer-literal call argument today — a genuine,
// pre-existing type-checker gap orthogonal to #6661's JVM lowering bugs.
// ─────────────────────────────────────────────────────────────────────────────
// `Byte` (8-bit UNSIGNED, docs/01 §2.1: `0 ..= 255`) — a named range clause
// crossing the JVM's native signed-byte midpoint (128) pins the existing
// unsigned-byte convention (`maskByteUnsigned`, `Jvm.Codegen`) actually
// holds for range-subtype construction/bounds-checking too, not just plain
// `Byte` arithmetic.  No `.toX()` projection assertion here: the distinct-
// type conversion method's NAME is derived from the underlying type's
// per-backend representation (`Jvm.Lowering.jvmDistinctConvName` /
// `Msil.Lowering.distinctConvName`), and `Byte` maps to a DIFFERENT
// representation on each backend (`JByte` on JVM → `"toByte"`; `MInt` on
// MSIL, since `typeExprToMsilCtx` erases `Byte` to plain `int` in scalar
// position → `"toInt"`) — a pre-existing MSIL/JVM naming inconsistency
// (docs/59 "dual Byte representations") orthogonal to #6661, so no single
// method name is portable across both targets this file runs on.
type SmallByte = Byte range 10 ..= 250

func smallByteIsOk(r: in Result[SmallByte, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "Byte-backed range subtype: bounds, including values above 127 (#6661)" {
  assertTrue(smallByteIsOk(SmallByte.tryFrom(10u8)), "10 lower bound inclusive")
  assertTrue(smallByteIsOk(SmallByte.tryFrom(200u8)), "200 (above JVM signed-byte midpoint) is in range")
  assertTrue(smallByteIsOk(SmallByte.tryFrom(250u8)), "250 upper bound inclusive")
  assertFalse(smallByteIsOk(SmallByte.tryFrom(9u8)), "9 below lower bound")
  assertFalse(smallByteIsOk(SmallByte.tryFrom(251u8)), "251 above upper bound")
}

// NAMED `Double` range subtype (the existing coverage was inline-only,
// `Long addBig`/`halveRatio` above) plus `Float` — the JVM-specific bug:
// `Float` (`JFloat`, a real 32-bit type distinct from `JDouble` on this
// backend, unlike MSIL where `Float` erases to `MDouble`) was folded as an
// INTEGER bound before the fix, so `Weight.tryFrom(...)` either failed
// class verification or silently compared the wrong bit pattern.
type Fraction = Double range 0.0 ..= 1.0

func fractionIsOk(r: in Result[Fraction, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "named Double-backed range subtype: bounds (#6661)" {
  assertTrue(fractionIsOk(Fraction.tryFrom(0.0)), "0.0 lower bound inclusive")
  assertTrue(fractionIsOk(Fraction.tryFrom(0.75)), "0.75 in range")
  assertTrue(fractionIsOk(Fraction.tryFrom(1.0)), "1.0 upper bound inclusive")
  assertFalse(fractionIsOk(Fraction.tryFrom(-0.001)), "-0.001 below lower bound")
  assertFalse(fractionIsOk(Fraction.tryFrom(1.001)), "1.001 above upper bound")
  assertTrue(Fraction.from(0.5).toDouble() > 0.4999, "from(0.5).toDouble() round-trips (lower)")
  assertTrue(Fraction.from(0.5).toDouble() < 0.5001, "from(0.5).toDouble() round-trips (upper)")
}

type Weight = Float range 0.0 ..= 100.0

func weightIsOk(r: in Result[Weight, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "Float-backed range subtype: bounds — the #6661 headline case" {
  assertTrue(weightIsOk(Weight.tryFrom(0.0f32)), "0.0 lower bound inclusive")
  assertTrue(weightIsOk(Weight.tryFrom(55.5f32)), "55.5 in range")
  assertTrue(weightIsOk(Weight.tryFrom(100.0f32)), "100.0 upper bound inclusive")
  assertFalse(weightIsOk(Weight.tryFrom(-0.5f32)), "-0.5 below lower bound")
  assertFalse(weightIsOk(Weight.tryFrom(100.5f32)), "100.5 above upper bound")
}

test "Float-backed range subtype: from() constructs in-range and panics out-of-range (#6661)" {
  val _ = Weight.from(0.0f32)
  val _ = Weight.from(100.0f32)
  val _ = Weight.from(42.5f32)
  assertPanics("Weight.from(100.5) panics above the upper bound", { -> val _ = Weight.from(100.5f32) })
}

// No `.toFloat()`/`.toDouble()` projection assertion here (same reasoning as
// `SmallByte` above): a `Float`-backed distinct type's conversion-method NAME
// is per-backend (`Jvm.Lowering.jvmDistinctConvName` -> `"toFloat"` on JVM,
// since `JFloat` is its own JVM representation; MSIL erases `Float` to
// `MDouble` in scalar position, so `Msil.Lowering.distinctConvName` names it
// `"toDouble"` there) — no single method name is portable across both
// targets this file runs on. The JVM-only `.toFloat()` round-trip (the
// #6661-followup gap where `jvmDistinctConvName` had no `JFloat` case at all,
// so a constructed `Weight` could never be read back on JVM) lives in
// `range_subtype_float_jvm_self_test.l`.
//
// ─────────────────────────────────────────────────────────────────────────────
// #6756 — `UInt`/`ULong`-backed range subtypes, moved here (dual-target) now
// that MSIL has a real `UInt`/`ULong` representation. Before the fix,
// `Msil.Codegen.typeExprToMsilCtx` had no `UInt`/`ULong` arm at all (unlike
// `Float`, which already erased to `MDouble`), so a `UInt`/`ULong`-backed
// distinct type fell through to "user type in this package" on
// `--target dotnet` and crashed the CLR loader ("Common Language Runtime
// detected an invalid program"). Fixed by erasing `UInt -> MInt` /
// `ULong -> MLong` (the SAME 32-/64-bit slot a signed `Int`/`Long` uses,
// mirroring the JVM backend's identical `UInt -> JInt`/`ULong -> JLong`
// erasure, #6661/#6695) plus unsigned-aware (`clt.un`/`cgt.un`) bounds
// checking in `emitDistinctBoundsToFail` — a plain SIGNED comparison
// misreads any in-range value at or above 2^31 (`UInt`) as negative,
// silently failing the bounds check for a legitimate value.
// ─────────────────────────────────────────────────────────────────────────────
type Population = UInt range 1000 ..= 4000000000

func populationIsOk(r: in Result[Population, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "UInt-backed range subtype: values with the sign bit set are still in range (#6756)" {
  assertTrue(populationIsOk(Population.tryFrom(1000u32)), "1000 lower bound inclusive")
  assertTrue(
    populationIsOk(Population.tryFrom(2500000000u32)),
    "2500000000 (>2^31, in range) must not read as negative"
  )
  assertTrue(populationIsOk(Population.tryFrom(4000000000u32)), "4000000000 upper bound inclusive (>2^31)")
  assertFalse(populationIsOk(Population.tryFrom(999u32)), "999 below lower bound")
  assertFalse(populationIsOk(Population.tryFrom(4000000001u32)), "4000000001 above upper bound (>2^31)")
}

func populationValue(r: in Result[Population, String]): Int {
  match r {
    case Ok(p) -> p.toInt()
    case Err(_) -> -1
  }
}

test "UInt-backed range subtype: toInt() projection round-trips for a small value (#6756)" {
  assertEqualInt(populationValue(Population.tryFrom(5000u32)), 5000, "tryFrom(5000).toInt() round-trips")
}

// `ULong` (64-bit unsigned) — a bound exercising the sign bit would need to
// exceed `Long.MAX_VALUE` (9223372036854775807), which the shared Int64-based
// range-literal fold (`foldRangeBound`) cannot represent — same pre-existing
// limitation the `Cents` case above lives with, orthogonal to #6756.
type BigId = ULong range 0 ..= 9000000000000000000

func bigIdIsOk(r: in Result[BigId, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "ULong-backed range subtype: construction and bounds (#6756)" {
  assertTrue(bigIdIsOk(BigId.tryFrom(0u64)), "0 lower bound inclusive")
  assertTrue(bigIdIsOk(BigId.tryFrom(123456789012345u64)), "a large in-range value")
  assertTrue(bigIdIsOk(BigId.tryFrom(9000000000000000000u64)), "9000000000000000000 upper bound inclusive")
  assertEqualLong(BigId.from(42u64).toLong(), 42i64, "from(42).toLong() round-trips")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6913 — a BARE (not range-/distinct-type-wrapped) `UInt`/`ULong` scalar's
// comparison (`<`/`>`/`<=`/`>=`), division/remainder (`/`/`%`), and
// stringification (`.toString()`/`toString(x)`/interpolation/concatenation)
// at/above the sign-bit boundary (2^31 for `UInt`, 2^63 for `ULong`).
//
// #6756 (above) gave MSIL a real `UInt`/`ULong` REPRESENTATION and fixed the
// crash class, but only `MDistinctType.isUnsigned`-gated range-subtype bounds
// checking consulted it for unsigned-aware codegen — a bare scalar's own
// comparison/division/stringification still used plain SIGNED IL
// (`clt`/`cgt`/`div`/`rem`/`Int32.ToString()`), silently misrendering any
// value with the sign bit set. Fixed via a new `fctx.unsignedSlots`
// side-channel (`Msil.Codegen`, keyed by SLOT INDEX rather than name — see
// its own doc comment for why that avoids the JVM backend's separate
// `unsignedUndo` scope-restore log) populated at every param/`val`/`var`/
// `let` binding site whose declared type is `UInt`/`ULong`, consulted by
// `isUnsignedExprMsil` from the `BLt`/`BGt`/`BLte`/`BGte`/`BDiv`/`BMod` binop
// arms and every stringification call site (`println`, `print`, `toString`,
// string interpolation, `+` string concatenation). Runs on BOTH targets:
// JVM already got the equivalent fix in #6748/#6754 (`ctx.unsignedVars`/
// `isUnsignedExpr`, `jvm/codegen/01_types.l`), so this section is a genuine
// cross-target parity check, not just an MSIL-only regression pin.
//
// Scoped to the shape #6913's fix sketch actually asks for — a bare name
// previously marked at a binding site, or a `u32`/`u64`-suffixed literal —
// NOT a function call's declared return type or a container-element read
// (the JVM backend's own LATER #6754/#6759 follow-on widenings past its
// original `unsignedVars`/`isUnsignedExpr` shape); an expression of either
// of those two shapes still conservatively compiles/runs correctly for
// every value that fits the signed range either way, understating
// "unsigned" only for a sign-bit-set value reached that way — a narrower,
// tracked gap, not silently dropped (see `isUnsignedExprMsil`'s own doc
// comment in `msil/codegen.l`).
// ─────────────────────────────────────────────────────────────────────────────
// ── UInt: comparison ─────────────────────────────────────────────────────────
//
// `3_000_000_000` and `1_000_000_000` are both valid `UInt` values (range
// `0 ..= 4_294_967_295`), but `3_000_000_000` carries the sign bit as a
// signed 32-bit int (`3_000_000_000 - 2^32 = -1_294_967_296`), so a plain
// signed `clt`/`cgt` would report `a < b` as TRUE and `a > b` as FALSE —
// backwards.
test "bare UInt relational comparison is unsigned across the sign bit (#6913)" {
  val a: UInt = 3000000000u32
  val b: UInt = 1000000000u32
  assertTrue(a > b, "3_000_000_000 > 1_000_000_000 (unsigned)")
  assertFalse(a < b, "3_000_000_000 < 1_000_000_000 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
  assertTrue(b < a, "1_000_000_000 < 3_000_000_000 (unsigned)")
  assertFalse(b > a, "b > a must be false")
}

test "bare UInt equality is unaffected by the unsigned fix (sanity check) (#6913)" {
  val a: UInt = 3000000000u32
  val c: UInt = 3000000000u32
  assertTrue(a == c, "equal UInt values compare equal")
  assertFalse(a != c, "equal UInt values are not unequal")
}

// A `UInt` PARAMETER (not just a local) must get the same treatment —
// exercises `registerParamsMsil`'s / `lowerFuncMsil`'s `markUnsignedSlotMsil`
// call.
func uintGreaterMsil(x: in UInt, y: in UInt): Bool {
  x > y
}

test "bare UInt comparison inside a function parameter (#6913)" {
  assertTrue(uintGreaterMsil(3000000000u32, 1000000000u32), "param-typed UInt comparison is unsigned")
  assertFalse(uintGreaterMsil(1000000000u32, 3000000000u32), "reversed args correctly false")
}

// ── UInt: division / remainder ───────────────────────────────────────────────
//
// Signed `div`/`rem` on the same sign-bit-set bit pattern computes the WRONG
// quotient/remainder (a two's-complement negative-value truncating divide).
test "bare UInt division and remainder are unsigned across the sign bit (#6913)" {
  val a: UInt = 3000000000u32
  val two: UInt = 2u32
  val seven: UInt = 7u32
  assertTrue((a / two) == 1500000000u32, "3_000_000_000 / 2 == 1_500_000_000 (unsigned)")
  assertTrue((a % seven) == 4u32, "3_000_000_000 % 7 == 4 (unsigned)")
}

// ── UInt: toString / interpolation / concatenation ───────────────────────────
//
// `Int32.ToString()` on the signed bit pattern of `3_000_000_000` prints
// "-1294967296" — the exact silent miscompile #6913 describes.
test "bare UInt toString renders the unsigned decimal value (#6913)" {
  val a: UInt = 3000000000u32
  assertEqual(a.toString(), "3000000000", "member .toString() is unsigned")
  assertEqual(toString(a), "3000000000", "free toString(x) is unsigned")
}

test "bare UInt string interpolation renders the unsigned decimal value (#6913)" {
  val a: UInt = 3000000000u32
  assertEqual("value=${a}", "value=3000000000", "interpolation is unsigned")
}

test "bare UInt string concatenation renders the unsigned decimal value (#6913)" {
  val a: UInt = 3000000000u32
  assertEqual("value=" + a.toString(), "value=3000000000", "+ concatenation is unsigned")
}

// `println` cannot be byte-captured safely here: this file is a
// `@test_module`, whose synthesised `main()` prints EVERY test's own TAP
// result line via `println` after each test runs — redirecting
// `System.Console.Out` process-globally (the only capture mechanism .NET
// offers, mirroring the JVM backend's own `unsigned_int_ops_jvm_self_test.l`
// `System.setOut`-based capture) and leaving it redirected if THIS test's own
// `assertTrue`/`assertEqual` panics would silently swallow every later test's
// TAP output too, masking unrelated failures. Instead this pins that
// `println` on a sign-bit-set `UInt`/`ULong` reaches the new unsigned
// `Console.WriteLine(uint32)`/`Console.WriteLine(uint64)` MemberRef tokens
// (`Msil.Codegen.tokWriteLineUInt`/`tokWriteLineULong`) and RUNS without a
// `MissingMethodException`/`InvalidProgramException` — the concrete NEW
// failure mode this fix's hand-built signature blob could introduce beyond
// the boxing path the `toString`/interpolation/concatenation cases above
// already exercise byte-for-byte. Manually verified end-to-end (actual
// captured stdout bytes, both `UInt` and `ULong`) against a from-source
// build — see this fix's decision-log entry / PR description.
test "bare UInt println does not crash for a sign-bit-set value (#6913)" {
  val a: UInt = 3000000000u32
  println(a)
  assertTrue(true, "println(UInt) above 2^31 ran without throwing")
}

// ── UInt: block-scope shadow does not leak unsigned-ness either direction ────
//
// Mirrors the JVM backend's #6754 finding-2 regression (name-keyed
// `unsignedVars` needing its own scope-undo log) — MSIL's `unsignedSlots` is
// keyed by SLOT INDEX instead (see its doc comment), so a shadowing bind
// already gets a FRESH slot via the pre-existing #5191 general-shadowing fix
// and this correctness property falls out "for free," but it's worth an
// explicit A/B-verified regression pin rather than an unverified claim.
test "bare UInt: nested Int shadow is signed, outer UInt survives the block (#6913)" {
  val x: UInt = 3000000000u32
  val threshold: UInt = 1000000000u32
  val enterShadow = x > threshold
  if enterShadow {
    val x: Int = -1
    assertTrue(x < 0, "the INNER shadow x is a plain signed Int (must not inherit the outer UInt tracking)")
  }
  assertTrue(x > threshold, "the OUTER x is still UInt after the shadowing block exits (unsigned compare)")
  assertFalse(x < threshold, "the OUTER x < threshold must be false (unsigned) after the block exits")
  assertEqual(x.toString(), "3000000000", "the OUTER x's toString is still unsigned after the block exits")
}

// ── ULong: comparison ─────────────────────────────────────────────────────────
//
// A `ULong` literal is folded through the lexer's signed `Int64` field, so no
// LITERAL can directly express a value at or above `2^63` (the same
// limitation `BigId` above documents) — `a` is built via `ULong` ADDITION
// instead (`add` wraps identically for signed and unsigned two's-complement,
// so this is a faithful way to reach a sign-bit-set `ULong` value at
// runtime): `Long.MaxValue + 4 == 2^63 + 3`, which reads as a large NEGATIVE
// number under a signed 64-bit interpretation, so the same class of bug
// applies to `clt`/`cgt`/`div`/`rem`.
test "bare ULong relational comparison is unsigned across the sign bit (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val b: ULong = 1000000000000000000u64
  assertTrue(a > b, "2^63+3 > 1e18 (unsigned) — a signed read of a is deeply negative")
  assertFalse(a < b, "2^63+3 < 1e18 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
}

// A `ULong` `var` (not just `val`/param) must get the same treatment —
// exercises the `LBVar` binding-site `markUnsignedSlotMsil` call.
test "bare ULong var comparison is unsigned across the sign bit (#6913)" {
  val base: ULong = 9223372036854775807u64
  var a: ULong = base + 4u64
  val b: ULong = 1000000000000000000u64
  assertTrue(a > b, "var-bound a > b (unsigned)")
  a = base + 5u64
  assertTrue(a > b, "reassigned var-bound a is still unsigned-compared")
}

// ── ULong: division / remainder ───────────────────────────────────────────────
test "bare ULong division and remainder are unsigned across the sign bit (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val two: ULong = 2u64
  val three: ULong = 3u64
  assertTrue((a / two) == 4611686018427387905u64, "(2^63+3) / 2 (unsigned)")
  assertTrue((a % two) == 1u64, "(2^63+3) % 2 == 1 (unsigned)")
  assertTrue((a / three) == 3074457345618258603u64, "(2^63+3) / 3 (unsigned)")
  assertTrue((a % three) == 2u64, "(2^63+3) % 3 == 2 (unsigned)")
}

// ── ULong: toString / interpolation / concatenation ───────────────────────────
test "bare ULong toString renders the unsigned decimal value (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual(a.toString(), "9223372036854775811", "member .toString() is unsigned")
  assertEqual(toString(a), "9223372036854775811", "free toString(x) is unsigned")
}

test "bare ULong string interpolation renders the unsigned decimal value (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual("value=${a}", "value=9223372036854775811", "interpolation is unsigned")
}

test "bare ULong string concatenation renders the unsigned decimal value (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual("value=" + a.toString(), "value=9223372036854775811", "+ concatenation is unsigned")
}

test "bare ULong println does not crash for a sign-bit-set value (#6913)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  println(a)
  assertTrue(true, "println(ULong) above 2^63 ran without throwing")
}

record Priced {
  cents: Cents
}

// A range subtype over `Long` built from an `Int` literal widens the argument
// (`from`/`tryFrom` took an `int32` where `int64` was declared, invalid IL),
// and renders as its value, not its wrapper type's name (D-progress-967).
test "a Long range subtype from an Int literal renders as its value (D-progress-967)" {
  val c = Cents.from(5000)
  assertEqual(c.toString(), "5000", "toString")
  assertEqual("price: ${c}", "price: 5000", "interpolation")
  assertEqual(toString(c), "5000", "free toString")
  val p = Priced(cents = Cents.from(7))
  assertEqual(p.cents.toString(), "7", "field toString")
  match Cents.tryFrom(12) {
    case Ok(v) -> assertEqual(v.toString(), "12", "tryFrom value")
    case Err(e) -> assertTrue(false, "tryFrom failed: " + e)
  }
}

type Quota = UInt range 0u32 ..= 4294967295u32

// A `UInt`-backed range erases to the signed representation on both targets;
// stringifying it must still use the unsigned formatter (D-progress-967).
test "a UInt range subtype renders its value unsigned (D-progress-967)" {
  val q = Quota.from(4000000000u32)
  assertEqual(q.toString(), "4000000000", "toString")
  assertEqual("quota: ${q}", "quota: 4000000000", "interpolation")
  assertEqual("q=" + toString(q), "q=4000000000", "free toString")
}

type Ratio = Double range 0.0 ..= 1.0

type Enabled = Bool

// A `Double`- or `Bool`-backed distinct value stringifies exactly as its
// underlying type: invariant-culture decimal and lowercase `true`/`false`,
// not the boxed wrapper's `Object.ToString()` (D-progress-967).
test "a Double range subtype renders its value like a Double (D-progress-967)" {
  val r = Ratio.from(0.5)
  assertEqual(r.toString(), "0.5", "toString")
  assertEqual(toString(r), "0.5", "free toString")
  assertEqual("ratio: ${r}", "ratio: 0.5", "interpolation")
  assertEqual("r=" + r.toString(), "r=0.5", "concatenation")
}

test "a Bool distinct type renders lowercase like a Bool (D-progress-967)" {
  val e = Enabled.from(true)
  assertEqual(e.toString(), "true", "toString")
  assertEqual(toString(e), "true", "free toString")
  assertEqual("enabled: ${e}", "enabled: true", "interpolation")
  val off = Enabled.from(false)
  assertEqual("${off}", "false", "interpolation of false")
}

// `println`/`print` of a distinct value print its underlying value. On the
// JVM they used to hand the wrapper to `PrintStream.println(String)`, a
// VerifyError that failed this whole module at class load (D-progress-967).
test "println and print of range and distinct values run on both targets (D-progress-967)" {
  println(Cents.from(5000))
  print(Ratio.from(0.5))
  println("")
  println(Enabled.from(true))
  println(Quota.from(4000000000u32))
  assertTrue(true, "println/print of distinct values ran without a verify error")
}
