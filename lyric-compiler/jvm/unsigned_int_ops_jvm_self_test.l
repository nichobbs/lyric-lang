//! unsigned_int_ops_jvm_self_test.l — JVM-only regression test for #6748:
//! `UInt`/`ULong` comparison/division/remainder/stringification outside the
//! range-subtype bounds-check path.
//!
//! #6661/#6695 gave the JVM backend proper `UInt`/`ULong` type-erasure
//! handling: `isPrimitiveTypeKeyword` reserves them, `typeExprToJvm` erases
//! them to `JInt`/`JLong`, and `Jvm.Lowering.emitJvmDistinctBoundsToFail`
//! (the range-subtype `from`/`tryFrom` bounds check) dispatches to
//! `Integer`/`Long.compareUnsigned` whenever `LDistinctType.isUnsigned` is
//! set. But that bounds check is internal plumbing for range-subtype
//! construction — ordinary user code comparing (`<`/`<=`/`>`/`>=`), dividing
//! (`/`), taking the remainder (`%`), or stringifying (`.toString()`, string
//! interpolation, `+` concatenation) a plain `UInt`/`ULong` VALUE still went
//! through the native SIGNED `if_icmpxx`/`lcmp`/`idiv`/`ldiv`/`irem`/`lrem`/
//! `String.valueOf` those types erase to — silently WRONG whenever the value
//! has its sign bit set (`UInt` >= 2^31, `ULong` >= 2^63), since the JVM has
//! no unsigned integer primitive at all. This file pins the fix: `Jvm.Codegen`
//! now tracks which locals/parameters/literals are statically `UInt`/`ULong`
//! (`FuncCtx.unsignedVars`, `isUnsignedExpr`) and dispatches relational
//! comparison, `/`, `%`, and stringification through `Integer`/
//! `Long.compareUnsigned`/`divideUnsigned`/`remainderUnsigned`/
//! `toUnsignedString` for exactly those operands, leaving plain `Int`/`Long`
//! on the native signed opcodes.
//!
//! `UInt`/`ULong` have no MSIL representation at all (docs/44,
//! `range_subtype_unsigned_jvm_self_test.l`'s header), so this file — like
//! that one — is JVM-only.
//!
//!   lyric test --target jvm lyric-compiler/jvm/unsigned_int_ops_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! #6754 (review findings on #6748/#6631) extended this file with three
//! more cases: `println`/`print` never consulted `isUnsignedExpr` at all
//! (they always pushed the raw signed `int`/`long` into
//! `PrintStream.println`/`.print`, unlike every OTHER stringification site
//! this file already covers); `isUnsignedExpr` was purely syntactic, missing
//! a `UInt`/`ULong`-returning function CALL and an indexed read off a
//! declared `slice[UInt]`/`slice[ULong]`; and `ctx.unsignedVars` was never
//! scope-restored, so a `UInt` shadowed by a same-named `Int` inside a
//! nested block leaked the wrong tracking in both directions. The
//! `println` cases below declare two extra `extern type`s
//! (`java.io.PrintStream` / `java.lang.System`) to redirect `System.out` to
//! a temp file and read the captured bytes back via `Std.File` — the only
//! way to assert what `println` actually WRITES, not a proxy for it.
//! `print`'s own codegen arm is fixed identically (mirrors `println`'s
//! shape) but is unreachable with a non-`String` argument through
//! type-checked Lyric source — `Std.Console.print` is declared `(s: in
//! String): Unit` and, unlike `println`, is NOT in the type checker's
//! polymorphic-builtin list — so there is no runtime case to assert for it;
//! see the comment on the second `println` test below.
@test_module
package Jvm.UnsignedIntOpsJvmSelfTest

import Std.Core
import Std.Testing
import Std.File

// ── UInt: comparison ─────────────────────────────────────────────────────────
//
// `3_000_000_000` and `1_000_000_000` are both valid `UInt` values (range
// `0 ..= 4_294_967_295`), but `3_000_000_000` carries the sign bit as a
// signed 32-bit int (`3_000_000_000 - 2^32 = -1_294_967_296`), so a plain
// signed `if_icmplt`/`if_icmpgt` would report `a < b` as TRUE and `a > b` as
// FALSE — backwards.
test "UInt relational comparison is unsigned across the sign bit (#6748)" {
  val a: UInt = 3000000000u32
  val b: UInt = 1000000000u32
  assertTrue(a > b, "3_000_000_000 > 1_000_000_000 (unsigned)")
  assertFalse(a < b, "3_000_000_000 < 1_000_000_000 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
  assertTrue(b < a, "1_000_000_000 < 3_000_000_000 (unsigned)")
  assertFalse(b > a, "b > a must be false")
}

test "UInt equality is unaffected (sanity check) (#6748)" {
  val a: UInt = 3000000000u32
  val c: UInt = 3000000000u32
  assertTrue(a == c, "equal UInt values compare equal")
  assertFalse(a != c, "equal UInt values are not unequal")
}

// A `UInt` PARAMETER (not just a local) must get the same treatment —
// exercises `setupStaticParamSlotsAndHolders`'s `recordUnsignedVarTy` call.
func uintGreater(x: in UInt, y: in UInt): Bool {
  x > y
}

test "UInt comparison inside a function parameter (#6748)" {
  assertTrue(uintGreater(3000000000u32, 1000000000u32), "param-typed UInt comparison is unsigned")
  assertFalse(uintGreater(1000000000u32, 3000000000u32), "reversed args correctly false")
}

// ── UInt: division / remainder ───────────────────────────────────────────────
//
// Signed `idiv`/`irem` on the same sign-bit-set bit pattern computes the
// WRONG quotient/remainder (Java's `idiv` truncates toward zero on the
// NEGATIVE interpretation of the bits).
test "UInt division and remainder are unsigned across the sign bit (#6748)" {
  val a: UInt = 3000000000u32
  val two: UInt = 2u32
  val seven: UInt = 7u32
  assertTrue((a / two) == 1500000000u32, "3_000_000_000 / 2 == 1_500_000_000 (unsigned)")
  assertTrue((a % seven) == 4u32, "3_000_000_000 % 7 == 4 (unsigned)")
}

// ── UInt: toString / interpolation / concatenation ───────────────────────────
//
// `String.valueOf(int)` on the signed bit pattern of `3_000_000_000` prints
// "-1294967296" — the exact silent miscompile this ticket describes.
test "UInt toString renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual(a.toString(), "3000000000", "member .toString() is unsigned")
  assertEqual(toString(a), "3000000000", "free toString(x) is unsigned")
}

test "UInt string interpolation renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual("value=${a}", "value=3000000000", "interpolation is unsigned")
}

test "UInt string concatenation renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual("value=" + a.toString(), "value=3000000000", "+ concatenation is unsigned")
}

// ── ULong: comparison ─────────────────────────────────────────────────────────
//
// A `ULong` literal is folded through the lexer's signed `Int64` field
// (`Lyric.Lexer.LInt.value: Long`), so no LITERAL can directly express a
// value at or above `2^63` (the same limitation
// `range_subtype_unsigned_jvm_self_test.l`'s `BigId` header documents) —
// `a` is built via `ULong` ADDITION instead (`ladd` wraps identically for
// signed and unsigned two's-complement, so this is a faithful way to reach
// a sign-bit-set `ULong` value at runtime): `Long.MAX_VALUE + 4 == 2^63 + 3`,
// which reads as a large NEGATIVE number under a signed 64-bit
// interpretation, so the same class of bug applies to `lcmp`/`ldiv`/`lrem`.
test "ULong relational comparison is unsigned across the sign bit (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val b: ULong = 1000000000000000000u64
  assertTrue(a > b, "2^63+3 > 1e18 (unsigned) — a signed read of a is deeply negative")
  assertFalse(a < b, "2^63+3 < 1e18 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
}

// ── ULong: division / remainder ───────────────────────────────────────────────
test "ULong division and remainder are unsigned across the sign bit (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val two: ULong = 2u64
  val three: ULong = 3u64
  assertTrue((a / two) == 4611686018427387905u64, "(2^63+3) / 2 (unsigned)")
  assertTrue((a % two) == 1u64, "(2^63+3) % 2 == 1 (unsigned)")
  assertTrue((a / three) == 3074457345618258603u64, "(2^63+3) / 3 (unsigned)")
  assertTrue((a % three) == 2u64, "(2^63+3) % 3 == 2 (unsigned)")
}

// ── ULong: toString / interpolation ───────────────────────────────────────────
test "ULong toString renders the unsigned decimal value (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual(a.toString(), "9223372036854775811", "member .toString() is unsigned")
  assertEqual(toString(a), "9223372036854775811", "free toString(x) is unsigned")
}

test "ULong string interpolation renders the unsigned decimal value (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual("value=${a}", "value=9223372036854775811", "interpolation is unsigned")
}

// ── println/print builtin (#6754 finding 1.1) ─────────────────────────────────
//
// `println`/`print` never consulted `isUnsignedExpr` at all — they always
// pushed the raw (possibly sign-bit-set) `int`/`long` straight into
// `PrintStream.println(int)`/`.print(long)`, which always renders the
// SIGNED decimal (`println(3_000_000_000u32)` printed `"-1294967296"`).
// Captured via a real `PrintStream` redirect (`System.setOut`) so this
// asserts the ACTUAL bytes `println`/`print` write, not a proxy for it.
extern type JPS = "java.io.PrintStream"

extern type JSys = "java.lang.System"

val printCapturePath: String = "/tmp/lyric_unsigned_print_jvm_self_test_6754.txt"

test "println renders the unsigned decimal value for a UInt above 2^31 (#6754 finding 1.1)" {
  deleteFile(printCapturePath)
  val capture = JPS.new(printCapturePath)
  JSys.setOut(capture)
  val a: UInt = 3000000000u32
  println(a)
  capture.flush()
  JSys.setOut(JPS.new("/dev/stdout"))
  val content = match readText(printCapturePath) { case Ok(s) -> s; case Err(_) -> "<read failed>" }
  deleteFile(printCapturePath)
  assertEqual(
    content,
    "3000000000\n",
    "println(UInt) must render the unsigned decimal (not the signed \"-1294967296\"); got: " + content
  )
}

// `Std.Console.print`'s DECLARED signature is `(s: in String): Unit`
// (`lyric-stdlib/std/console.l`) — unlike `println`, `print` is NOT in the
// type checker's `isCodegenBuiltinName` polymorphic-builtin list
// (`typechecker_checker.l`), so `print(<UInt/ULong>)` is a T0043 type error
// and can never reach `lowerBuiltinOrStaticCall`'s `funcName == "print"`
// codegen arm with a non-`String` argument through type-checked Lyric
// source. That arm's `normalizeUnsignedPrintArg` call is still fixed (it
// mirrors `println`'s arm exactly and would matter if `print`'s signature
// ever widens), but there is no reachable runtime case to assert here — a
// second `println` case below covers `ULong` instead, through the path
// that IS reachable.
test "println renders the unsigned decimal value for a ULong above 2^63 (#6754 finding 1.1)" {
  deleteFile(printCapturePath)
  val capture = JPS.new(printCapturePath)
  JSys.setOut(capture)
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  println(a)
  capture.flush()
  JSys.setOut(JPS.new("/dev/stdout"))
  val content = match readText(printCapturePath) { case Ok(s) -> s; case Err(_) -> "<read failed>" }
  deleteFile(printCapturePath)
  assertEqual(content, "9223372036854775811\n", "println(ULong) must render the unsigned decimal; got: " + content)
}

// ── isUnsignedExpr widening (#6754 finding 1.2) ────────────────────────────────
//
// `isUnsignedExpr` was purely syntactic: only a bare name previously
// recorded in `unsignedVars`, or a `u32`/`u64`-suffixed literal, reported
// `true`. A `UInt`/`ULong`-returning function CALL, or an indexed read off
// a declared `slice[UInt]`/`slice[ULong]`, silently reverted to signed
// codegen for that one expression.
func bigUIntValue(): UInt {
  3000000000u32
}

test "isUnsignedExpr recognizes a UInt-returning function call (#6754 finding 1.2a)" {
  val threshold: UInt = 1000000000u32
  assertTrue(bigUIntValue() > threshold, "bigUIntValue() > threshold must be unsigned-compared")
  assertFalse(bigUIntValue() < threshold, "bigUIntValue() < threshold must be false (unsigned)")
  assertEqual(bigUIntValue().toString(), "3000000000", "toString() on a UInt-returning call result is unsigned")
}

test "isUnsignedExpr recognizes an indexed read from a declared slice[UInt] (#6754 finding 1.2c)" {
  val xs: slice[UInt] = [3000000000u32, 1000000000u32]
  val threshold: UInt = 1000000000u32
  assertTrue(xs[0] > threshold, "xs[0] > threshold must be unsigned-compared")
  assertFalse(xs[0] < threshold, "xs[0] < threshold must be false (unsigned)")
  assertEqual(xs[0].toString(), "3000000000", "toString() on an indexed UInt element is unsigned")
}

// ── unsignedVars scope save/restore (#6754 finding 2) ──────────────────────────
//
// `recordUnsignedVarTy` only ever ADDED an entry to `ctx.unsignedVars`; it
// never evicted one for a non-unsigned rebind, and the map was never
// threaded through the block-scope undo log `slots`/`types` already use
// (#5191). A `UInt` shadowed by a plain `Int` of the same name inside a
// nested block kept the OUTER unsigned tracking for the INNER (signed)
// value — and a naive fix that only added eviction, without also
// scope-restoring, would then leak the eviction past the block, losing the
// OUTER `UInt` binding's own unsigned tracking once the block exits. This
// case exercises both directions in one A/B-verified test.
test "unsignedVars scope-undo: nested Int shadow is signed, outer UInt survives the block (#6754 finding 2)" {
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

// ── ctx.varGenericArgs scope save/restore (issue #6759, a SIBLING bug in the
//    same class, unrelated to UInt/ULong) ──────────────────────────────────
//
// A code-review pass on #6754 found the exact same "never scope-restored"
// shape in a DIFFERENT `Jvm.Codegen.FuncCtx` map: `ctx.varGenericArgs`
// (`String -> List[TypeExpr]`, the declared/inferred generic-instantiation
// registry `scrutineeGenericArgs`/`indexedElemTypeOverride` consult so a
// `match`/indexed read on a variable recovers its erased payload's real
// type). Every mutation site (`recordVarGenericArgs`,
// `recordParamGenericArgs`, `recordDeclaredElemType`, and the two
// match-arm field-binding sites in `lowerPatternBind`) used a bare
// remove-then-add with no scope awareness at all — a nested block/`if`
// binding that shadowed an outer name with a DIFFERENT (or no) generic
// instantiation permanently overwrote the outer entry; once the block
// exited, the outer binding's own `match` no longer recovered ITS args.
// Fixed with the identical `unsignedUndo`-shaped mechanism above, applied
// to this map (`FuncCtx.varGenericArgsUndo` / `VarGenericArgsUndo`,
// replayed by the same `exitBlockScope`). This is genuinely NOT a proxy
// assertion: before the fix, this exact shape threw a real
// `ClassCastException` (`Integer cannot be cast to String`) at runtime —
// the OUTER `Result[Int, String]` binding's `match` incorrectly reused the
// INNER shadow's `Result[String, String]` args to `checkcast` an `Ok`
// payload that was actually a boxed `Integer`.
func makeIntResultUnrelatedToUint(): Result[Int, String] {
  Ok(value = 5)
}

func makeStrResultUnrelatedToUint(): Result[String, String] {
  Ok(value = "hi")
}

test "varGenericArgs scope-undo: inner Result[String,String] shadow doesn't corrupt the outer Result[Int,String]'s match (#6759)" {
  val r = makeIntResultUnrelatedToUint()
  val enterShadow = true
  if enterShadow {
    val r = makeStrResultUnrelatedToUint()
    match r {
      case Ok(s) -> assertEqual(s, "hi", "the INNER shadow r unboxes as its own Result[String,String]")
      case Err(_) -> assertTrue(false, "inner r must be Ok")
    }
  }
  match r {
    case Ok(n) -> assertEqualInt(n + 1, 6, "the OUTER r is still Result[Int,String] after the shadowing block exits")
    case Err(_) -> assertTrue(false, "outer r must be Ok")
  }
}
