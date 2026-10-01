//! std/secure_random.l - Cryptographically secure random number generation.
//!
//! All functions use System.Security.Cryptography.RandomNumberGenerator,
//! backed by the OS entropy source.  Suitable for security-sensitive values:
//! session tokens, cryptographic keys, nonces, API secrets, CSRF tokens.
//!
//! For non-security uses (simulations, games, test fixtures), prefer
//! Std.Random which is faster.
@runtime_checked
@io
package Std.SecureRandom

import Std.Core
import Std.SecureRandomHost

/// Cryptographically strong random integer in [0, max).
/// max must be positive.
@stable(since = "1.0")
pub func secureNextInt(max: in Int): Int
  requires: max > 0
  ensures: result >= 0 and result < max
{
  hostSecureNextInt(max)
}

/// Cryptographically strong random integer in [min, max), exactly uniform:
/// every integer in range is equally likely to be returned.  Both hosts
/// draw from a rejection-sampling algorithm bounded to the requested range
/// rather than reducing a wider draw with `%`, which would bias low values
/// toward `range / 2^N` of the underlying draw's width — this guarantee is
/// load-bearing for security-sensitive draws (tokens, OTP digits) where
/// even a small bias is a real distinguishing weakness.
/// min must be strictly less than max.
@stable(since = "1.0")
pub func secureNextIntRange(min: in Int, max: in Int): Int
  requires: min < max
  ensures: result >= min and result < max
{
  hostSecureNextIntRange(min, max)
}

/// Return a new byte slice of the given length filled with cryptographically
/// strong random bytes.  count must be >= 0.
@stable(since = "1.0")
pub func secureGetBytes(count: in Int): slice[Byte]
  requires: count >= 0
  ensures: result.length == count
{
  hostSecureGetBytes(count)
}
