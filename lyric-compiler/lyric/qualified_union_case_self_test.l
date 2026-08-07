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
//!
//! Test 4 ("qualifier disambiguates same-named cases across unions") doubles
//! as the regression cover for #5982: on `--target jvm`,
//! `jvm/codegen/03_match.l`'s `PBinding` nullary-case branch resolved a bare
//! `case Internal ->` arm via the bundle-global `ctorClassFor` registry
//! without consulting the scrutinee's static union type, so it always tested
//! against whichever of `StoreError`/`NetError` registered `Internal` first —
//! surfacing as "match not exhaustive" when matching over the OTHER union's
//! value.  Fixed by `resolveBareCaseClassJvm`, which derives
//! `<scrutinee's own class>$Internal` first.  This file now runs on BOTH
//! `--target dotnet` and `--target jvm` in CI (the JVM step lives in the
//! `compiler-self-tests-jvm` job).
//!
//! Tests 6-7 (#6298) cover a QUALIFIED reference to a GENERIC nullary union
//! case in value position — `Option.None`, distinct from the plain
//! (non-generic) `StoreError.Internal` case above.  A generic nullary case
//! has no singleton instance (Q-GEN-001, docs/43) and must be constructed
//! via the TypeSpec-closing machinery (`buildGenericCaseCtorTok` for the
//! cross-assembly stdlib case, `buildInBundleGenericCtorTok` for an
//! in-bundle one); before the fix, the qualified EMember value-position arm
//! instead emitted a bare `newobj` against the case's OPEN generic
//! MemberRef, which crashed on `--target dotnet` with
//! `TypeLoadException: Could not load type 'Std.Core.Option_None`1'` —
//! sought in the CONSUMER assembly rather than the stdlib one.  The bare
//! (unqualified) `None` form already worked correctly and is unaffected by
//! this fix.
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

// In-bundle generic union with a nullary case, for contrast with the
// cross-assembly stdlib `Option[T]` case in the #6298 tests below.
union Maybe6298[T] {
  case Just6298(value: T)
  case Nothing6298
}

func maybeMessage6298(m: Maybe6298[Int]): String {
  match m {
    case Just6298(v) -> "just " + toString(v)
    case Nothing6298 -> "nothing"
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

test "#6298: qualified stdlib Option.None (cross-assembly generic nullary case)" {
  val n: Option[Int] = Option.None
  val msg = match n { case Some(v) -> "some " + toString(v); case None -> "none" }
  assertTrue(msg == "none", "Option.None")
}

test "#6298: qualified stdlib Option.Some still constructs alongside None" {
  val n: Option[Int] = Option.Some(value = 42)
  val msg = match n { case Some(v) -> "some " + toString(v); case None -> "none" }
  assertTrue(msg == "some 42", "Option.Some(value = 42)")
}

test "#6298: qualified in-bundle generic nullary case (Maybe6298.Nothing6298)" {
  val m: Maybe6298[Int] = Maybe6298.Nothing6298
  assertTrue(maybeMessage6298(m) == "nothing", "Maybe6298.Nothing6298")
}
