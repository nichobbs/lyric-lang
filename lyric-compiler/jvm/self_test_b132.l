//! jvm/self_test_b132.l — Stage B132: IDistinctType codegen pipeline integration.
//!
//! Exercises codegenPackage → lowerPackage for a Lyric `type X = Y` distinct
//! type declaration (docs/41 §9 Band 3).  Compiles a complete Lyric source
//! string via Jvm.Bridge.compileToJar.
//!
//! The Lyric program:
//!
//!   package TestDistinct132
//!   type UserId = Int
//!   func main(): Unit { println("distinct_ok") }
//!
//! Java output (java -jar):
//!   distinct_ok
package Jvm.SelfTestB132

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge
import Jvm.Driver

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b132"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  // #879 deferred: the issue suggested constructing a `UserId(42)` value
  // here to exercise the distinct-type constructor codegen, but the
  // self-hosted JVM emitter does not yet implement distinct-type wrapper
  // class lowering for value construction.  The test would fail at
  // `java -jar` runtime (NoSuchMethodError on the synthesized
  // constructor).  This self-test stays as a codegen-pipeline smoke
  // test until the wrapper class is wired up; the extended-coverage
  // follow-up is tracked in #887.
  val src = "package TestDistinct132\n" + "type UserId = Int\n" + "func main(): Unit {\n" +
    "  println(\"distinct_ok\")\n" +
    "}\n"

  val jarPath = outDir + "/distinct.jar"
  val ok = compileToJar(src, jarPath, "TestDistinct132", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
