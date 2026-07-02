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
//! Written as a plain `func main` program rather than `@test_module`,
//! matching `kernel_self_test.l`'s pattern in this directory.
//!
//! Run with the compiler sources loaded so `import Msil.MetadataReader` resolves:
//!
//!   LYRIC_LOAD_COMPILER=1 ./bin/lyric run lyric-compiler/msil/metadata_reader_self_test.l
package Msil.MetadataReaderSelfTest

import Msil.MetadataReader
import Std.Core
import Std.String as Str

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=FAIL")
  }
}

pub func main(): Int {
  val debugInfo = refPackDirDebugInfo()
  check("debugInfo_nonEmpty", debugInfo.length > 0)

  match refPackDir() {
    case Some(dir) -> {
      check("debugInfo_mentionsFoundDir", Str.contains(debugInfo, "found " + dir))
    }
    case None -> {
      check("debugInfo_hasNoFoundMarker", not Str.contains(debugInfo, "found "))
    }
  }

  0
}
