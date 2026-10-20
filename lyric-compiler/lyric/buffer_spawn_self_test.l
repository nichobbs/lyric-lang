//! A `buffer[T]` handed to `spawn` is a copy (D185, docs/67 §4.4): a write the
//! spawning task makes afterwards is not seen by the spawned task, and the
//! spawned task's view is the buffer as it was handed over.
//!
//! Runs on dotnet and native.  On the JVM the spawned operand is evaluated
//! inside the task, so the copy of an array or buffer argument happens after
//! the later write (#8391); add `--target jvm` here and to its CI line when
//! that is fixed.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/buffer_spawn_self_test.l
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
