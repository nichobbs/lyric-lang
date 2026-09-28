//! stdlib/tests/console_locale_c_tests.l — non-ASCII console text under a
//! C/POSIX locale (#7513).
//!
//! On `--target jvm`, `System.out`/`System.err`/`System.in` decode/encode
//! through the JVM's platform-default charset unless rebound, which is
//! ASCII under a C/POSIX locale (common in containers/CI) — every
//! non-ASCII `println`/`print`/`Std.Console.error` byte would come back as
//! `?`, and every non-ASCII `readLine()` character would come back
//! mangled. `Jvm.Codegen.emitConsoleUtf8Setup` rebinds `System.out`/`err`
//! to UTF-8 `PrintStream`s at process startup, and
//! `Std.ConsoleHost.stdinReader` decodes stdin as UTF-8 explicitly, so all
//! four paths stay correct regardless of the process locale.
//!
//! A driving script (`scripts/ci/console-locale-c-test.sh`) runs this
//! under `LC_ALL=C LANG=C`, feeds a non-ASCII line on stdin, and
//! byte-diffs the raw stdout/stderr against the exact expected UTF-8
//! bytes with `cmp` — never a shell string comparison, which would go
//! through the invoking shell's own locale-dependent decoding.
package Std.Console.LocaleCTests

import Std.Core
import Std.Console

func main(): Int {
  println("café 😀 中文")
  print("café 😀 中文")
  println("")
  error("erré 😀")
  match readLine() {
    case Ok(line) -> println("echo:" + line)
    case Err(_) -> println("echo:<error>")
  }
  0
}
