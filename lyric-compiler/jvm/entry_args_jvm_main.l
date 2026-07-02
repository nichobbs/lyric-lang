//! entry_args_jvm_main.l — `func main(args: slice[String]): Int` entry-point
//! program for the `--target jvm` argv / exit-code regression check (#3303).
//!
//! Not a `@test_module`: the JVM entry wrapper (`main(String[])` forwarding
//! argv and routing an `Int` return through `java.lang.System.exit`) is only
//! synthesised around a user `main`, which `lyric test`'s synthesised runner
//! replaces.  CI compiles this file with `lyric build --target jvm`, runs
//! `java -jar out.jar one two three`, and asserts both the printed argv line
//! and the process exit code (= args.count).
package Main

import Std.Console

func main(args: slice[String]): Int {
  println("argc=" + args.count.toString())
  var i = 0
  while i < args.count {
    println("arg" + i.toString() + "=" + args[i])
    i = i + 1
  }
  args.count
}
