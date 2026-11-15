//! async.l - async functions lowered from TIR (docs/70 phase 4a, D520): a coroutine with its task
//! completion, retained reference parameters, a call that awaits in place, `spawn` inside a
//! `scope` with `await` on the handle, an async function calling another, a Unit-returning one, and
//! `sleepMillis` (the reactor's sleep leaf, which parks the task).  `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package AsyncViaTir

import Std.Core
import Std.Console as Console
import Std.Time

async func answer(): Int {
  42
}

async func greet(name: in String): String {
  "hello " + name
}

async func shout(name: in String): String {
  val g = greet(name)
  g + "!"
}

async func note(tag: in String): Unit {
  println("note " + tag)
}

async func add(a: in Int, b: in Int): Int {
  a + b
}

func twice(x: in Int): Int {
  x * 2
}

async func fan(): Int {
  scope {
    val x = spawn add(1, 2)
    val y = spawn add(10, 20)
    val z = spawn add(100, 200)
    return (await x) + (await y) + (await z)
  }
}

async func napper(): Int {
  sleepMillis(5)
  val t = answer()
  sleepMillis(1)
  t - 35
}

func main(): Unit {
  println(toString(twice(21)))
  println(toString(answer()))
  println(shout("ann"))
  note("a")
  println(toString(fan()))
  println(toString(napper()))
}
