// jvm/self_test_b131.l — Stage B131: IEnum codegen pipeline integration.
//
// Exercises codegenPackage → lowerPackage for a Lyric `enum` declaration
// (docs/41 §9 Band 3).  Compiles a complete Lyric source string via
// Jvm.Bridge.compileToJar.
//
// The Lyric program:
//
//   package TestEnum131
//   enum Direction { case North, case South, case East, case West }
//   func main(): Unit { println("enum_ok") }
//
// Java output (java -jar):
//   enum_ok

package Jvm.SelfTestB131

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge
import Jvm.Driver

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b131"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val src =
    "package TestEnum131\n" +
    "enum Direction { case North, case South, case East, case West }\n" +
    "func main(): Unit {\n" +
    "  println(\"enum_ok\")\n" +
    "}\n"

  val jarPath = outDir + "/enum.jar"
  val ok = compileToJar(src, jarPath, "TestEnum131")
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
