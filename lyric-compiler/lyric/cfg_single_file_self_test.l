//! cfg_single_file_self_test.l — end-to-end regression test for `@cfg`
//! erasure on the SINGLE-FILE build paths (docs/59 §5.4).  Manifest and
//! project builds always ran `Lyric.Cfg.applyCfgErasure`; the single-file
//! `Msil.Bridge.compileToMsilWithVersion` and legacy `Jvm.Bridge.compileToJar`
//! paths compiled `@cfg`-gated items unconditionally — same source,
//! divergent semantics.  This module imports only `Std.*`, so `lyric test`
//! compiles it through the single-file pipeline on `--target dotnet`
//! (`emitTestPlain` → `Msil.Bridge.compileToMsilWithVersion`), and its
//! feature-gated item references a type that does not exist: the build only
//! succeeds when the single-file path erases the item before the type
//! checker runs.  The `--target jvm` run rides the bundled path (which
//! always erased) and pins cross-target parity of the same source.
@test_module
package Lyric.CfgSingleFileSelfTest

import Std.Core
import Std.Testing

// Erased on every build: the feature is never active (no `--features` on a
// single-file build, and the declared set is empty so the F0013 typo guard
// stays off).  The parameter type does not exist, so compiling this item
// instead of erasing it is a fatal type error — the pre-fix single-file
// behaviour.
@cfg(feature = "cfg_single_file_never_active")
pub func gatedByFeature(x: in CfgSingleFileMissingType): Int {
  0
}

// Target pseudo-features (D-N-013): the single-file paths thread
// `target.dotnet` / `target.jvm` into the active set, so exactly one of
// these survives per target and the reference below compiles on both.
@cfg(target = "dotnet")
pub func targetTag(): String {
  "dotnet"
}

@cfg(target = "jvm")
pub func targetTag(): String {
  "jvm"
}

test "inactive cfg feature item is erased on the single-file path" {
  // The proof is the build itself: `gatedByFeature` names a nonexistent
  // type and this module only compiles because erasure removed the item
  // before the type checker ran.
  assertTrue(true, "feature-gated item erased (this module compiled)")
}

test "target pseudo-feature selects exactly one variant" {
  val tag = targetTag()
  assertTrue(tag == "dotnet" or tag == "jvm", "surviving targetTag names a real target: " + tag)
}
