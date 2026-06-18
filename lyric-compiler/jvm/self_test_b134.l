//! jvm/self_test_b134.l — Stage B134: IImpl JVM codegen pipeline.
//!
//! Exercises codegenPackage → lowerPackage where a record declares that it
//! implements an interface (docs/41 §9 Band 3).  Compiles a complete Lyric
//! source string via Jvm.Bridge.compileToJar.
//!
//! The Lyric program:
//!
//!   package TestImpl134
//!   interface Nameable { func name(): String }
//!   record Person { age: Int }
//!   impl Nameable for Person { func name(): String { "person" } }
//!   func main(): Unit { println("impl_ok") }
//!
//! Java output (java -jar):
//!   impl_ok
package Jvm.SelfTestB134

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b134"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val src = "package TestImpl134\n" + "interface Nameable {\n" + "  func name(): String\n" + "}\n" +
    "record Person { age: Int }\n" +
    "impl Nameable for Person {\n" +
    "  func name(): String { \"person\" }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(\"impl_ok\")\n" +
    "}\n"

  val jarPath = outDir + "/impl.jar"
  val ok = compileToJar(src, jarPath, "TestImpl134", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
