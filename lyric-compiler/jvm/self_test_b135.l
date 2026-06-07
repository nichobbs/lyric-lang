//! jvm/self_test_b135.l — Stage B135: non-void try/finally regression (#1683/#2043).
//!
//! Verifies that a non-void function whose body is a single `try { … } finally { … }`
//! block produces bytecode the JVM class-file verifier accepts.  The #1683 fix
//! paths through `lowerFunc`'s `tailTy == JVoid` branch when `try/finally` is
//! in tail position (the finally-fallback in `lowerBlockExpr` evaluates in
//! statement mode and reports JVoid); the emitted `return` opcode must be valid
//! for the enclosing method's return descriptor.
//!
//! The Lyric program:
//!
//!   package TestTryFinally135
//!   func greet(): String {
//!     try { "hello" } finally { println("side-effect") }
//!   }
//!   func main(): Unit { println(greet()) }
//!
//! Java output (java -jar):
//!   side-effect
//!   hello
package Jvm.SelfTestB135

import Std.Core
import Std.Collections
import Std.File
import Jvm.Bridge

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b135"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  // A non-void function whose sole body statement is try/finally exercises the
  // `tailTy == JVoid` branch in `lowerFunc` (#1683).  If the JVM verifier
  // rejects the class, `compileToJar` returns false.
  val src = "package TestTryFinally135\n" + "func greet(): String {\n" +
    "  try { \"hello\" } finally { println(\"side-effect\") }\n" +
    "}\n" +
    "func main(): Unit { println(greet()) }\n"

  val jarPath = outDir + "/try_finally.jar"
  val ok = compileToJar(src, jarPath, "TestTryFinally135", newList())
  if ok {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
