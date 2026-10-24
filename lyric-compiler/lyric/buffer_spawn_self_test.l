//! A `buffer[T]` handed to `spawn` is a copy (D185, docs/67 §4.4): a write the
//! spawning task makes afterwards is not seen by the spawned task, and the
//! spawned task's view is the buffer as it was handed over.
//!
//! Runs on dotnet, the JVM and native.  The JVM evaluates a copied array or
//! buffer argument of the spawned call when `spawn` runs, not inside the task
//! (#8391); the array and object-element cases pin both copy lowerings.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_spawn_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/buffer_spawn_self_test.l
//!   lyric test --target native lyric-compiler/lyric/buffer_spawn_self_test.l
@test_module
package Lyric.BufferSpawnSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Buffer
import Std.Bench

async func firstOf(b: in buffer[Int]): Int {
  return b[0]
}

async func spawnThenWrite(): Int {
  var b = filled(2, 1)
  scope {
    val t = spawn firstOf(b)
    b[0] = 9
    val seen = await t
    return seen * 100 + b[0]
  }
}

test "a buffer handed to spawn is a copy: a later write is not seen by the task" {
  assertEqualInt(spawnThenWrite(), 109, "the task read the buffer as it was handed over; the writer sees its own write")
}

async func firstOfArray(a: in array[2, Int]): Int {
  return a[0]
}

async func spawnArrayThenWrite(): Int {
  var a: array[2, Int] = [1, 1]
  scope {
    val t = spawn firstOfArray(a)
    a[0] = 9
    val seen = await t
    return seen * 100 + a[0]
  }
}

test "an array handed to spawn is a copy: a later write is not seen by the task" {
  assertEqualInt(spawnArrayThenWrite(), 109, "the task read the array as it was handed over")
}

async func firstOfStrings(a: in array[2, String]): String {
  return a[0]
}

async func spawnStringArrayThenWrite(): String {
  var a: array[2, String] = ["x", "y"]
  scope {
    val t = spawn firstOfStrings(a)
    a[0] = "z"
    val seen = await t
    return seen + a[0]
  }
}

test "an array of references handed to spawn is copied when spawned" {
  assertEqual(spawnStringArrayThenWrite(), "xz", "the task saw the original element")
}

// A copy does not copy the storage until a write meets it (D226), so each of
// these has a task holding storage the spawning task then writes to, or the
// other way round.
async func sumOf(b: in buffer[Int]): Int {
  var t = 0
  for x in b {
    t = t + x
  }
  return t
}

async func spawnTwoThenWrite(): Int {
  var b = filled(4, 1)
  scope {
    val t1 = spawn sumOf(b)
    val t2 = spawn sumOf(b)
    b[0] = 100
    b[1] = 100
    val s1 = await t1
    val s2 = await t2
    return (s1 + s2) * 1000 + b[0] + b[1]
  }
}

test "two tasks handed the same buffer both see it as it was handed over" {
  assertEqualInt(spawnTwoThenWrite(), 8200, "each task summed four ones; the writer sees its own writes")
}

async func bumpOwnCopy(b: in buffer[Int]): Int {
  var c = b
  c[0] = 50
  return c[0]
}

async func spawnTaskWrites(): Int {
  var b = filled(3, 1)
  scope {
    val t = spawn bumpOwnCopy(b)
    val r = await t
    return r * 10 + b[0]
  }
}

test "a task that writes its own copy of a spawned buffer does not change the spawner's" {
  assertEqualInt(spawnTaskWrites(), 501, "the task wrote 50 to its copy; the spawner still holds 1")
}

async func firstOfBig(b: in buffer[Int]): Int {
  return b[0]
}

async func spawnBigBuffer(): Int {
  var b = filled(50000, 3)
  scope {
    val before = allocatedBytes()
    val t = spawn firstOfBig(b)
    val used = allocatedBytes() - before
    b[0] = 4
    val seen = await t
    if used > 100000i64 {
      return 0 - 1
    }
    return seen * 10 + b[0]
  }
}

test "handing a large buffer to spawn marks it shared instead of copying it" {
  assertEqualInt(
    spawnBigBuffer(),
    34,
    "the spawn allocated far less than the buffer; the task read 3, the spawner wrote 4"
  )
}

async func repeatedSum(b: in buffer[Int]): Int {
  var t = 0
  var r = 0
  while r < 50 {
    for x in b {
      t = t + x
    }
    r = r + 1
  }
  return t
}

async func spawnWhileWriting(): Int {
  var b = filled(1000, 1)
  scope {
    val t = spawn repeatedSum(b)
    var i = 0
    while i < 1000 {
      b[i] = 2
      i = i + 1
    }
    val seen = await t
    return seen + b[999]
  }
}

test "a task reading its buffer while the spawner overwrites every element sees the original" {
  assertEqualInt(spawnWhileWriting(), 50000 + 2, "the task summed fifty passes of ones")
}
