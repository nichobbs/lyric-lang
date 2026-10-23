//! A program (not a test module) that drives the multi-threaded coroutine scheduler hard enough for
//! ThreadSanitizer: recursive fork-join, sleepers resumed on other threads, a protected total hit
//! from every task, and await chains that park on a sleeping leaf and resume on another thread.  `scripts/ci/async-mt-e2e.sh`
//! compiles its IR with `-fsanitize=thread` and runs it with `LYRIC_ASYNC_THREADS` set; any data
//! race or wrong answer is a failure.
package Std.AsyncMt.TsanMain

import Std.Core
import Std.Console as Console
import Std.Time as Time

protected type Total {
  var sum: Int = 0
  entry add(n: in Int) {
    sum = sum + n
  }
  entry get(): Int {
    return sum
  }
}

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

async func fib(n: in Int): Int {
  if n < 2 {
    return n
  }
  scope {
    val a = spawn fib(n - 1)
    val b = spawn fib(n - 2)
    return await a + await b
  }
}

async func napper(t: in Total, n: in Int, ms: in Int): Unit {
  Time.sleepMillis(ms)
  t.add(n)
  Time.sleepMillis(ms)
  t.add(n * 100)
}

async func sleepers(t: in Total): Unit {
  scope {
    val a = spawn napper(t, 1, 3)
    val b = spawn napper(t, 2, 7)
    val c = spawn napper(t, 3, 5)
    val d = spawn napper(t, 4, 1)
    await a
    await b
    await c
    await d
  }
}

async func chain(n: in Int): Int {
  if n == 0 {
    Time.sleepMillis(10)
    return 0
  }
  return await chain(n - 1) + 1
}

async func chains(): Int {
  scope {
    val a = spawn chain(20)
    val b = spawn chain(30)
    val c = spawn chain(40)
    return await a + await b + await c
  }
}

func main(): Int {
  val v = await fib(15)
  if v != 610 {
    return fail("fib " + v.toString())
  }

  val total = Total()
  await sleepers(total)
  if total.get() != 1010 {
    return fail("sleepers " + total.get().toString())
  }

  val c = await chains()
  if c != 90 {
    return fail("chains " + c.toString())
  }
  Console.println("async mt ok")
  0
}
