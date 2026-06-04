//! benchmarks/bench_numeric.l — numeric kernel benchmarks.
//!
//! Measures tight arithmetic loops on Int and Double values.
//! Covers the core operations that matter for inner-loop code:
//!   * Integer summation loop         (add, branch, counter)
//!   * Integer multiply-accumulate    (mul + add)
//!   * GCD (Euclidean, mixed ops)
//!   * Double floating-point loop     (reveals Float vs Int codegen delta)
//!   * Fibonacci (recursive, small N)
//!
//! Run with: lyric bench benchmarks/bench_numeric.l
//!
//! Int in Lyric is a 32-bit signed integer with overflow-checked arithmetic.
//! Loop bounds are chosen so no accumulator exceeds 2^31 - 1.
@bench_module
package Bench.Numeric

import Std.Core
import Std.Time

// ─── Integer sum ─────────────────────────────────────────────────────────────
// Sum 0..65535 = 2,147,450,880 which fits in Int.
@bench
pub func benchIntSum(): Unit {
  var acc = 0
  var i = 0
  while i < 65536 {
    acc = acc + i
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

// ─── Multiply-accumulate ──────────────────────────────────────────────────────
// Sum of i^2 for i in 1..1000 = 333,833,500 which fits in Int.
@bench
pub func benchIntMulAcc(): Unit {
  var acc = 0
  var i = 1
  while i <= 1000 {
    acc = acc + i * i
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

// ─── Integer GCD (Euclidean) ──────────────────────────────────────────────────
func gcd(a: in Int, b: in Int): Int {
  var x = a
  var y = b
  while y != 0 {
    val t = y
    y = x - (x / y) * y
    x = t
  }
  x
}

@bench
pub func benchGcd(): Unit {
  var result = 0
  var i = 1
  while i <= 10000 {
    result = gcd(result + i * 97 + 7, i * 89 + 3)
    i = i + 1
  }
  if result < 0 {
    println(toString(result))
  }
}

// ─── Double floating-point loop ───────────────────────────────────────────────
@bench
pub func benchDoubleSum(): Unit {
  var acc = 0.0
  var i = 0
  while i < 1000000 {
    acc = acc + 1.0
    i = i + 1
  }
  if acc < 0.0 {
    println(toString(acc))
  }
}

// ─── Fibonacci (recursive, small N) ──────────────────────────────────────────
func fib(n: in Int): Int {
  if n <= 1 {
    return n
  }
  fib(n - 1) + fib(n - 2)
}

@bench
pub func benchFibRecursive(): Unit {
  val result = fib(30)
  if result < 0 {
    println(toString(result))
  }
}
