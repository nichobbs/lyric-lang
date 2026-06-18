//! qualified_union_case_self_test.l — #3840: qualified union-case construction
//! on the self-hosted MSIL backend.
//!
//! Before this fix, `StoreError.UserNotFound(id = 7)` was parsed as
//! `EMember(EPath["StoreError"], "UserNotFound")` and `lowerMethodCallMsil`
//! treated it as a method call on the enum type rather than a constructor
//! call on the union case, producing the runtime error:
//!
//!   unsupported method 'UserNotFound' on the receiver type at this call
//!   site (no matching user method, extern binding, or built-in intrinsic)
//!
//! The fix detects qualified union-case calls in `lowerMethodCallMsil` and
//! routes them to `lowerBuiltinOrStaticCallMsil` with a synthetic EPath, so
//! they share the existing named-arg / default / generic-inference machinery.
//!
//! Run in CI via native `lyric test --target dotnet` (in-process through the
//! self-hosted `Msil.Bridge`).  Imports only `Std.*`.
@test_module
package Lyric.QualifiedUnionCaseSelfTest

import Std.Core
import Std.Testing

union StoreError {
  case UserNotFound(id: Long)
  case RoleNotFound(name: String)
  case Internal
}

// Second union with a same-named case ("Internal") to exercise qualifier
// disambiguation in `pickCaseFqnByQualifier`.
union NetError {
  case Timeout(ms: Int)
  case Internal
}

func storeMessage(e: StoreError): String {
  match e {
    case UserNotFound(id) -> "user " + toString(id)
    case RoleNotFound(name) -> "role " + name
    case Internal -> "store internal"
  }
}

func netMessage(e: NetError): String {
  match e {
    case Timeout(ms) -> "timeout " + toString(ms)
    case Internal -> "net internal"
  }
}

test "qualified union-case construction with named payload" {
  val e = StoreError.UserNotFound(id = 7i64)
  assertTrue(storeMessage(e) == "user 7", "StoreError.UserNotFound(id = 7)")
}

test "qualified union-case construction with positional payload" {
  val e = StoreError.RoleNotFound("admin")
  assertTrue(storeMessage(e) == "role admin", "StoreError.RoleNotFound(positional)")
}

test "qualified nullary case construction" {
  val e = StoreError.Internal
  assertTrue(storeMessage(e) == "store internal", "StoreError.Internal")
}

test "qualifier disambiguates same-named cases across unions" {
  val s = StoreError.Internal
  val n = NetError.Internal
  assertTrue(storeMessage(s) == "store internal", "StoreError.Internal picks StoreError")
  assertTrue(netMessage(n) == "net internal", "NetError.Internal picks NetError")
}

test "qualified case construction with named payload disambiguates" {
  val n = NetError.Timeout(ms = 250)
  assertTrue(netMessage(n) == "timeout 250", "NetError.Timeout(ms = 250)")
}
