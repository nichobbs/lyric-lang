/// Lyric.Auth.AuthHost — thin BCL shim for JWT and API-key crypto primitives.
///
/// `lyric-auth/src/_kernel/net/auth_kernel.l` orchestrates full JWT verification
/// and API-key comparison in Lyric, calling through these two externs only for
/// operations that require BCL crypto primitives:
///
///   hmacSha256       — HMAC-SHA256 signature computation (HMACSHA256.ComputeHash)
///   fixedTimeEquals  — byte-content-constant-time comparison (FixedTimeEquals)
///
/// All parsing, JSON scanning, base64url decoding, claim extraction, exp/nbf
/// validation, and algorithm allow-list enforcement live in auth_kernel.l so that
/// only the truly BCL-bound operations cross this boundary.
///
/// FixedTimeEquals semantics: constant-time for equal-length inputs; exits
/// immediately when lengths differ (so the expected key's byte length may be
/// inferred from timing).  For fixed-format keys the length is not secret.

namespace Lyric.Auth

open System.Security.Cryptography

[<Sealed; AbstractClass>]
type AuthHost private () =

    /// Compute HMAC-SHA256 of `message` using `key`.
    /// Returns the raw 32-byte MAC as a byte array.
    static member hmacSha256(key: byte[], message: byte[]) : byte[] =
        use hmac = new HMACSHA256(key)
        hmac.ComputeHash message

    /// Byte-content-constant-time comparison of `a` and `b`.
    /// Returns true iff both have equal length and identical content.
    /// Constant-time for equal-length inputs; exits immediately on length
    /// mismatch (the expected byte length may be inferred from timing).
    static member fixedTimeEquals(a: byte[], b: byte[]) : bool =
        CryptographicOperations.FixedTimeEquals(
            System.ReadOnlySpan<byte>(a),
            System.ReadOnlySpan<byte>(b))
