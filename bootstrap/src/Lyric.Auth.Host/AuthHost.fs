/// Lyric.Auth.AuthHost — .NET host shim for JWT verification and API key comparison.
///
/// `lyric-auth/src/_kernel/net/auth_kernel.l` declares each entry point with
/// `@externTarget("Lyric.Auth.AuthHost.<method>")`; the emitter resolves those
/// references to the static methods below at codegen time, so Lyric code calling
/// through the kernel boundary produces a direct IL `call` into these methods.
///
/// JWT algorithm support (BCL-only path, no NuGet dependency):
///   HS256 — verified using HMAC-SHA256 (System.Security.Cryptography.HMACSHA256).
///   All other algorithms — return false (fail closed).  RS256 and public-key
///   algorithms require key material not available in this BCL-only path; full
///   `System.IdentityModel.Tokens.Jwt` support is tracked for follow-up (#443).
///
/// All three methods are designed to fail closed: any exception, malformed input,
/// or unsupported algorithm returns false / sets value="" and returns false, rather
/// than propagating.

namespace Lyric.Auth

open System
open System.Runtime.InteropServices
open System.Security.Cryptography
open System.Text
open System.Text.Json

[<Sealed; AbstractClass>]
type AuthHost private () =

    /// Decode a base64url-encoded segment to raw bytes.
    /// Returns None for a malformed or unpaddable segment.
    static let fromBase64Url (s: string) : byte[] option =
        let std = s.Replace('-', '+').Replace('_', '/')
        let paddedOpt : string option =
            match std.Length % 4 with
            | 0 -> Some std
            | 2 -> Some (std + "==")
            | 3 -> Some (std + "=")
            | _ -> None  // rem=1 is not valid base64url
        match paddedOpt with
        | None -> None
        | Some padded ->
            try Some (Convert.FromBase64String padded)
            with _ -> None

    /// Pull a single string claim from a raw UTF-8-decoded payload byte array.
    static let tryGetStringClaim (payloadBytes: byte[]) (key: string) : string option =
        try
            let json = Encoding.UTF8.GetString payloadBytes
            use doc  = JsonDocument.Parse json
            let mutable elem = Unchecked.defaultof<JsonElement>
            if doc.RootElement.TryGetProperty(key, &elem) then
                Option.ofObj (elem.GetString())
            else None
        with _ -> None

    /// Validate a Bearer JWT.
    ///
    /// Supports HS256 only via HMAC-SHA256 (BCL; no NuGet required).  Returns
    /// false immediately when `allowedAlgorithms` (comma-separated, case-sensitive)
    /// does not contain "HS256" — the parameter is enforced, not ignored.  RS256
    /// and other public-key algorithms are tracked in #443.
    static member verifyJwt(token: string, secret: string, issuer: string, audience: string, allowedAlgorithms: string) : bool =
        try
            let hsAllowed =
                allowedAlgorithms.Split(',')
                |> Array.exists (fun a -> a.Trim() = "HS256")
            if not hsAllowed then false
            else
            let parts = token.Split('.')
            if parts.Length <> 3 then false
            else
                let headerSeg  = parts.[0]
                let payloadSeg = parts.[1]
                let sigSeg     = parts.[2]
                match fromBase64Url headerSeg,
                      fromBase64Url payloadSeg,
                      fromBase64Url sigSeg with
                | None, _, _
                | _, None, _
                | _, _, None -> false
                | Some headerBytes, Some payloadBytes, Some sigBytes ->
                    let headerJson = Encoding.UTF8.GetString headerBytes
                    use headerDoc  = JsonDocument.Parse headerJson
                    let mutable algElem = Unchecked.defaultof<JsonElement>
                    let algOpt =
                        if headerDoc.RootElement.TryGetProperty("alg", &algElem)
                        then Option.ofObj (algElem.GetString())
                        else None
                    match algOpt with
                    | None -> false
                    | Some alg when alg = "HS256" ->
                        let message  = Encoding.UTF8.GetBytes(headerSeg + "." + payloadSeg)
                        let keyBytes = Encoding.UTF8.GetBytes secret
                        use hmac     = new HMACSHA256(keyBytes)
                        let expected = hmac.ComputeHash message
                        if not (CryptographicOperations.FixedTimeEquals(
                                    ReadOnlySpan<byte>(sigBytes),
                                    ReadOnlySpan<byte>(expected))) then false
                        else
                            let issOk =
                                String.IsNullOrEmpty issuer
                                || tryGetStringClaim payloadBytes "iss" = Some issuer
                            let audOk =
                                String.IsNullOrEmpty audience
                                || tryGetStringClaim payloadBytes "aud" = Some audience
                            issOk && audOk
                    | Some _ ->
                        // RS256 and other public-key algorithms require key material
                        // beyond what this BCL-only path exposes.  Fail closed.
                        false
        with _ -> false

    /// Extract a named claim from a JWT payload segment without re-verifying.
    ///
    /// Sets `value` to the claim string and returns true on success.
    /// Returns false and leaves `value` unchanged for any malformed input or
    /// absent claim.  Call only on tokens already accepted by `verifyJwt`.
    static member tryExtractClaim(token: string, claimKey: string, [<Out>] value: byref<string>) : bool =
        try
            let parts = token.Split('.')
            if parts.Length < 2 then false
            else
                match fromBase64Url parts.[1] with
                | None -> false
                | Some payloadBytes ->
                    match tryGetStringClaim payloadBytes claimKey with
                    | None   -> false
                    | Some s -> value <- s; true
        with _ -> false

    /// Constant-time byte-for-byte comparison of two strings (UTF-8 encoded).
    ///
    /// Returns true iff `provided` and `expected` encode identically.
    /// Uses `CryptographicOperations.FixedTimeEquals` which runs in time
    /// proportional to `expected.Length` regardless of where the strings differ,
    /// preventing timing-oracle attacks on API keys.
    static member verifyApiKey(provided: string, expected: string) : bool =
        if String.IsNullOrEmpty expected then false
        else
            let a = Encoding.UTF8.GetBytes(if String.IsNullOrEmpty provided then "" else provided)
            let b = Encoding.UTF8.GetBytes expected
            CryptographicOperations.FixedTimeEquals(ReadOnlySpan<byte>(a), ReadOnlySpan<byte>(b))
