//! alias_import_jvm_self_test.l — JVM aliased-package-import regression test
//! (#4606, epic #2663).
//!
//! The MSIL bridge runs `Lyric.AliasRewriter.rewriteFile` between parse and
//! type-check so `import Std.String as Str; Str.trim(s)` (and the implicit
//! alias of a bare `import Std.Time`) collapse to fully-qualified paths.  The
//! JVM bridge skipped that pass, so an aliased package-method call reached
//! codegen with the alias as its receiver and fell through to the auto-FFI
//! `Object` guess — panicking with "no method for 'java.lang.Object.<name>'".
//! Both `Jvm.Bridge.compileToJar` and `compileToJarBundledWithFeatures` now run
//! the rewriter; this module pins the behaviour at runtime.
//!
//! Scope: aliased calls into the non-generic `Std.String` surface.  An
//! aliased call into a *generic* stdlib function (`Coll.mapSize`) is
//! excluded — cross-package generic specialisation on the JVM is the open
//! #3229 gap, independent of alias rewriting.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`) and
//! runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.AliasImportSelfTest

import Std.Core
import Std.Testing
import Std.String as Str

// An explicit alias used for a package-function call in a helper the tests
// call through, pinning the alias survives the full middle-end pipeline.
func viaExplicitAlias(s: String): String {
  Str.trim(s)
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "explicit alias: Str.trim resolves through the alias" {
  assertEqual(viaExplicitAlias("  hi  "), "hi", "Str.trim must resolve via the explicit alias")
}

test "explicit alias: Str.startsWith and Str.toUpper resolve" {
  assertTrue(Str.startsWith("lyric", "ly"), "Str.startsWith via alias")
  assertEqual(Str.toUpper("jvm"), "JVM", "Str.toUpper via alias")
}
