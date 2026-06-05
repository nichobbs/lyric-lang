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

test "self.save() returns the constructed Result, matches Ok" {
  assertEqualInt(classify(mk().putSelf()), 1, "self.save() -> Ok")
}

test "bare save() returns the constructed Result, matches Ok" {
  assertEqualInt(classify(mk().putBare()), 1, "bare save() -> Ok")
}
