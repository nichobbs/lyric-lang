//! cross_package_type_resolution_jvm_self_test.l — executable regression
//! test for #7357: a bare (non-generic) reference to a type declared in a
//! package the current file never DIRECTLY imports — only transitively,
//! through a package it DOES import that itself re-exports the type —
//! erased to a phantom SAME-PACKAGE class instead of the real one, failing
//! with `NoClassDefFoundError: <thisPackage>/<TypeName>` at class-load.
//!
//! Two concrete shapes reported this:
//!   - `Std.Json`'s `JsonElement`: declared as a plain `pub record` in
//!     `Std.JsonHost` (`_kernel_jvm/json_host.l`), re-exported through
//!     `Std.Json` (`import Std.JsonHost`) — a consumer file writes `import
//!     Std.Json`, never `import Std.JsonHost` directly. `Lambda.Dispatch`'s
//!     `hasProp(elem: in JsonElement, name: in String): Bool` — a plain
//!     free-function helper called from a SIBLING function in the same
//!     file, not inlined — hit this (#7337's investigation; lyric-i18n's
//!     `fromJson` carries an inlining workaround for the identical gap, see
//!     its header comment).
//!   - `Std.Time`'s `Instant`: an `extern type` (not a plain record) in
//!     `Std.TimeHost`, re-exported through `Std.Time`. A generic function
//!     call this compiler's monomorphizer specialises for a caller's own
//!     `Option[Instant]` (`Std.Core.isSome[T]` called as `isSome(o)` with
//!     `o: Option[Instant]`) synthesises a specialised copy whose
//!     substituted parameter type is a bare `TRef("Instant")` — the SAME
//!     gap, since the synthesised copy is registered as if declared in the
//!     CALLER's own file, which (like the `JsonElement` case) writes
//!     `import Std.Time`, never `import Std.TimeHost`.
//!
//! Root cause: `Jvm.Bridge.externSeedForFile`'s bare-key visibility check
//! (which package-level type registry entries a consumer's UNQUALIFIED type
//! reference may resolve against) considered only a file's own DIRECT
//! imports, not the TRANSITIVE closure reachable through them — fixed by
//! `Jvm.Bridge.transitiveWantedPkgs`, a BFS over each in-bundle package's
//! own import list.
//!
//! This file exercises the three reported shapes:
//!   1. a plain (non-lambda) function parameter typed with the transitively-
//!      imported record `JsonElement`, called from a sibling function
//!      (never inlined) — the `hasProp` shape.
//!   2. a LAMBDA parameter typed with the same transitively-imported record.
//!   3. `Option[Instant]` passed to the generic `Std.Core.isSome[T]`.
//!
//! Run in CI via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target jvm` is the load-bearing run (the
//! erasure/monomorphization bug is JVM-only — MSIL's real generics and
//! metadata-based type resolution never hit it); `--target dotnet` exercises
//! the same shapes on the CLR for parity. Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm    lyric-compiler/jvm/cross_package_type_resolution_jvm_self_test.l
//!   lyric test --target dotnet lyric-compiler/jvm/cross_package_type_resolution_jvm_self_test.l
@test_module
package Lyric.CrossPackageTypeResolutionJvmSelfTest

import Std.Core
import Std.Json
import Std.Time
import Std.Testing

// Shape 1: a plain function parameter typed with a transitively-imported
// record (`JsonElement`, from `Std.JsonHost` via `Std.Json`), called from a
// SIBLING function — mirrors `Lambda.Dispatch.hasProp`.
func hasStringProp(elem: in JsonElement, name: in String): Bool {
  match tryGetProperty(elem, name) {
    case Some(v) -> valueKind(v) == 3
    case None -> false
  }
}

func firstNameOrEmpty(elem: in JsonElement): String {
  if hasStringProp(elem, "name") {
    match tryGetProperty(elem, "name") {
      case Some(v) -> getString(v)
      case None -> ""
    }
  } else {
    ""
  }
}

test "plain function parameter typed with a transitively-imported record resolves to its real class (#7357, hasProp shape)" {
  val doc = parseJson("{\"name\":\"ada\"}")
  defer {
    disposeJson(doc)
  }
  val root = rootElement(doc)
  assertTrue(hasStringProp(root, "name"), "hasStringProp must see the \"name\" property")
  assertEqual(firstNameOrEmpty(root), "ada", "firstNameOrEmpty decodes through the helper")
}

// Shape 2: a LAMBDA parameter typed with the same transitively-imported
// record.
func extractName(elem: in JsonElement): String {
  val extractor = { (e: JsonElement) ->
    match tryGetProperty(e, "name") {
      case Some(v) -> if valueKind(v) == 3 { getString(v) } else { "" }
      case None -> ""
    }
  }
  extractor(elem)
}

test "lambda parameter typed with a transitively-imported record resolves to its real class (#7357)" {
  val doc = parseJson("{\"name\":\"grace\"}")
  defer {
    disposeJson(doc)
  }
  assertEqual(extractName(rootElement(doc)), "grace", "extractName via a JsonElement-typed lambda param")
}

// Shape 3: `Option[Instant]` passed to the generic `Std.Core.isSome[T]` —
// `Instant` is an `extern type` (not a plain record) from `Std.TimeHost`,
// re-exported through `Std.Time`.
test "Option[Instant] passed to the generic isSome resolves Instant's real class (#7357)" {
  val withValue: Option[Instant] = Some(value = now())
  val empty: Option[Instant] = None
  assertTrue(isSome(withValue), "isSome must be true for Some(Instant)")
  assertTrue(not isSome(empty), "isSome must be false for None")
}
