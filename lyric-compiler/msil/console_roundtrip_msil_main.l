//! console_roundtrip_msil_main.l — `Std.Console` stdin/stdout/stderr round-trip
//! program for `--target dotnet` (mirrors `jvm/console_roundtrip_jvm_main.l`).
//!
//! Not a `@test_module`: TAP tests have no stdin.  CI compiles and runs this
//! file with `lyric run`, pipes `printf 'alpha\nbeta\n'` into it, and asserts
//! the echoed lines, the EOF `Err(EndOfInput)`, and the stderr line.  This is
//! the MSIL-target regression coverage for `hostReadLineOpt` (#4816/#4817):
//! `Std.Console.readLine`'s original `case null -> Err(EndOfInput)` first arm
//! silently reported EOF on every call in any self-hosted-compiled binary —
//! the JVM twin had `console_roundtrip_jvm_main.l`, but the `.NET`
//! `_kernel/console_host.l` seam had no equivalent executable proof.
package Main

import Std.Core
import Std.Console as Console

func main(): Int {
  var lines = 0
  var keep = true
  while keep {
    match Console.readLine() {
      case Ok(line) -> {
        Console.println("echo:" + line)
        lines = lines + 1
      }
      case Err(_) -> {
        keep = false
      }
    }
  }
  Console.error("err-line")
  Console.println("eof-after:" + toString(lines))
  0
}
