//! metadata_reader_self_test.l — regression coverage for the reference-pack
//! probe walk (#4741, #4747).
//!
//! `probeRefPackRoot` / `RefPackProbe` are intentionally not `pub` (#4746) —
//! `refPackDir()` and `refPackDirDebugInfo()` are the only public surface,
//! and both are built on top of the same per-root probe (#4741: before that
//! refactor the two walks could silently drift apart).  This test exercises
//! that shared-source-of-truth property from outside the package: whatever
//! `refPackDir()` finds (or doesn't) on the host running this test,
//! `refPackDirDebugInfo()`'s trace must agree with it.
//!
//! Converted from a plain `func main` program to `@test_module` (#4751).
//! `Msil.MetadataReader` resolves under native `lyric test` the same way
//! `Msil.Kernel`/`Msil.Heaps` do for the sibling `msil_self_test_m2a.l`-
//! `m2d.l`/`m88.l` `@test_module` files: the self-hosted compiler DLLs are
//! staged as restored deps (see the "MSIL backend self-tests M2a-M2d
//! (native lyric test)" CI step), so no `LYRIC_LOAD_COMPILER=1` recompile
//! is needed here either. This file is NOT YET added to that step's file
//! list in `.github/workflows/ci.yml` — that one-line CI wiring addition is
//! left for a follow-up, since this triage pass is scoped to
//! `lyric-compiler/msil/` source files only, not the workflow file.
@test_module
package Msil.MetadataReaderSelfTest

import Msil.MetadataReader
import Std.Core
import Std.String as Str
import Std.Testing

test "refPackDirDebugInfo() returns a non-empty trace" {
  val debugInfo = refPackDirDebugInfo()
  assertTrue(debugInfo.length > 0, "debugInfo_nonEmpty")
}

test "refPackDir() and refPackDirDebugInfo() agree on what was found" {
  val debugInfo = refPackDirDebugInfo()
  match refPackDir() {
    case Some(dir) -> {
      assertTrue(Str.contains(debugInfo, "found " + dir), "debugInfo_mentionsFoundDir")
    }
    case None -> {
      assertTrue(not Str.contains(debugInfo, "found "), "debugInfo_hasNoFoundMarker")
    }
  }
}
