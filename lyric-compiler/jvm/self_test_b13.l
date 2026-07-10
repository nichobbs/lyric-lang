//! jvm/self_test_b13.l — Stage B13 smoke test: JDK round-trip class-file reader.
//!
//! Compiles a one-class probe with the host `javac`, reads the resulting real
//! JDK class file from disk, and passes its bytes to
//! Jvm.Reader.parseClassSummary, verifying that the magic number is valid and
//! the major version is >= 52 (Java 8).
//!
//! The probe was historically pre-created by the deleted F# Expecto harness
//! (JvmLoweringB13Test.fs); the test now produces its own fixture so it is
//! self-sufficient under scripts/run-numbered-self-tests.sh (requires a JDK
//! on PATH, same as the other JVM-target CI steps).
package Jvm.SelfTestB13

import Std.Core
import Std.Collections
import Std.File
import Std.Process as Process
import Jvm.Reader
import Jvm.Kernel

func main(): Unit {
  val dir = "/tmp/lyric-jvm-b13"
  val path = dir + "/Probe.class"

  match createDir(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  match writeText(dir + "/Probe.java", "public class Probe { public static int answer() { return 42; } }") {
    case Ok(_) -> ()
    case Err(_) -> {
      println("javac_ok=false")
      return
    }
  }
  val javacArgs: List[String] = newList()
  javacArgs.add("-d")
  javacArgs.add(dir)
  javacArgs.add(dir + "/Probe.java")
  match Process.run("javac", javacArgs) {
    case Ok(rc) -> {
      if rc == 0 {
        println("javac_ok=true")
      } else {
        println("javac_ok=false")
        return
      }
    }
    case Err(_) -> {
      println("javac_ok=false")
      return
    }
  }

  match readBytes(path) {
    case Err(_) -> {
      println("read_ok=false")
    }
    case Ok(bytes) -> {
      println("read_ok=true")
      println("byte_count=" + toString(bytes.count))

      val summary = parseClassSummary(bytes)

      if summary.magicValid {
        println("magic_valid=true")
      } else {
        println("magic_valid=false")
      }

      println("major_version=" + toString(summary.majorVersion))

      if summary.majorVersion >= 52 {
        println("version_ok=true")
      } else {
        println("version_ok=false")
      }

      println("pool_count=" + toString(summary.poolCount))
      println("method_count=" + toString(summary.methodCount))
    }
  }
}
