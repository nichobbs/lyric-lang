//! iface_slice_arg_self_test.l — regression test for #6369: a list-literal
//! argument passed to an INTERFACE (or record) method whose parameter is a
//! `slice[T]` must be emitted as a real `T[]`, not a `List<object>`.
//!
//! Before the fix, `lowerMethodCallMsil`'s per-argument loop only pushed the
//! callee's expected parameter type for `MConcreteMap` parameters; every other
//! parameter type (notably `slice[T]` → `MArray`) fell through with no
//! expectation.  A list literal whose elements aren't bare literals/names —
//! e.g. `["a", n.toString()]`, an `EBinop`/call expression that
//! `inferHomogeneousListElemTypeMsil` cannot type — then took `EList`'s
//! no-hint fallback and built a `List<object>`, while the interface slot's
//! signature still declared `string[]`.
//!
//! The CLR accepts that call (both operands are object references), so this
//! was a SILENT miscompile: the callee's `params.length` / `params[i]` read
//! the `List<object>` instance at array-layout offsets, returning garbage.
//! Symptoms were nondeterministic and load-dependent — `IndexOutOfRange`
//! and `OverflowException` surfacing only after enough heap churn — which is
//! how it was originally mis-filed as an Npgsql connection-pool defect
//! (#6359): lyric-db's `DbConnection.query/execute(sql, params)` take exactly
//! this shape, so every parameterised query through the public interface was
//! passing a malformed array.
//!
//! The free-function path (`lowerBuiltinOrStaticCallMsil`) always pushed the
//! expectation, which is why the same call went from broken to correct just by
//! being routed through a free function instead of an interface method.
//!
//! Runs on both targets via native `lyric test`.  Imports only `Std.*`.
@test_module
package Lyric.IfaceSliceArgSelfTest

import Std.Core
import Std.Testing

interface Sink {
  func take(label: in String, xs: in slice[String]): Int
  func takeInts(xs: in slice[Int]): Int
}

record CountingSink {
  bump: Int
}

impl Sink for CountingSink {
  // Reads BOTH the length and every element, so a malformed array shows up
  // either as a wrong count or as an out-of-range/overflow throw.
  func take(label: in String, xs: in slice[String]): Int {
    var total = label.length
    var i = 0
    while i < xs.length {
      total = total + xs[i].length
      i = i + 1
    }
    return total + self.bump
  }

  func takeInts(xs: in slice[Int]): Int {
    var total = 0
    var i = 0
    while i < xs.length {
      total = total + xs[i]
      i = i + 1
    }
    return total + self.bump
  }
}

// A free function taking the same shape — this path always worked, and pins
// that the interface path now agrees with it.
func takeFree(label: in String, xs: in slice[String]): Int {
  var total = label.length
  var i = 0
  while i < xs.length {
    total = total + xs[i].length
    i = i + 1
  }
  return total
}

test "#6369: non-inferable list literal passed to an interface method keeps its length" {
  val s: Sink = CountingSink(bump = 0)
  val n = 7
  // Elements are EBinop/call expressions, so element-type inference can't
  // type them — exactly the shape that used to fall back to List<object>.
  // "ab"=2, "item7"=5, "7"=1
  assertEqualInt(s.take("ab", ["item" + n.toString(), n.toString()]), 8, "two-element slice arg")
}

test "#6369: interface and free-function paths agree on the same literal" {
  val s: Sink = CountingSink(bump = 0)
  val n = 42
  val viaIface = s.take("k", ["v" + n.toString(), n.toString()])
  val viaFree = takeFree("k", ["v" + n.toString(), n.toString()])
  assertEqualInt(viaIface, viaFree, "interface arg lowering matches free-function arg lowering")
}

test "#6369: single-element non-inferable literal through an interface method" {
  val s: Sink = CountingSink(bump = 0)
  val n = 5
  assertEqualInt(s.take("", [n.toString()]), 1, "one-element slice arg")
}

test "#6369: empty literal through an interface method" {
  val s: Sink = CountingSink(bump = 0)
  val empty: slice[String] = []
  assertEqualInt(s.take("xy", empty), 2, "empty slice arg")
}

test "#6369: Int-element literal through an interface method" {
  val s: Sink = CountingSink(bump = 0)
  val n = 3
  assertEqualInt(s.takeInts([n + 1, n * 2]), 10, "Int slice arg keeps element values")
}

test "#6369: repeated interface calls stay correct across many allocations" {
  // The original defect only surfaced after enough heap churn shifted what
  // the misread object's memory contained, so drive the same call many times
  // and assert every result rather than just the first.
  val s: Sink = CountingSink(bump = 1)
  var i = 0
  var bad = 0
  while i < 2000 {
    val got = s.take("z", ["e" + i.toString(), i.toString()])
    val want = 1 + (1 + i.toString().length) + i.toString().length + 1
    if got != want {
      bad = bad + 1
    }
    i = i + 1
  }
  assertEqualInt(bad, 0, "2000 interface calls with list-literal args all correct")
}
