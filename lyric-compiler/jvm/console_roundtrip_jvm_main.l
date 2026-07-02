//! console_roundtrip_jvm_main.l — `Std.Console` stdin/stdout/stderr round-trip
//! program for `--target jvm` (band J6, epic #2663 / #2669).
//!
//! Not a `@test_module`: TAP tests have no stdin.  CI compiles this file with
//! `lyric build --target jvm`, runs `printf 'alpha\nbeta\n' | java -jar
//! out.jar`, and asserts the echoed lines, the EOF `Err(EndOfInput)`, and the stderr
//! line.  This is the first executable proof of the pure-Lyric
//! `_kernel_jvm/console_host.l` (previously a phantom `lyric.stdlib.jvm.*`
//! shim; now `getstatic java.lang.System.{out,err,in}` via the auto-FFI's
//! static-field path, with a process-shared BufferedReader for stdin).
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
