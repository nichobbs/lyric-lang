//! jvm/self_test_b13.l — Stage B13 smoke test: JDK round-trip class-file reader.
//!
//! Reads a real JDK class file from disk (written by the F# test harness
//! via javac) and passes its bytes to Jvm.Reader.parseClassSummary, verifying
//! that the magic number is valid and the major version is >= 52 (Java 8).
//!
//! The Expecto test (JvmLoweringB13Test.fs) pre-creates the class file at
//! /tmp/lyric-jvm-b13/Probe.class before running this Lyric program.
package Jvm.SelfTestB13

import Std.Core
import Std.Collections
import Std.File
import Jvm.Reader

func main(): Unit {
  val path = "/tmp/lyric-jvm-b13/Probe.class"

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
