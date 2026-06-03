// benchmarks/bench_string.l — string operation benchmarks.
//
// Measures allocation-heavy string patterns to surface the cost of
// Lyric's String (immutable CLR string) operations:
//
//   benchStringConcat     — repeated `acc + fragment` in a loop.
//   benchToString         — toString(Int) called N times.
//   benchStringLength     — s.length property access in a loop.
//   benchStringContains   — Str.contains substring check repeated N times.
//   benchStringReplace    — Str.replace on a fixed-size string repeated N times.
//
// String concatenation in a tight loop is the worst case for an immutable
// string model.  The intent is to compare the raw overhead between .NET and
// JVM targets, and to guide whether a `StringBuilder`-style stdlib type
// (Std.Text.Builder or similar) is warranted.
//
// Run with: lyric bench benchmarks/bench_string.l

@bench_module
package Bench.String

import Std.Core
import Std.String as Str
import Std.Time

// ─── Repeated concatenation ───────────────────────────────────────────────────

@bench
pub func benchStringConcat(): Unit {
  var acc = ""
  var i   = 0
  while i < 1000 {
    acc = acc + "x"
    i   = i + 1
  }
  if acc.length < 0 { println(acc) }
}

// ─── toString on Int ──────────────────────────────────────────────────────────

@bench
pub func benchToString(): Unit {
  var acc = ""
  var i   = 0
  while i < 10000 {
    acc = toString(i)
    i   = i + 1
  }
  if acc.length < 0 { println(acc) }
}

// ─── .length property ─────────────────────────────────────────────────────────

@bench
pub func benchStringLength(): Unit {
  val s = "Hello, Lyric! This is a fixed-length benchmark string."
  var acc = 0
  var i   = 0
  while i < 100000 {
    acc = acc + s.length
    i   = i + 1
  }
  if acc < 0 { println(toString(acc)) }
}

// ─── Std.String.contains ─────────────────────────────────────────────────────

@bench
pub func benchStringContains(): Unit {
  val haystack = "The quick brown fox jumps over the lazy dog"
  var found    = 0
  var i        = 0
  while i < 50000 {
    if Str.contains(haystack, "fox") { found = found + 1 }
    i = i + 1
  }
  if found < 0 { println(toString(found)) }
}

// ─── Std.String.replace ──────────────────────────────────────────────────────

@bench
pub func benchStringReplace(): Unit {
  val original = "aaabbbcccaaabbbccc"
  var acc = ""
  var i   = 0
  while i < 5000 {
    acc = Str.replace(original, "aaa", "ZZZ")
    i   = i + 1
  }
  if acc.length < 0 { println(acc) }
}
