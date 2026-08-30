//! range_subtype_self_test.l — executable regression test for distinct- and
//! range-subtype construction in the **self-hosted** MSIL and JVM backends
//! (#1501, JVM parity in #5956).
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
// `range_subtype_unsigned_jvm_self_test.l`.
// `UInt`/`ULong`-backed range subtypes are JVM-ONLY today: MSIL's
// `typeExprToMsilCtx` has no `UInt`/`ULong` arm at all (unlike `Float`,
// which erases to `MDouble` there) — a `UInt`/`ULong`-backed distinct type
// falls through to "user type in this package" on `--target dotnet` and
// crashes the CLR loader ("invalid program"), so those cases live in the
// JVM-only `range_subtype_unsigned_jvm_self_test.l` instead of here (this
// file runs on BOTH targets). Extending MSIL is tracked separately —
// out of scope for #6661, which is specifically about the JVM backend.
