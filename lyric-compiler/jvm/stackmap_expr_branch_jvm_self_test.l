//! stackmap_expr_branch_jvm_self_test.l — runtime regression suite for
//! #6346/#6356: a branch-lowered SUBexpression (comparison, `and`/`or`,
//! if-expression) evaluated while an ENCLOSING expression holds operands on
//! the operand stack.  Before the frame-pass stack simulation (B5c in
//! `lowering.l`), every branch-target StackMapTable frame declared an EMPTY
//! operand stack, so these shapes failed class loading with
//! "VerifyError: Inconsistent stackmap frames at branch target" — the
//! lyric-mcp `Mcp.Server.handleInitialize` class (a comparison in
//! call-argument position after earlier arguments were already stacked).
//! The list/tuple cases additionally pin the `LAstoreAs` receiver-slot
//! typing (an `ArrayList` receiver reloaded across a branchy element's
//! frame must be framed as `ArrayList`, not `Object`).
//!
//! Run in CI via native `lyric test --target jvm` (the shapes are
//! target-portable; the JVM run is the load-bearing one).
@test_module
package Lyric.StackmapExprBranchSelfTest

import Std.Core
import Std.Testing

func take3(a: in String, b: in Bool, c: in Bool): String {
  if b and c {
    a + "-yes"
  } else {
    a + "-no"
  }
}

record Flagged {
  tag: String
  flag: Bool
}

test "comparison in call-argument position after stacked arguments (#6346)" {
  val n = 3
  assertEqual(take3("x", n > 2, n > 1), "x-yes", "both comparisons true")
  assertEqual(take3("y", n > 5, n > 1), "y-no", "first comparison false")
}

test "comparison in constructor-argument position (#6346)" {
  val n = 3
  val p = Flagged(tag = "t", flag = n > 2)
  assertTrue(p.flag, "ctor-arg comparison true")
  val q = Flagged(tag = "u", flag = n > 5)
  assertFalse(q.flag, "ctor-arg comparison false")
}

test "boolean and/or in call-argument position (#6346)" {
  val n = 3
  assertEqual(take3("a", n > 0 and n < 10, true), "a-yes", "and in arg position")
  assertEqual(take3("b", n > 5 or n < 1, true), "b-no", "or in arg position, false")
}

test "if-expression in call-argument position (#6346)" {
  val n = 3
  assertEqual(take3("c", if n > 2 { true } else { false }, true), "c-yes", "if-expr arg")
}

test "branchy operand of arithmetic (#6346)" {
  val n = 3
  val k = 1 + (if n > 2 { 10 } else { 20 })
  assertEqualInt(k, 11, "lhs stacked while rhs if-expr branches")
}

test "branchy element in a list literal (#6346)" {
  val n = 3
  val xs: slice[Bool] = [n > 1, n > 5]
  assertEqualInt(xs.length, 2, "two elements")
  assertTrue(xs[0], "first element true")
  assertFalse(xs[1], "second element false")
}

test "branchy element in a tuple (#6346)" {
  val n = 3
  val t = (n > 2, "k")
  match t {
    case (b, s) -> {
      assertTrue(b, "tuple first element from comparison")
      assertEqual(s, "k", "tuple second element")
    }
  }
}

test "branchy operand of string concatenation (#6346)" {
  val n = 3
  assertEqual("n>2=" + toString(n > 2), "n>2=true", "concat with comparison operand")
}

test "nested: comparison inside an inner call's argument list (#6346)" {
  val n = 3
  assertEqual(take3(take3("i", n > 2, true), n > 1, true), "i-yes-yes", "inner call arg branches under outer args")
}

// #6578: `val (a, b): (T1, T2) = match { ... }` destructuring a tuple whose
// two match arms build it via DIFFERENTLY-shaped expressions (one arm a
// block with an intermediate `val` then a trailing tuple literal, the other
// a bare inline tuple literal). `lowerLocalPatBind`'s `PTuple` fallback
// always bound each element as `Object` — ignoring the `(JStringBuilder,
// String)` annotation entirely — so a later use of the extern-typed element
// (`sb.append(...)`) emitted no `checkcast` and the StackMapTable's local
// slot stayed typed `java/lang/Object`: `VerifyError: Bad type on operand
// stack` at that later use. Fixed by resolving each element against the
// annotation's own tuple element type when the arities line up.
extern type JStringBuilder = "java.lang.StringBuilder"

func buildFromBlock(): JStringBuilder {
  val sb = JStringBuilder.new()
  sb.append("A")
  sb
}

func buildInline(): JStringBuilder {
  JStringBuilder.new()
}

test "tuple destructuring with an extern-typed element across divergent match-arm shapes (#6578)" {
  val cond = true
  val (sb, tag): (JStringBuilder, String) = match cond {
    case true -> {
      val x = buildFromBlock()
      (x, "block-arm")
    }
    case false -> (buildInline(), "inline-arm")
  }
  sb.append("Z")
  assertEqual(sb.toString(), "AZ", "destructured extern-typed element usable without a VerifyError")
  assertEqual(tag, "block-arm", "second tuple element correctly bound")
}
