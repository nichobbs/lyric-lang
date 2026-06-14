//! self_method_call_jvm_self_test.l — JVM regression test for intra-impl
//! `self.m()` / bare `m()` dispatch (#1722, JVM parity for MSIL D-progress-355).
//!
//! Before this fix, `impl T for X` methods were lowered as STATIC functions on the
//! target class (`lowerFunc`, flags 0x0009).  A call `obj.m(args)` lowered to
//! `invokevirtual X.m` (J3 `<class>#<method>` registry), but no registry entry
//! existed for impl methods so the call fell through to the `()Object` guess, which
//! mismatches the static descriptor and causes a JVM VerifyError.  Inside the impl
//! body, bare `m()` resolved to the static host class (wrong owner) and `self.m()`
//! tried `invokevirtual` on the object registry key — both missing.
//!
//! The fix:
//!   • `lowerImplMethod` emits impl methods as true instance methods
//!     (slot 0 = `this`, `selfClass = Some(targetClass)`, flags 0x0001).
//!   • `collectFileSigs` registers `<targetClass>#<method>` for each `IMplFunc`.
//!   • `lowerGeneralStaticCall` checks `ctx.selfClass + "#" + funcName` before the
//!     static-method lookup, emitting `aload_0; invokevirtual` for bare `m()`.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/self_method_call_jvm_self_test.l
@test_module
package Lyric.SelfMethodCallJvmSelfTest

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
  func viaSelfArg(s: in String): String
  func viaSelfIntArg(n: in Int): Int
}

record Impl {
  tag: Int
}

impl Svc for Impl {
  func base(): Int {
    return 42
  }
  func viaSelf(): Int {
    self.base()
  }
  func viaBare(): Int {
    base()
  }
  func echo(s: in String): String {
    return s + s
  }
  func viaBareArg(s: in String): String {
    echo(s)
  }
  func twice(n: in Int): Int {
    return n + n
  }
  func viaBareIntArg(): Int {
    twice(5)
  }
  func save(): Result[Unit, SErr] {
    return Ok(())
  }
  func putSelf(): Result[Unit, SErr] {
    self.save()
  }
  func putBare(): Result[Unit, SErr] {
    save()
  }
  func viaSelfArg(s: in String): String {
    self.echo(s)
  }
  func viaSelfIntArg(n: in Int): Int {
    self.twice(n)
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

test "self.m(String arg) dispatches correctly via lowerMethodCall (#3563)" {
  assertEqual(mk().viaSelfArg("ab"), "abab", "self.echo(\"ab\")")
}

test "self.m(Int arg) dispatches correctly via lowerMethodCall (#3563)" {
  assertEqualInt(mk().viaSelfIntArg(7), 14, "self.twice(7)")
}
