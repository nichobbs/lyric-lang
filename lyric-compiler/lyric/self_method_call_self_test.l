//! Intra-impl method call regression (self.m / bare m); see D-progress-355.
@test_module
package Lyric.SelfMethodCallSelfTest

import Std.Core
import Std.Testing

record SErr {
  code: String
}

interface Svc {
  func base(): Int
  func viaSelf(): Int
  func viaBare(): Int
  func echo(s: in String): String
  func viaBareArg(s: in String): String
  func twice(n: in Int): Int
  func viaBareIntArg(): Int
  func save(): Result[Unit, SErr]
  func putSelf(): Result[Unit, SErr]
  func putBare(): Result[Unit, SErr]
}

record Impl {
  tag: Int
}

impl Svc for Impl {
  func base(): Int {
    return 42
  }
  func viaSelf(): Int {
    // Explicit `self.base()` must dispatch to base(), not return null/0.
    self.base()
  }
  func viaBare(): Int {
    // Bare `base()` (implicit self) must resolve the sibling method too.
    base()
  }
  func echo(s: in String): String {
    return s + s
  }
  func viaBareArg(
    // Bare sibling call passing an argument — exercises the arg-lowering loop.
    s: in String,
  ): String {
    echo(s)
  }
  func twice(n: in Int): Int {
    return n + n
  }
  func viaBareIntArg(): Int {
    // Bare sibling call with a VALUE-TYPE argument: the arg must stay an
    // unboxed int32 — boxing it mismatches twice's declared `int32` parameter
    // and the JIT rejects the body (InvalidProgramException, #1723).
    twice(5)
  }
  func save(): Result[Unit, SErr] {
    return Ok(())
  }
  func putSelf(): Result[Unit, SErr] {
    // The returned Result must be the value save() built, not a dropped call.
    self.save()
  }
  func putBare(): Result[Unit, SErr] {
    save()
  }
}

func mk(): Impl {
  return Impl(tag = 0)
}

func classify(r: in Result[Unit, SErr]): Int {
  match r {
    case Err(_) -> 0
    case Ok(_) -> 1
  }
}

test "self.base() returns the method result" {
  assertEqualInt(mk().viaSelf(), 42, "self.base()")
}

test "bare base() resolves the sibling method" {
  assertEqualInt(mk().viaBare(), 42, "bare base()")
}

test "bare sibling call with an argument lowers the arg" {
  assertEqual(mk().viaBareArg("ab"), "abab", "bare echo(\"ab\")")
}

test "bare sibling call with an Int argument does not box" {
  assertEqualInt(mk().viaBareIntArg(), 10, "bare twice(5)")
}

test "self.save() returns the constructed Result, matches Ok" {
  assertEqualInt(classify(mk().putSelf()), 1, "self.save() -> Ok")
}

test "bare save() returns the constructed Result, matches Ok" {
  assertEqualInt(classify(mk().putBare()), 1, "bare save() -> Ok")
}

// #6489: a BARE call inside an instance method body where BOTH a same-named
// free function and a sibling method exist must resolve the sibling method
// (method-wins) — the JVM backend and the type checker's member-callee
// fallback (#1722/#6435) always did; MSIL resolved the free function until
// #6489 gated its `resolvedFqn` resolution on the bare-sibling hit.
func probe(): Int {
  1
}

func freeOnly(): Int {
  41
}

record ShadowHolder {
  n: Int
  func probe(): Int {
    2
  }
  func viaBareShadowed(): Int {
    probe()
  }
  func viaBareFree(): Int {
    freeOnly()
  }
}

test "bare call shadowed by a sibling method resolves the method (#6489)" {
  val h = ShadowHolder(n = 0)
  assertEqualInt(h.viaBareShadowed(), 2, "method wins over the same-named free function")
}

test "bare call with no same-named sibling still resolves the free function (#6489)" {
  val h = ShadowHolder(n = 0)
  assertEqualInt(h.viaBareFree(), 41, "free function resolution unaffected when no sibling shadows it")
}
