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
//! #5943 closed the remaining member of this qualified-resolution family: a
//! package-qualified union-case CONSTRUCTOR call with args (`Std.Errors.
//! ParseError.InvalidFormat(input = ..., expected = ...)`, or the same-package
//! `AppError.Missing(id = ...)` / `Pkg.AppError.Missing(id = ...)` shapes) is
//! neither a registered free function (the #5845 probe) nor a nullary enum
//! value (#5769), so it fell through the SAME `lowerMethodCall` receiver-as-
//! value path and panicked identically. Fixed by adding a case-constructor
//! probe right after the #5845 free-function probe: flatten the receiver,
//! take its LAST segment as the parent union's simple name, and look up
//! `<Union>$<Case>` in the `ctors` registry that `collectFileCtors`'s
//! `IUnion` branch already populates for #4802 — reusing that single
//! registry instead of adding a new one. The non-call analog (a bare nullary
//! case VALUE reference with no parens, `AppError.Down`) parses as a plain
//! `EMember`, never reaching `lowerMethodCall` at all, so a sibling probe
//! (`tryQualifiedUnionCaseValueJvm`, `jvm/codegen/01_types.l`) was added
//! beside `tryQualifiedEnumClassJvm` in the `EMember` value-lowering path
//! (`jvm/codegen/02_exprs.l`) for that shape. Both probes are scoped
//! narrowly: MSIL already resolves the package/type-qualified CALL form
//! (mirrors `lowerMethodCallMsil`'s own #3840 union-case-constructor fix),
//! so only JVM needed the codegen change; a 3+-segment package-qualified
//! BARE-VALUE nullary reference (no call parens) is not exercised here
//! because it surfaces a separate, pre-existing MSIL gap unrelated to #5943
//! (tracked separately) — the nullary case below is exercised through the
//! 2-segment type-qualified form (`AppError.Down`), which already works on
//! both targets.
//!
//! #5971 closed the PATTERN-position sibling of the #5769 VALUE fix: a
//! package-qualified enum-case *pattern* in a `match` arm (`case
//! Std.Http.GET ->`), including through an `import X as Y` alias (`case
//! H.GET ->` after `import Std.Http as H`), silently failed to discriminate
//! on `--target dotnet`. `registerEnumDeclMsil` already keys the package-
//! qualified ordinal (`pkgName + "." + case`) for VALUE references, but the
//! `PConstructor` pattern-TEST codegen (`lowerPatternTestMsil`,
//! `msil/codegen.l`) only consulted it when the pattern's penultimate
//! segment named the enum TYPE (`case HttpMethod.GET ->`) — never when it
//! named the declaring PACKAGE, the conventional Lyric spelling #5769
//! established. Falling through, the pattern hit the "truly unknown case
//! name" fallback: an unconditional non-null check instead of an ordinal
//! comparison, so the scrutinee's OWN ordinal (via IL `brfalse`) silently
//! decided the match — ordinal 0 (`GET`) never matched (false negative) and
//! any nonzero ordinal always matched (false positive), regardless of the
//! actual case tested. `Lyric.AliasRewriter` already expands `import X as
//! Y` / `case Y.Case ->` to the real package path before type-check, so the
//! aliased form hit the exact same codegen gap. `--target jvm` was
//! unaffected (#5769 already covers the JVM pattern path via
//! `enumVariantClass`).
//!
//! Run in CI via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target dotnet` through `Msil.Bridge` (already
//! covered by `enum_msil_self_test.l`'s equivalent case, but exercised again
//! here for a single shared regression file), `--target jvm` through
//! `Jvm.Bridge` `compileToJarBundled`. Imports only `Std.*`.
@test_module
package Lyric.QualifiedEnumCaseSelfTest

import Std.Core
import Std.Errors
import Std.Http
import Std.Http as H
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

// #5943: package-qualified union-case CONSTRUCTION — a nullary case, a
// single-field case, and a two-field case, each covering a different arity
// of the same fix.
union AppError {
  case Down
  case Missing(id: Long)
  case Bad(code: Int, reason: String)
}

func describeAppError(e: in AppError): String {
  match e {
    case Down -> "down"
    case Missing(id) -> "missing:" + toString(id)
    case Bad(code, reason) -> "bad:" + toString(code) + ":" + reason
  }
}

test "#5943: nullary union case via type-qualified reference (no package prefix) resolves on both targets" {
  val a = AppError.Down
  assertEqual(describeAppError(a), "down", "AppError.Down (type-qualified nullary reference)")
}

test "#5943: single-field union-case CONSTRUCTION type-qualified (Union.Case(args), no package prefix) resolves on both targets" {
  val a = AppError.Missing(id = 7i64)
  assertEqual(describeAppError(a), "missing:7", "AppError.Missing(id = 7) (type-qualified construction)")
}

test "#5943: single-field union-case CONSTRUCTION fully package-qualified resolves on both targets" {
  // `EMember(EMember(EPath["Lyric"], "QualifiedEnumCaseSelfTest"), "AppError")`
  // as the receiver, `Missing` the member — the exact multi-segment shape
  // `lowerMethodCall` fell through to value-evaluation on before the fix.
  val a = Lyric.QualifiedEnumCaseSelfTest.AppError.Missing(id = 99i64)
  assertEqual(describeAppError(a), "missing:99", "Lyric.QualifiedEnumCaseSelfTest.AppError.Missing(id = 99)")
}

test "#5943: two-field union-case CONSTRUCTION fully package-qualified resolves on both targets" {
  val a = Lyric.QualifiedEnumCaseSelfTest.AppError.Bad(code = 500, reason = "boom")
  assertEqual(
    describeAppError(a),
    "bad:500:boom",
    "Lyric.QualifiedEnumCaseSelfTest.AppError.Bad(code = 500, reason = \"boom\")"
  )
}

test "#5943: package-qualified union-case CONSTRUCTION against a real cross-package stdlib union (Std.Errors.ParseError) resolves on both targets" {
  // `Std.Errors` is a genuinely different package from this test module (not
  // just a same-file/self-qualified reference) — the real-world #5943 repro
  // shape: a consumer package constructing another package's union case by
  // its full dotted path.
  val e = Std.Errors.ParseError.InvalidFormat(input = "abc", expected = "int")
  assertEqual(
    ParseError.message(e),
    "invalid format: 'abc' (expected int)",
    "Std.Errors.ParseError.InvalidFormat(...) (cross-package qualified construction)"
  )
}

// #5971: package-qualified enum-case PATTERN in a `match` arm — the
// PATTERN-position sibling of the #5769 VALUE fix above.  A real
// cross-package enum (`Std.Http.HttpMethod`), tested at three distinct
// ordinals (GET=0, POST=1, PUT=2) so a regression that resolves the
// discriminator to "always true for ordinal != 0" or "always false for
// ordinal == 0" (the exact #5971 MSIL bug) cannot pass by accident.
func describeHttpMethodQualified(m: in HttpMethod): String {
  match m {
    case Std.Http.GET -> "qualified-get"
    case Std.Http.POST -> "qualified-post"
    case Std.Http.PUT -> "qualified-put"
    case _ -> "qualified-other"
  }
}

test "#5971: package-qualified enum-case pattern (case Std.Http.GET ->) discriminates correctly on both targets" {
  assertEqual(
    describeHttpMethodQualified(Std.Http.GET),
    "qualified-get",
    "GET (ordinal 0) matches its own qualified case pattern"
  )
  assertEqual(
    describeHttpMethodQualified(Std.Http.POST),
    "qualified-post",
    "POST (ordinal 1) matches its own qualified case pattern, not GET's"
  )
  assertEqual(
    describeHttpMethodQualified(Std.Http.PUT),
    "qualified-put",
    "PUT (ordinal 2) matches its own qualified case pattern, not GET's"
  )
  assertEqual(
    describeHttpMethodQualified(Std.Http.DELETE),
    "qualified-other",
    "DELETE (ordinal 3, no dedicated arm) falls through to the catch-all"
  )
}

// #5971 aliased form: `import Std.Http as H` is syntactic sugar for `import
// Std.Http` per `Lyric.AliasRewriter` (`case H.GET ->` rewrites to `case
// Std.Http.GET ->` before type-check), so this exercises the exact
// user-facing shape from the bug report through the same codegen path.
func describeHttpMethodAliasQualified(m: in HttpMethod): String {
  match m {
    case H.GET -> "alias-get"
    case H.POST -> "alias-post"
    case H.PUT -> "alias-put"
    case _ -> "alias-other"
  }
}

test "#5971: aliased package-qualified enum-case pattern (import Std.Http as H; case H.GET ->) discriminates correctly on both targets" {
  assertEqual(
    describeHttpMethodAliasQualified(Std.Http.GET),
    "alias-get",
    "GET (ordinal 0) matches via the import alias"
  )
  assertEqual(
    describeHttpMethodAliasQualified(Std.Http.POST),
    "alias-post",
    "POST (ordinal 1) matches via the import alias, not GET's"
  )
  assertEqual(
    describeHttpMethodAliasQualified(Std.Http.PUT),
    "alias-put",
    "PUT (ordinal 2) matches via the import alias, not GET's"
  )
}
