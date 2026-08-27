//! env_args_jvm_main.l — `Std.Environment.args()` JVM regression check
//! (#5377).
//!
//! Not a `@test_module`: `lyric test` never forwards real CLI args to the
//! compiled test program, so the only way to prove `Std.Environment.args()`
//! observes the REAL process argv is to build a real jar and launch it with
//! `java -jar ... <args>` (mirrors `entry_args_jvm_main.l`'s #3303 check).
//! This program's `main` deliberately declares NO `argv` parameter, so the
//! test also pins that the capture is unconditional — the entry-point
//! wrapper stashes the incoming `String[]` into the `__LyricJvmRuntime`
//! holder class before forwarding to the Lyric `main` regardless of whether
//! `main` itself declares an `argv` parameter (see `Jvm.Codegen`'s `hasMain`
//! synthesis in `codegen/06_items.l` and `LPRuntimeArgsHolder` in
//! `Jvm.Lowering`). CI compiles this file with `lyric build --target jvm`,
//! runs `java -jar out.jar four five`, and asserts the printed argv lines.
package Main

import Std.Console
import Std.Environment

func main(): Unit {
  val a = args()
  println("argc=" + a.count.toString())
  var i = 0
  while i < a.count {
    println("arg" + i.toString() + "=" + a[i])
    i = i + 1
  }
}
