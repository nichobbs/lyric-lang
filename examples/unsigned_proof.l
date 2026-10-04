@proof_required(checked_arithmetic)
package UnsignedProof

// Demonstrates how the verifier models unsigned integers, the signed
// minimum literals and signed division.  Run with:
//
//     lyric prove examples/unsigned_proof.l --verbose
//
// `UInt`, `ULong` and `Byte` are bitvectors of their width: a literal next to
// one becomes a bitvector constant, ordering, division and remainder are
// unsigned, and `checked_arithmetic` proves that no `+`, `-` or `*` wraps.
// Signed `/` and `%` truncate toward zero, as they do at runtime.
// Every obligation needs an SMT solver (z3 or cvc5).
// Unsigned ordering: 3000000000 and 2147483648 are above Int's sign bit.
pub func high(x: UInt): UInt
  requires: x > 3000000000
  ensures: result >= 2147483648
  = x

// A range over the upper half of ULong; its bounds are unsigned.
pub func upper(x: ULong range 9223372036854775808u64 ..= 18446744073709551615u64): ULong
  ensures: result > 9223372036854775807u64
  = x

// Unsigned division and remainder of the largest UInt.
pub func halfMax(x: UInt): UInt
  requires: x == 4294967295
  ensures: result == 2147483647
  = x / 2

pub func lastDigit(x: UInt): UInt
  requires: x == 4294967295
  ensures: result == 5
  = x % 10

// UInt widens to ULong by zero-extension, so the sum does not wrap.
pub func widened(a: UInt, b: ULong): ULong
  requires: a == 4294967295 and b == 1
  ensures: result == 4294967296
  = a + b

// Checked arithmetic: the precondition rules out the wrap.
pub func increment(x: UInt): UInt
  requires: x < 4294967295
  ensures: result > x
  = x + 1

// The signed minimum literals are one negative constant.
pub func longMin(): Long
  ensures: result < 0
  = -9223372036854775808

pub func intMin(): Int
  ensures: result == 0 - 2147483647 - 1
  = -2147483648i32

// Signed division truncates toward zero and the remainder takes the
// dividend's sign, as at runtime: -7 / 2 is -3 and -7 % 2 is -1, not the
// Euclidean -4 and 1.  A signed `/` or `%` must also never divide the
// type's minimum by -1, which traps in every build profile.
pub func halveNegative(x: Int): Int
  requires: x == -7
  ensures: result == -3
  = x / 2

pub func negativeRemainder(x: Long, d: Long): Long
  requires: x < 0 and d != 0 and d != -1
  ensures: result <= 0
  = x % d
