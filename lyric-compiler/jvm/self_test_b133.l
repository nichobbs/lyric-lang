//! jvm/self_test_b133.l — Stage B133: IInterface JVM codegen pipeline.
//!
//! Exercises codegenPackage → lowerPackage for a Lyric `interface` declaration
//! (docs/41 §9 Band 3).  Compiles a complete Lyric source string via
//! Jvm.Bridge.compileToJar.
//!
//! The Lyric program:
//!
//!   package TestIface133
//!   interface Greeter { func greet(): String }
//!   record SimpleGreeter {}
//!   impl Greeter for SimpleGreeter { func greet(): String { "hello" } }
//!   func main(): Unit { println("iface_ok") }
//!
//! Java output (java -jar):
//!   iface_ok
package Jvm.SelfTestB133

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b133"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val src = "package TestIface133\n" + "interface Greeter {\n" + "  func greet(): String\n" + "}\n" +
    "record SimpleGreeter {}\n" +
    "impl Greeter for SimpleGreeter {\n" +
    "  func greet(): String { \"hello\" }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(\"iface_ok\")\n" +
    "}\n"

  val jarPath = outDir + "/iface.jar"
  val ok = compileToJar(src, jarPath, "TestIface133", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
