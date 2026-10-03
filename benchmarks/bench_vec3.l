//! benchmarks/bench_vec3.l — small value-record arithmetic.
//!
//! Measures the inner-loop shape graphics and game code is made of: a
//! three-component `Float` vector added, subtracted and scaled thousands of
//! times per frame, and a fixed array of positions integrated in place.
//!
//! On `--target native` a record without `var` fields is a value (D157) and
//! `array[N, T]` is stored inline (D167), so every bench here reports
//! `alloc=0B/run`; `scripts/ci/bench-vec3-alloc.sh` asserts it (docs/67 G1).
//! On dotnet and JVM records are heap objects, so the same benches report the
//! bytes their temporaries allocate.
//!
//! Run with: lyric bench benchmarks/bench_vec3.l --target native
@bench_module
package Bench.Vec3

import Std.Core
import Std.Time
import Std.Bench

@derive(Add, Sub)
record Vec3 {
  x: Float
  y: Float
  z: Float
}

func scale(v: in Vec3, k: in Float): Vec3 = Vec3(x = v.x * k, y = v.y * k, z = v.z * k)

func dot(a: in Vec3, b: in Vec3): Float = a.x * b.x + a.y * b.y + a.z * b.z

// ─── Add / Sub ────────────────────────────────────────────────────────────────
@bench
pub func benchVec3AddSub(): Unit {
  var acc = Vec3(x = 0.0, y = 0.0, z = 0.0)
  val step = Vec3(x = 1.0, y = 2.0, z = 3.0)
  val back = Vec3(x = 0.5, y = 1.0, z = 1.5)
  var i = 0
  while i < 10000 {
    acc = acc + step - back
    i = i + 1
  }
  if acc.x < 0.0 {
    println(toString(acc.x))
  }
}

// ─── Scale and dot product ────────────────────────────────────────────────────
@bench
pub func benchVec3ScaleDot(): Unit {
  val a = Vec3(x = 1.0, y = 2.0, z = 3.0)
  var b = Vec3(x = 3.0, y = 2.0, z = 1.0)
  var sum = 0.0
  var i = 0
  while i < 10000 {
    b = scale(b, 0.5) + a
    sum = sum + dot(a, b)
    i = i + 1
  }
  if sum < 0.0 {
    println(toString(sum))
  }
}

// ─── Fixed array of positions ─────────────────────────────────────────────────
@bench
pub func benchVec3ArrayIntegrate(): Unit {
  val zero = Vec3(x = 0.0, y = 0.0, z = 0.0)
  var pos: array[8, Vec3] = [zero, zero, zero, zero, zero, zero, zero, zero]
  val vel = Vec3(x = 0.25, y = 0.5, z = 0.75)
  var step = 0
  while step < 1000 {
    for k in 0 ..< 8 {
      pos[k] = pos[k] + vel
    }
    step = step + 1
  }
  if pos[7].z < 0.0 {
    println(toString(pos[7].z))
  }
}
