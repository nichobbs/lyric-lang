//! std/_kernel/secure_random_host.l - host boundary for
//! System.Security.Cryptography.RandomNumberGenerator (CSPRNG).
//!
//! All methods here use the OS-level cryptographic entropy source and are
//! safe for security-sensitive values (tokens, keys, nonces, session IDs).
//!
//! Internal: only Std.SecureRandom should import this.
@axiom("System.Security.Cryptography.RandomNumberGenerator conforms to its documented .NET contracts and produces cryptographically strong output")
package Std.SecureRandomHost

/// Cryptographically strong random integer in [0, max).
/// max must be positive; BCL throws ArgumentOutOfRangeException otherwise.
@externTarget("System.Security.Cryptography.RandomNumberGenerator.GetInt32")
pub func hostSecureNextInt(max: in Int): Int = ()

/// Cryptographically strong random integer in [min, max).
/// min must be < max; BCL throws ArgumentOutOfRangeException otherwise.
@externTarget("System.Security.Cryptography.RandomNumberGenerator.GetInt32")
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int = ()

/// Fill a new byte slice of the given length with cryptographically
/// strong random bytes.  count must be >= 0.
@externTarget("System.Security.Cryptography.RandomNumberGenerator.GetBytes")
pub func hostSecureGetBytes(count: in Int): slice[Byte] = ()
