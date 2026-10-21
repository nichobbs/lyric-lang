//! rng.l - Game.Rng: a small deterministic generator (docs/67 G7).
//!
//! `Std.Random` is backed by the host, so its sequence differs between targets and runtimes.  A
//! game that must replay exactly keeps its randomness in its state and draws it from here: a
//! 64-bit xorshift whose sequence is defined by this file alone.
package Game.Rng

import Std.Core

pub record Rng {
  var state: Long
}

/// A generator seeded with `seed`.  Distinct seeds give distinct sequences (sixteen draws are discarded so that nearby seeds diverge).
pub func seeded(seed: in Long): Rng {
  var state = seed.xor(0x2545F4914F6CDD1Di64)
  if state == 0i64 {
    state = 0x2545F4914F6CDD1Di64
  }
  val r = Rng(state = state)
  var i = 0
  while i < 16 {
    val _ = nextInt(r)
    i = i + 1
  }
  r
}

/// The next 32 random bits as a non-negative `Int`.
pub func nextInt(r: in Rng): Int
  ensures: result >= 0
{
  var x = r.state
  x = x.xor(x.shl(13))
  x = x.xor(x.shr(7).and(0x01FFFFFFFFFFFFFFi64))
  x = x.xor(x.shl(17))
  r.state = x
  x.shr(33).and(0x7FFFFFFFi64).toInt()
}

/// An integer in `[0, bound)`.
pub func nextBelow(r: in Rng, bound: in Int): Int
  requires: bound > 0
  ensures: result >= 0 and result < bound
{
  nextInt(r) % bound
}

/// A float in `[0, 1)`.
pub func nextUnit(r: in Rng): Float
  ensures: result >= 0.0f32 and result < 1.0f32
{
  (nextInt(r) % 16777216).toFloat() / 16777216.0f32
}
