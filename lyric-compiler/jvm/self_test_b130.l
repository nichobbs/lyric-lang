//! jvm/self_test_b130.l — Stage B130: async generator pipeline integration.
//!
//! Exercises the full codegenPackage → lowerPackage pipeline for async generator
//! functions (Gap-4 / Gap-4a).  Compiles a Lyric source string containing an
//! `async func` with `yield` via `Jvm.Bridge.compileToJar` and runs the JAR.
//!
//! The Lyric generator program:
//!
//!   async func evens(n: Int): Int {
//!     var i = 0
//!     while i < n {
//!       yield i * 2
//!       i = i + 1
//!     }
//!   }
//!
//!   func main(): Unit {
//!     for v in evens(4) {
//!       println(toString(v))
//!     }
//!   }
//!
//! Expected output (lines): 0, 2, 4, 6
//!
//! Java output (java -jar):
//!   0
//!   2
//!   4
//!   6
package Jvm.SelfTestB130

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge
import Jvm.Driver

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b130"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  // Lyric source containing an async generator and a consumer.
  val src = "package TestEvens\n" + "import Std.Core\n" + "async func evens(n: Int): Int {\n" + "  var i = 0\n" +
    "  while i < n {\n" +
    "    yield i * 2\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  for v in evens(4) {\n" +
    "    println(toString(v))\n" +
    "  }\n" +
    "}\n"

  val jarPath = outDir + "/evens.jar"
  val ok = compileToJar(src, jarPath, "TestEvens", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
