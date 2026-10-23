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
