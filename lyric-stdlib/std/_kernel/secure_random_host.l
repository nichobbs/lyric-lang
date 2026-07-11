//! std/_kernel/secure_random_host.l - host boundary for
//! System.Security.Cryptography.RandomNumberGenerator (CSPRNG).
//!
//! All methods here use the OS-level cryptographic entropy source and are
//! safe for security-sensitive values (tokens, keys, nonces, session IDs).
//!
//! Internal: only Std.SecureRandom should import this.
@axiom("System.Security.Cryptography.RandomNumberGenerator conforms to its documented .NET contracts and produces cryptographically strong output")
package Std.SecureRandomHost

extern type SecureRng = "System.Security.Cryptography.RandomNumberGenerator"

/// Cryptographically strong random integer in [0, max).
/// max must be positive; BCL throws ArgumentOutOfRangeException otherwise.
pub func hostSecureNextInt(max: in Int): Int {
  SecureRng.GetInt32(max)
}

/// Cryptographically strong random integer in [min, max).
/// min must be < max; BCL throws ArgumentOutOfRangeException otherwise.
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int {
  SecureRng.GetInt32(min, max)
}

/// Fill a new byte slice of the given length with cryptographically
/// strong random bytes.  count must be >= 0.
pub func hostSecureGetBytes(count: in Int): slice[Byte] {
  SecureRng.GetBytes(count)
}
