//! benchmarks/bench_contracts.l — contract overhead benchmarks.
//!
//! Measures the cost of `@runtime_checked` contract elaboration (requires /
//! ensures asserts) versus plain functions.  This is the key signal for
//! deciding whether to strip contracts in release builds.
//!
//! All three variants perform the same arithmetic work so differences in
//! timing isolate the assertion overhead:
//!
//!   benchPlain         — no contracts, no annotations.
//!   benchRuntimeChecked — @runtime_checked requires: + ensures: on every call.
//!   benchAxiom         — @axiom skips assertion injection entirely.
//!
//! Because the bootstrap emitter still injects runtime checks via exit-label
//! routing (not the self-hosted contract elaborator), the delta between
//! benchPlain and benchRuntimeChecked reflects the raw overhead of the
//! requires / ensures assert branches, not elaborator compile time.
//!
//! Run with: lyric bench benchmarks/bench_contracts.l
@bench_module
package Bench.Contracts

import Std.Core
import Std.Time

// ─── Shared kernel: integer clamp ─────────────────────────────────────────────
// Plain, no contracts.
func clampPlain(x: in Int, lo: in Int, hi: in Int): Int {
  if x < lo {
    return lo
  }
  if x > hi {
    return hi
  }
  x
}

// Runtime-checked variant — requires: + ensures: on every call.
@runtime_checked
func clampChecked(x: in Int, lo: in Int, hi: in Int): Int
  requires: lo <= hi
  ensures: result >= lo and result <= hi
{
  if x < lo {
    return lo
  }
  if x > hi {
    return hi
  }
  x
}

// Axiom variant — body verified once at declaration; no runtime checks.
@axiom("clampAxiom satisfies lo<=hi by construction")
func clampAxiom(x: in Int, lo: in Int, hi: in Int): Int {
  if x < lo {
    return lo
  }
  if x > hi {
    return hi
  }
  x
}

// ─── Benchmarks ───────────────────────────────────────────────────────────────
@bench
pub func benchPlain(): Unit {
  var acc = 0
  var i = 0
  while i < 10000 {
    acc = acc + clampPlain(i, 10, 9990)
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

@bench
pub func benchRuntimeChecked(): Unit {
  var acc = 0
  var i = 0
  while i < 10000 {
    acc = acc + clampChecked(i, 10, 9990)
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

@bench
pub func benchAxiom(): Unit {
  var acc = 0
  var i = 0
  while i < 10000 {
    acc = acc + clampAxiom(i, 10, 9990)
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}
