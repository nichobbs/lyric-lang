//! alias_impl_self_test.l — regression for #3673.
//!
//! An interface-impl method whose signature names a type alias (`alias Sid =
//! String`) must match the interface slot it implements (`func make(): String`).
//! The MSIL emitter previously lowered the alias to a bogus `MClass("…Sid")`
//! instead of resolving it to the underlying `String`, so the impl method's
//! signature didn't match the slot and the loader rejected the type with
//! "Method 'make' ... does not have an implementation" (TypeLoadException) the
//! moment the record was constructed.
//!
//! Run in CI via native `lyric test` on the dotnet target; imports only `Std.*`.
//! Not wired for `--target jvm`: the JVM backend has a separate, pre-existing
//! interface-dispatch gap ("Found interface ..., but class was expected") that
//! fails this shape with or without the alias — tracked in #3687.
@test_module
package AliasImplSelfTest

import Std.Core
import Std.Testing

alias Sid = String

interface Store {
  func make(): String
}

record M {
  var n: Int
}

impl Store for M {
  func make(): Sid {
    return "made"
  }
}

// Constructing M loads the type; without alias resolution the loader rejected M
// because its `make` slot looked unimplemented (Sid != String).
test "interface impl method typed with an alias-to-primitive loads and runs (#3673)" {
  val m = M(n = 0)
  assertEqual(m.make(), "made", "alias-typed impl method returns through the interface slot")
}

// Calling through an interface-typed binding exercises the virtual slot directly.
func callThroughStore(s: in Store): String {
  return s.make()
}

test "alias-typed impl method dispatches through the interface slot (#3673)" {
  val m = M(n = 1)
  assertEqual(callThroughStore(m), "made", "virtual dispatch reaches the alias-typed impl")
}
