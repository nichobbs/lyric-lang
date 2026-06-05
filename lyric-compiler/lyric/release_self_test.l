//! release_self_test.l — exercises the pure helpers of Lyric.Release
//! (entry-point/package detection) via the native `@test_module` runner.
//!
//! These cover the source-introspection that picks the AOT trampoline's entry
//! type.  The toolchain-driving parts of Lyric.Release (dotnet publish, file
//! staging) are integration-tested by the "release e2e" CI step against the
//! real binary — they can't run through `lyric test` (host-backed stdlib at
//! runtime, #2001).
//!
//! Runs in CI via:
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/release_self_test.l
@test_module
package Lyric.ReleaseSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Release as Release

// ── packageNameOf ────────────────────────────────────────────────────────────
test "packageNameOf: simple package declaration" {
  assertEqual(Release.packageNameOf("package Demo\nimport Std.Core\n"), "Demo", "first package line")
}

test "packageNameOf: dotted package name" {
  assertEqual(
    Release.packageNameOf("// header\npackage My.App.Server\n"),
    "My.App.Server",
    "dotted name, after a comment line"
  )
}

test "packageNameOf: no package declaration → empty" {
  assertEqual(Release.packageNameOf("import Std.Core\nfunc main(): Int { 0 }\n"), "", "no package line")
}

// ── declaresEntryMain ────────────────────────────────────────────────────────
test "declaresEntryMain: zero-arg main is an entry" {
  assertTrue(Release.declaresEntryMain("package P\npub func main(): Int { 0 }\n"), "pub func main()")
  assertTrue(Release.declaresEntryMain("func main(): Int { 0 }\n"), "func main()")
}

test "declaresEntryMain: main with parameters is not an entry" {
  assertTrue(
    not Release.declaresEntryMain("func main(argv: in slice[String]): Int { 0 }\n"),
    "main(argv) is not the emitter's entry form"
  )
}

test "declaresEntryMain: no main → false" {
  assertTrue(not Release.declaresEntryMain("func helper(): Int { 0 }\n"), "no main")
}
