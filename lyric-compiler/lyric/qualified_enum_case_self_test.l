//! qualified_enum_case_self_test.l — #5769: JVM parity for package-qualified
//! enum-case value references.
//!
//! #5737/#5768 fixed a package-qualified enum-case reference (`Std.Http.GET`
//! — package `Std.Http`, case `GET` of `HttpMethod`; Lyric enum cases are
//! referenced through their declaring PACKAGE, never an explicit
//! `<EnumType>.` segment) on MSIL: `tryQualifiedEnumOrdinalMsil` fell through
//! to the `EMember` arm's union-case-construction heuristic whenever the
//! trailing package segment collided with an unrelated union's case name,
//! mis-resolving and emitting invalid IL. `enum_msil_self_test.l` pins the
//! MSIL fix (`--target dotnet` only).
//!
//! #5769 traced the JVM backend's equivalent lowering (`jvm/codegen/02_exprs.l`
//! `EMember` arm) and found it only special-cased a receiver that is a bare
//! `EPath` (single segment) — a 3-segment reference like `Std.Http.GET`
//! (whose immediate receiver `Std.Http` is itself an `EMember`, not a bare
//! `EPath`) recursed into evaluating `Std` alone as a value and hit the
//! "reference resolves to no local/param/..." compile-time panic. Fixed by
//! adding `flattenPathExprSegsJvm`/`tryQualifiedEnumClassJvm`
//! (`jvm/codegen/01_types.l`, mirroring MSIL's `flattenPathExprSegs`/
//! `tryQualifiedEnumOrdinalMsil`) and a package-qualified `"enum:" + <dotted
//! package> + "." + <case>` registration key alongside the existing
//! type-scoped `"enum:" + <EnumType> + "." + <case>` key
//! (`jvm/codegen/06_items.l`'s `IEnum` registration).
//!
//! This test exercises the SAME real-world repro as `enum_msil_self_test.l`'s
//! `#5737` case (`Std.Http.GET`, a genuine stdlib enum bundled alongside user
//! code the same way on both targets).
//!
//! #5845 closed the sibling gap noted above: a fully-qualified FREE-FUNCTION
//! call whose callee has a multi-segment package prefix (`Std.Http.request(
//! ...)` — package `Std.Http`, function `request`) also parses with a
//! nested-`EMember` receiver (`EMember(EMember(EPath["Std"], "Http"),
//! "request")`), which `lowerMethodCall` (`jvm/codegen/04_calls.l`) did not
//! flatten before falling through to `lowerExpr` on the receiver — evaluating
//! the package prefix `Std.Http` as a VALUE panics ("reference 'Std' resolves
//! to no local, ..."). Fixed by flattening the receiver via the existing
//! `flattenPathExprSegsJvm` (#5769) and, when `<prefix>/<member>` names a
//! registered free function in `ctx.funcSigs`, routing to the static-call
//! lowering (`lowerBuiltinOrStaticCall`) instead — mirroring MSIL's
//! `flattenPathExprSegs` fix in `lowerMethodCallMsil` (#3332).
//!
//! Run in CI via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target dotnet` through `Msil.Bridge` (already
//! covered by `enum_msil_self_test.l`'s equivalent case, but exercised again
//! here for a single shared regression file), `--target jvm` through
//! `Jvm.Bridge` `compileToJarBundled`. Imports only `Std.*`.
@test_module
package Lyric.QualifiedEnumCaseSelfTest

import Std.Core
import Std.Http
import Std.Testing

enum Color {
  case Red
  case Green
  case Blue
}

func colorName(c: in Color): String {
  match c {
    case Red -> "red"
    case Green -> "green"
    case Blue -> "blue"
  }
}

// A second, unrelated union whose case name collides with a package segment
// of the qualified reference below (`Std.Rest.RestError.Http` vs.
// `Std.Http.GET`) — the exact #5737 collision shape, reproduced in-bundle so
// this test does not depend on `Std.Rest` itself.
union LocalError {
  case Http(code: Int)
  case Other(message: String)
}

func describeLocalError(e: in LocalError): String {
  match e {
    case Http(code) -> "http:" + code.toString()
    case Other(message) -> "other:" + message
  }
}

test "package-qualified enum case (in-bundle) resolves and matches" {
  val c = Color.Red
  assertEqual(colorName(c), "red", "Color.Red as bare qualified value")
  assertEqual(colorName(Color.Green), "green", "Color.Green as arg")
}

test "package-qualified enum case does not collide with an unrelated union case name" {
  val e = Http(code = 404)
  assertEqual(describeLocalError(e), "http:404", "Http(...) union construction unaffected")
}

// #5737/#5769: `Std.Http.GET` is a PACKAGE-qualified enum-case reference
// (package `Std.Http`, case `GET` of `HttpMethod`) — three segments, whose
// immediate receiver (`Std.Http`) is itself a two-segment path, not a bare
// single-segment `EPath`.
test "#5737/#5769: Std.Http.GET (package-qualified stdlib enum case) resolves on both targets" {
  val m = Std.Http.GET
  match m {
    case GET -> assertTrue(true, "Std.Http.GET resolves to the enum value")
    case _ -> panic("Std.Http.GET resolved to the wrong case")
  }
  // Passed as a call argument to an ordinary, unqualified call.
  assertTrue(httpMethodIsGet(Std.Http.GET), "Std.Http.GET as a qualified call argument")
}

func httpMethodIsGet(m: in HttpMethod): Bool {
  match m {
    case GET -> true
    case _ -> false
  }
}

// #5845: fully-qualified FREE-FUNCTION calls whose callee has a multi-segment
// package prefix (`Std.Http.request(...)`, `Std.Http.withHeader(...)`) — the
// call-form sibling of the #5769 enum-case-value fix above, now closed.
test "#5845: Std.Http.request(...) and Std.Http.withHeader(...) (fully-qualified free-function calls) resolve and run on both targets" {
  val u = match Url.tryFrom("http://example.com") {
    case Ok(value) -> value
    case Err(_) -> panic("test setup: Url.tryFrom(\"http://example.com\") unexpectedly failed")
  }
  // 2-argument fully-qualified call: `EMember(EMember(EPath["Std"], "Http"),
  // "request")` as the callee, receiver `Std.Http` itself an `EMember`, not a
  // bare `EPath` — the exact shape `lowerMethodCall` used to mis-lower.
  val req = Std.Http.request(Std.Http.GET, u)
  // 3-argument fully-qualified call on the resulting request — exercises a
  // second arity through the same qualified-call path.
  val _ = Std.Http.withHeader(req, "X-Test", "1")
  assertTrue(true, "Std.Http.request/withHeader (3-segment qualified free-function calls) executed without panicking")
}
