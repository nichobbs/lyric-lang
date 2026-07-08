# lyric-auth

Transport-agnostic authentication library for [Lyric](https://github.com/nichobbs/lyric-lang). Ships JWT verification with algorithm pinning, claim extraction, constant-time API key comparison, and role-based access control helpers.

> **Status**: `Auth` (JWT verification, claim extraction, API-key comparison,
> role checks) is production-ready on both `.NET` and JVM via
> `Auth.Kernel.Net` / `Auth.Kernel.Jvm`. `Auth.Aspects.ValidateKey` (the
> B′-mode API-key aspect template) is verified on `.NET` but currently
> broken on JVM due to an unrelated, pre-existing self-hosted JVM
> aspect-weaver codegen bug (see "Platform parity" below) — this is
> independent of the `Auth.Kernel.Jvm` extern boundary, which is fully
> verified on both targets.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `dotnet` | .NET via `Auth.Kernel.Net` | Available — `Auth` and `Auth.Aspects` both verified |
| `jvm` | JVM via `Auth.Kernel.Jvm` | `Auth` available and verified (HMAC-SHA256 via `javax.crypto.Mac`/`SecretKeySpec`); `Auth.Aspects.ValidateKey` fails at runtime due to a pre-existing B′-mode aspect-weaver JVM codegen bug (`__LyricBModeCallContext` `NoSuchMethodError`), unrelated to this library — present before and independent of the kernel fix, tracked separately |

`jvm` is opt-in (`[features] default = ["dotnet"]` in `lyric.toml`); build
with `--target jvm --no-default-features --features jvm` to select it.

## Packages

| Package | Description |
|---|---|
| `Auth` | Core: `verifyJwt`, `extractClaim`, `verifyApiKey`, `rolesContain` |
| `Auth.Kernel.Net` | .NET extern boundary — HMAC-SHA256 via `System.Security.Cryptography.HMACSHA256.HashData` |
| `Auth.Kernel.Jvm` | JVM extern boundary — HMAC-SHA256 via `javax.crypto.Mac`/`SecretKeySpec` (JVM auto-FFI, no Maven dependency); all other JWT/claim/API-key logic is a pure-Lyric port shared in spirit with `Auth.Kernel.Net` |

## Installation

```toml
[dependencies]
"Lyric.Auth" = { path = "../lyric-auth" }
```

## Quick start

### JWT verification

```lyric
import Auth
import Std.Core

val secret = "your-secret-key"
val token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
val issuer = "https://example.com"
val audience = "my-app"

match Auth.verifyJwt(token, secret, issuer, audience, "HS256") {
  case Ok(_) -> {
    // Token is valid
    match Auth.extractClaim(token, "sub") {
      case Some(userId) -> {
        // Use userId
      }
      case None -> {
        // "sub" claim not found
      }
    }
  }
  case Err(e) -> {
    // Invalid token — check e.code for specific error
  }
}
```

### API key verification

```lyric
import Auth

val providedKey = "api_key_from_header"
val storedKey = "expected_api_key"

if Auth.verifyApiKey(providedKey, storedKey) {
  // Key is valid
} else {
  // Key is invalid
}
```

### Role-based access control

```lyric
import Auth
import Std.Core

val userRoles = "admin,moderator"
val requiredRole = "admin"

if Auth.rolesContain(userRoles, requiredRole) {
  // User has the required role
} else {
  // User lacks permission
}
```

## JWT verification

### Algorithm pinning

JWT verification enforces RFC 8725 §3.1 algorithm pinning to prevent common vulnerabilities:

- **Prevents `alg=none` forgery**: The library rejects tokens with the `none` algorithm regardless of signature validity.
- **Prevents HS256/RS256 confusion**: The algorithm string must match the expected algorithm exactly; symmetric and asymmetric schemes cannot be mixed.

Specify the expected algorithm when verifying:

```lyric
match Auth.verifyJwt(token, secret, issuer, audience, "HS256") {
  case Ok(_)  -> // Token is valid and issuer/audience matched
  case Err(e) -> // Token invalid; check e.code (ALG_REJECTED, BAD_SIGNATURE, etc.)
}
```

### Supported algorithms

| Algorithm | Secret type | Use case |
|---|---|---|
| `HS256` | Shared secret (String) | Symmetric; both parties share the same key |
| `RS256` | Public key (String, PEM format) | Asymmetric; only the public key is needed for verification |
| `HS512` | Shared secret (String) | Higher security variant of HS256 |
| `RS512` | Public key (String, PEM format) | Higher security variant of RS256 |

### Claims extraction

Extract individual claims from the JWT token. Claims return `Option[String]` since they may not be present:

```lyric
match Auth.extractClaim(token, "sub") {
  case Some(userId) -> {
    // Subject claim found
  }
  case None -> {
    // Subject claim not present
  }
}
```

## API key verification

Use constant-time comparison to prevent timing attacks:

```lyric
import Auth

// Compare against the stored API key
val storedKey = getUserApiKey()

if Auth.verifyApiKey(providedKeyFromRequest, storedKey) {
  // Grant access
}
```

The `verifyApiKey` function performs constant-time string comparison to prevent timing attacks. **Store API keys securely**: hash them before storage (e.g., SHA-256 or HMAC-SHA256 with a salt), then use `verifyApiKey` to compare the provided key (after hashing with the same algorithm and salt) against the stored hash. Never store plaintext API keys.

## Role-based access control

Validate user roles against a required permission:

```lyric
import Auth

val userRoles = extractRolesFromToken(claims)

if Auth.rolesContain(userRoles, "admin") {
  // User has admin role
}
```

The `userRoles` parameter is a comma-separated string of roles; the function checks if it contains the required role:

```lyric
// Example with multiple roles
val userRoles = "user,admin,moderator"

if Auth.rolesContain(userRoles, "admin") {
  // User has admin role
}
```

## Low-level API

### `verifyJwt`

Verify a JWT token and validate issuer/audience claims.

```lyric
pub func verifyJwt(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: not contains(toLower(allowedAlgorithms), "none")
```

| Parameter | Description |
|---|---|
| `token` | The JWT string to verify |
| `secret` | The secret (for HS256/HS512) or public key PEM (for RS256/RS512) |
| `issuer` | Expected `iss` claim value |
| `audience` | Expected `aud` claim value |
| `allowedAlgorithms` | Comma-separated allow-list of JWT `alg` values (e.g., `"HS256"` or `"HS256,RS256"`). Tokens with `alg: none` are always rejected. |

**Preconditions:**
- `secret` must be non-empty
- `allowedAlgorithms` must be a non-empty, comma-separated list of algorithms the caller is prepared to accept (e.g., `"HS256"` or `"RS256,RS512"`)
- `allowedAlgorithms` must NOT contain the `"none"` algorithm (case-insensitive). Passing `"HS256,none"` violates this precondition and will raise a contract violation at runtime.

Returns `Ok(Unit)` if signature and claims are valid; `Err(JwtError)` otherwise. The `JwtError.code` field contains fine-grained error information (`ALG_REJECTED`, `BAD_SIGNATURE`, `EXPIRED`, etc.).

### `verifyJwtWithSkew`

Verify a JWT token with a custom clock-skew leeway.

```lyric
pub func verifyJwtWithSkew(
  token: in String,
  secret: in String,
  issuer: in String,
  audience: in String,
  allowedAlgorithms: in String,
  clockSkewSeconds: in Int
): Result[Unit, JwtError]
  requires: secret.length > 0
  requires: allowedAlgorithms.length > 0
  requires: not contains(toLower(allowedAlgorithms), "none")
  requires: clockSkewSeconds >= 0
```

Like `verifyJwt`, but accepts an explicit clock-skew tolerance in seconds. Pass `0` for strict expiry (no leeway); pass `60` for the industry standard (the `verifyJwt` default).

**Preconditions:**
- Same as `verifyJwt`: `secret` and `allowedAlgorithms` must be non-empty, and `allowedAlgorithms` must not contain `"none"`
- `clockSkewSeconds` must be non-negative (0 or greater)

### `extractClaim`

Extract a claim value from a JWT token.

```lyric
pub func extractClaim(
  token: in String,
  claimKey: in String
): Option[String]
  requires: claimKey.length > 0
```

| Parameter | Description |
|---|---|
| `token` | The JWT string (already verified by `verifyJwt`) |
| `claimKey` | The claim key to extract (e.g., `"sub"`, `"iss"`, `"org"`) |

**Preconditions:**
- `claimKey` must be non-empty

Returns `Some(value)` if the claim is present; `None` otherwise.

### `verifyApiKey`

Verify an API key using constant-time string comparison to prevent timing attacks.

```lyric
pub func verifyApiKey(
  provided: in String,
  expected: in String
): Bool
  requires: expected.length > 0
```

| Parameter | Description |
|---|---|
| `provided` | The API key provided by the client |
| `expected` | The valid API key to compare against (from storage) |

**Preconditions:**
- `expected` must be non-empty

**Note**: The function performs constant-time string comparison. For production use, store API keys securely (e.g., hashed with SHA-256 or HMAC-SHA256 using a salt); hash the incoming key and compare the hashes using this function to prevent credential exposure on database compromise.

### `rolesContain`

Check if a comma-separated role string contains a required role.

```lyric
pub func rolesContain(
  allowedRoles: in String,
  role: in String
): Bool
```

| Parameter | Description |
|---|---|
| `allowedRoles` | Comma-separated list of roles (e.g., `"admin,user,moderator"`) |
| `role` | The role to check for (e.g., `"admin"`) |

Returns `true` if `allowedRoles` contains the specified `role`. Whitespace around roles is trimmed automatically.

## Package layout

```
lyric-auth/
  lyric.toml              package manifest
  README.md               this file
  src/
    auth.l                Auth  (JWT, claims, API key, roles)
    auth_aspects.l        Auth.Aspects  (planned aspect templates)
    _kernel/
      net/
        auth_kernel.l     Auth.Kernel.Net  (.NET extern boundary)
      jvm/
        auth_kernel.l     Auth.Kernel.Jvm  (JVM extern boundary)
  tests/
    *_tests.l             test modules
```

## See also

- `docs/26-aspects.md` §18 — aspect template design and instantiation rules
- `docs/03-decision-log.md` — design decisions
