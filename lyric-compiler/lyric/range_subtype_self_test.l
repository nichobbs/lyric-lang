//! range_subtype_self_test.l — executable regression test for distinct- and
//! range-subtype construction in the **self-hosted** MSIL backend (#1501).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: those
//! `_tests.l` files are compiled and run by the **F# stage-0** emitter, which
//! has always synthesised the distinct/range construction API (`from`,
//! `tryFrom`, `toInt`).  The self-hosted `Msil.Bridge` did not — a
//! `Type.from(x)` / `Type.tryFrom(x)` / `value.toInt()` call compiled to invalid
//! IL (InvalidProgramException at run time), and range bounds were dropped
//! entirely (`rangeClause` was never read by the emitter).  This file is run by
//! native `lyric test`, which compiles it in-process through the self-hosted
//! pipeline (lexer → parser → type-checker → mode-checker → codegen → MSIL PE)
//! and executes it, so it exercises the path the `_tests.l` files cannot.
//!
//!   lyric test lyric-compiler/lyric/range_subtype_self_test.l
//!
//! Consumption uses `match` rather than the `isOk`/`isErr` stdlib helpers: a
//! generic stdlib function applied to a `Result` over a *user* type still
//! erases its type arguments in the self-hosted backend (the cross-package
//! generic-function monomorphization gap, #1498), which is orthogonal to the
//! construction API this test covers.  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
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

// ─────────────────────────────────────────────────────────────────────────────
// Plain distinct types (no range) get the same construction/projection API.
// ─────────────────────────────────────────────────────────────────────────────
test "plain distinct type constructs and projects" {
  assertEqualInt(UserId.from(42).toInt(), 42, "UserId.from(42).toInt()")
  assertEqualInt(UserId.from(0).toInt(), 0, "UserId.from(0).toInt()")
}
