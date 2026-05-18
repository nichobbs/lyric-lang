// std/secure_random.l - Cryptographically secure random number generation.
//
// All functions use System.Security.Cryptography.RandomNumberGenerator,
// backed by the OS entropy source.  Suitable for security-sensitive values:
// session tokens, cryptographic keys, nonces, API secrets, CSRF tokens.
//
// For non-security uses (simulations, games, test fixtures), prefer
// Std.Random which is faster.

package Std.SecureRandom

import Std.Core
import Std.SecureRandomHost

/// Cryptographically strong random integer in [0, max).
/// max must be positive.
@stable(since="1.0")
pub func secureNextInt(max: in Int): Int { hostSecureNextInt(max) }

/// Cryptographically strong random integer in [min, max).
/// min must be strictly less than max.
@stable(since="1.0")
pub func secureNextIntRange(min: in Int, max: in Int): Int {
  hostSecureNextIntRange(min, max)
}

/// Return a new byte slice of the given length filled with cryptographically
/// strong random bytes.  count must be >= 0.
@stable(since="1.0")
pub func secureGetBytes(count: in Int): slice[Byte] { hostSecureGetBytes(count) }
