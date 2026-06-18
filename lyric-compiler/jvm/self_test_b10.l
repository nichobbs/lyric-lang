//! jvm/self_test_b10.l — Stage B10 smoke test: manifest and contract emission.
//!
//! Exercises Jvm.Manifest by generating a MANIFEST.MF and a lyric-contract JSON
//! for a synthetic "Jvm.Classfile" package, then prints both to stdout.
//!
//! The Expecto test (JvmLoweringB10Test.fs) compiles and runs this program,
//! then verifies key substrings in the output:
//!   "Manifest-Version: 1.0"         (MANIFEST.MF first line)
//!   "Lyric-Package: Jvm.Classfile"  (package metadata in manifest)
//!   "\"package\": \"Jvm.Classfile\""  (package field in contract JSON)
//!   "\"name\": \"parseClassSummary\""  (first export in contract JSON)
package Jvm.SelfTestB10

import Std.Core
import Std.Collections
import Jvm.Manifest

func main(): Unit {
  val meta = PackageMeta(packageName = "Jvm.Classfile", mainClass = "jvm/classfile/Program", version = "0.1.0")

  val mf = makeManifestMf(meta)
  println("--- MANIFEST.MF ---")
  println(mf)

  val exports: List[ExportedFunc] = newList()
  exports.add(ExportedFunc(name = "parseClassSummary", descriptor = "([B)Ljvm/reader/ClassSummary;"))
  exports.add(ExportedFunc(name = "readU2", descriptor = "([BI)I"))
  exports.add(ExportedFunc(name = "skipPool", descriptor = "([BII)I"))

  val json = makeLyricContractJson(meta, exports)
  println("--- CONTRACT ---")
  println(json)
}
