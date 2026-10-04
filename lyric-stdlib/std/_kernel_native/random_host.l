//! std/_kernel_native/random_host.l - native twin of `_kernel/random_host.l`:
//! a pure-Lyric xorshift64 PRNG behind the same `Std.RandomHost` surface.
//!
//! WARNING: like `System.Random`, this is a PRNG, NOT a cryptographically
//! secure RNG: use `Std.SecureRandom` for security-sensitive uses. xorshift64
//! uses only xor and shifts, so there is no arithmetic that could overflow.
//!
//! Differences from the dotnet twin, none observable through `Std.Random`'s
//! contract: a `Random` is a record holding the generator state, and
//! `hostSharedRandom` returns a fresh generator seeded from OS entropy on
//! every call (not one shared instance), so it is thread-safe with no lock.
//! `hostMakeRandom(seed)` is deterministic: the same seed gives the same
//! sequence (the sequence differs from .NET's).
//!
//! Internal: only Std.Random should import this.
@axiom("lyric_uuid_v4 (lyric-rt) draws from the OS entropy source and returns a canonical 36-character UUID string")
@io
package Std.RandomHost

import Std.Core

extern func rtUuidV4(): String = "lyric_uuid_v4"

/// A generator. `state` is never zero (xorshift's one absorbing state).
pub record Random {
  var state: Long
}

func hexDigit(c: in Int): Long {
  if c >= 48 and c <= 57 {
    (c - 48).toLong()
  } else if c >= 97 and c <= 102 {
    (c - 97 + 10).toLong()
  } else if c >= 65 and c <= 70 {
    (c - 65 + 10).toLong()
  } else {
    0i64
  }
}

// The first 16 hex digits of a fresh random UUID, as a Long: 64 bits of OS
// entropy.
func entropySeed(): Long {
  val u = rtUuidV4()
  var acc = 0i64
  var taken = 0
  var i = 0
  while i < u.length and taken < 16 {
    val c = u.codeUnitAt(i)
    if c != 45 {
      acc = acc.shl(4).or(hexDigit(c))
      taken = taken + 1
    }
    i = i + 1
  }
  acc
}

func nonZero(seed: in Long): Long {
  if seed == 0i64 {
    88172645463325252i64
  } else {
    seed
  }
}

pub func hostSharedRandom(): Random {
  Random(state = nonZero(entropySeed()))
}

pub func hostMakeRandom(seed: in Int): Random {
  // Spread a small seed over the state so nearby seeds do not start close.
  Random(state = nonZero(seed.toLong().shl(32).xor(seed.toLong()).xor(0x2545F4914F6CDD1Di64)))
}

// xorshift64 (13, 7, 17), with the right shift made logical by masking.
func step(rng: in Random): Long {
  var x = rng.state
  x = x.xor(x.shl(13))
  x = x.xor(x.shr(7).and(0x01FFFFFFFFFFFFFFi64))
  x = x.xor(x.shl(17))
  rng.state = x
  x
}

pub func hostNextInt(rng: in Random): Int {
  step(rng).shr(33).and(0x7FFFFFFFi64).toInt()
}

// Uniform in [0, bound): rejection sampling over 63 bits, so no value is
// favoured (a plain `%` would bias the low ones).
func bounded(rng: in Random, bound: in Long): Long {
  val maxLong = 9223372036854775807i64
  val remainder = (maxLong % bound + 1i64) % bound
  var v = step(rng).and(maxLong)
  while v > maxLong - remainder {
    v = step(rng).and(maxLong)
  }
  v % bound
}

/// Random integer in `[0, max)`.
pub func hostNextIntBelow(rng: in Random, max: in Int): Int {
  if max <= 0 {
    panic("Std.Random: max must be positive")
  }
  bounded(rng, max.toLong()).toInt()
}

/// Random integer in `[min, max)`.
pub func hostNextIntRange(rng: in Random, min: in Int, max: in Int): Int {
  if min >= max {
    panic("Std.Random: min must be below max")
  }
  (min.toLong() + bounded(rng, max.toLong() - min.toLong())).toInt()
}

pub func hostNextLong(rng: in Random): Long {
  step(rng)
}

pub func hostNextDouble(rng: in Random): Double {
  step(rng).shr(11).and(0x1FFFFFFFFFFFFFi64).toDouble() / 9007199254740992.0
}
