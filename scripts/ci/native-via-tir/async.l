//! async.l - a call to an async function stays on the AST path (docs/70 phase 4a, D520): the callee
//! returns a task the call site unwraps, so a direct call from TIR would read a task pointer as the
//! result.  `native-via-tir-e2e.sh` runs it both ways and pins the census.
package AsyncViaTir

import Std.Core
import Std.Console as Console

async func answer(): Int {
  42
}

func twice(x: in Int): Int {
  x * 2
}

func main(): Unit {
  println(toString(twice(21)))
  println(toString(answer()))
}
