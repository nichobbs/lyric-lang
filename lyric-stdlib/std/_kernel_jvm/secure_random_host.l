//! std/_kernel_jvm/secure_random_host.l — JVM host boundary for
//! java.security.SecureRandom (CSPRNG).
//!
//! Mirrors _kernel/secure_random_host.l for the JVM target.
//! All methods route through a process-wide SecureRandom instance backed by
//! the OS-level cryptographic entropy source (`/dev/urandom` on Linux,
//! `BCryptGenRandom` on Windows, `SecRandomCopyBytes` on macOS via JDK).
//!
//! Internal: only Std.SecureRandom should import this.
@axiom("java.security.SecureRandom conforms to its documented JDK contracts and produces cryptographically strong output; lyric.stdlib.jvm.SecureRandomHost wraps the strongest available algorithm")
package Std.SecureRandomHost

// Cryptographically strong random integer in [0, max).
// max must be positive; the shim panics with IllegalArgumentException otherwise.
@externTarget("lyric.stdlib.jvm.SecureRandomHost.nextInt")
pub func hostSecureNextInt(max: in Int): Int = ()

// Cryptographically strong random integer in [min, max).
// min must be strictly less than max.
@externTarget("lyric.stdlib.jvm.SecureRandomHost.nextIntRange")
pub func hostSecureNextIntRange(min: in Int, max: in Int): Int = ()

// Fill a new byte slice of the given length with cryptographically strong
// random bytes.  count must be >= 0.
@externTarget("lyric.stdlib.jvm.SecureRandomHost.getBytes")
pub func hostSecureGetBytes(count: in Int): slice[Byte] = ()
