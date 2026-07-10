//! jvm/self_test_b131.l — Stage B131: IEnum codegen pipeline integration.
//!
//! Exercises codegenPackage → lowerPackage for a Lyric `enum` declaration
//! (docs/41 §9 Band 3).  Compiles a complete Lyric source string via
//! Jvm.Bridge.compileToJar, then RUNS the produced jar under `java` (the
//! self_test_b13.l host-JDK pattern) and asserts the program's actual output,
//! so enum-case access is runtime-proven, not just compile-proven.
//!
//! The embedded program covers every enum-value path (docs/59 §4.4):
//!   - qualified case access in expression position (`Direction.North` →
//!     `getstatic` of the variant's singleton field);
//!   - bare case references in expression position (`East` as a match-arm
//!     result / argument);
//!   - singleton identity (`d == d2` for two reads of the same case);
//!   - passing an enum value across a function boundary;
//!   - `match` over an enum scrutinee with bare (`case North ->`) and
//!     qualified (`case Direction.North ->`) case patterns.
//!
//! Java output (java -jar):
//!   ident_ok
//!   name_N
//!   rot_E
//!   rot2_S
//!   enum_ok
package Jvm.SelfTestB131

import Std.Core
import Std.Collections
import Std.File
import Std.Process as Process
import Jvm.Bridge
import Jvm.Driver

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b131"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  // #879: actually construct and USE Direction values so the JVM codegen
  // paths for enum-case access (getstatic), identity, function-boundary
  // crossing, and enum match patterns are all exercised, not just the
  // type-definition lowering pass.
  val src = "package TestEnum131\n" + "enum Direction { case North, case South, case East, case West }\n" +
    "func rotate(d: in Direction): Direction {\n" +
    "  match d {\n" +
    "    case North -> East\n" +
    "    case East -> South\n" +
    "    case South -> West\n" +
    "    case West -> North\n" +
    "  }\n" +
    "}\n" +
    "func nameOf(d: in Direction): String {\n" +
    "  match d {\n" +
    "    case Direction.North -> \"N\"\n" +
    "    case East -> \"E\"\n" +
    "    case South -> \"S\"\n" +
    "    case West -> \"W\"\n" +
    "  }\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  val d = Direction.North\n" +
    "  val d2 = Direction.North\n" +
    "  if d == d2 {\n" +
    "    println(\"ident_ok\")\n" +
    "  } else {\n" +
    "    println(\"ident_bad\")\n" +
    "  }\n" +
    "  println(\"name_\" + nameOf(d))\n" +
    "  println(\"rot_\" + nameOf(rotate(d)))\n" +
    "  println(\"rot2_\" + nameOf(rotate(rotate(d))))\n" +
    "  println(\"enum_ok\")\n" +
    "}\n"

  val jarPath = outDir + "/enum.jar"
  val ok = compileToJar(src, jarPath, "TestEnum131", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
    return
  }

  val javaArgs: List[String] = newList()
  javaArgs.add("-jar")
  javaArgs.add(jarPath)
  match Process.runCapture("java", javaArgs, 60000) {
    case Ok(res) -> {
      if res.exitCode == 0 {
        println("java_exit_ok=true")
      } else {
        println("java_exit_ok=false")
        println(res.stderr)
        return
      }
      val expected = "ident_ok\nname_N\nrot_E\nrot2_S\nenum_ok\n"
      if res.stdout == expected {
        println("enum_runtime_output_ok=true")
      } else {
        println("enum_runtime_output_ok=false")
        println("expected: " + expected)
        println("actual: " + res.stdout)
      }
    }
    case Err(e) -> {
      println("java_exit_ok=false")
      println(e)
    }
  }
}
