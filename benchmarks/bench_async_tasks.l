//! benchmarks/bench_async_tasks.l - native async scheduler task throughput (docs/67 G8, #8493).
//!
//! Three task-heavy workloads for the coroutine scheduler in `lyric-rt/src/lyric_async.c`.  Each
//! bench runs a fixed number of tasks, so tasks per second is that count divided by the mean time:
//!
//! - `benchForkJoinFib` - recursive fork-join `fib(25)`: every call with `n >= 2` spawns two
//!   subproblems and awaits both, 242785 tasks in all.  Almost every task is fine-grained, which is
//!   the case that per-thread deques with work stealing exist for.
//! - `benchSpawnEmpty` - 100000 spawned tasks with empty bodies, started ten at a time by 10000
//!   batch tasks and awaited in order (110001 tasks with the batches and the driver): spawn and
//!   completion cost with no work to hide them.
//! - `benchFanIn` - 20 rounds of 1024 leaves that each sleep 1 ms, started and joined by a binary
//!   tree of spawns (3071 tasks a round, 61421 with the driver): every leaf parks on the timer list
//!   and all of them wake at once, so the woken tasks and their joins pile onto the ready queues
//!   together.
//!
//! `LYRIC_ASYNC_THREADS` picks the scheduler (unset or 1 cooperative, N >= 2 multi-threaded).
//! `scripts/ci/async-mt-e2e.sh` runs this file at 1, 2, 4 and all cores, prints tasks per second
//! for each, and fails when the fork-join case is slower on all cores than on one thread.
//!
//! Run with: lyric bench benchmarks/bench_async_tasks.l --target native
@bench_module
package Bench.AsyncTasks

import Std.Core
import Std.Time
import Std.Bench

val fibN: Int = 25

val fibAnswer: Int = 75025

val emptyBatches: Int = 10000

val fanInRounds: Int = 20

val fanInLeaves: Int = 1024

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

async func empty(): Unit {
  return ()
}

async func emptyBatch(): Int {
  scope {
    val t0 = spawn empty()
    val t1 = spawn empty()
    val t2 = spawn empty()
    val t3 = spawn empty()
    val t4 = spawn empty()
    val t5 = spawn empty()
    val t6 = spawn empty()
    val t7 = spawn empty()
    val t8 = spawn empty()
    val t9 = spawn empty()
    await t0
    await t1
    await t2
    await t3
    await t4
    await t5
    await t6
    await t7
    await t8
    await t9
    return 10
  }
}

async func leaf(): Int {
  sleepMillis(1)
  return 1
}

async func fanTree(n: in Int): Int {
  if n == 1 {
    return await leaf()
  }
  scope {
    val a = spawn fanTree(n / 2)
    val b = spawn fanTree(n - n / 2)
    return await a + await b
  }
}

func report(what: String, got: Int, want: Int): Unit {
  if got != want {
    println("bench_async_tasks: " + what + " computed " + toString(got) + ", expected " + toString(want))
  }
}

@bench
pub func benchForkJoinFib(): Unit {
  report("fib", await fib(fibN), fibAnswer)
}

async func emptyAll(): Int {
  var total = 0
  var b = 0
  while b < emptyBatches {
    total = total + (await emptyBatch())
    b = b + 1
  }
  total
}

@bench
pub func benchSpawnEmpty(): Unit {
  report("empty tasks", await emptyAll(), emptyBatches * 10)
}

async func fanInAll(): Int {
  var total = 0
  var r = 0
  while r < fanInRounds {
    total = total + (await fanTree(fanInLeaves))
    r = r + 1
  }
  total
}

@bench
pub func benchFanIn(): Unit {
  report("fan-in", await fanInAll(), fanInRounds * fanInLeaves)
}
