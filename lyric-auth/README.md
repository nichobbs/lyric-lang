# lyric-auth

Transport-agnostic authentication library for [Lyric](https://github.com/nichobbs/lyric-lang). Ships JWT verification with algorithm pinning, claim extraction, constant-time API key comparison, and role-based access control helpers.

> **Status**: Library source is complete. Both `.NET` and JVM backends are available via `Auth.Kernel.Net` / `Auth.Kernel.Jvm`.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `dotnet` | .NET via `Auth.Kernel.Net` | Available |
| `jvm` | JVM via `Auth.Kernel.Jvm` | Available |

## Packages

| Package | Description |
|---|---|
| `Auth` | Core: `verifyJwt`, `extractClaim`, `verifyApiKey`, `rolesContain` |
| `Auth.Kernel.Net` | .NET extern boundary |
| `Auth.Kernel.Jvm` | JVM extern boundary |

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

match Auth.verifyJwt(token, secret, { algorithm: "HS256" }) {
  case Ok(claims) -> {
    // Extract claims
    val userId = Auth.extractClaim(claims, "sub")
    // Use the verified claims
  }
  case Err(e) -> {
    // Invalid token
  }
}
```

### API key verification

```lyric
import Auth

val providedKey = "api_key_from_header"
val storedHash = "hashed_api_key_from_db"

if Auth.verifyApiKey(providedKey, storedHash) {
  // Key is valid
} else {
  // Key is invalid
}
```

### Role-based access control

```lyric
import Auth
import Std.Core

val userRoles = ["admin", "moderator"]
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
- **Prevents HS256/RS256 confusion**: The algorithm parameter must match the expected algorithm exactly; symmetric and asymmetric schemes cannot be mixed.

Specify the expected algorithm when verifying:

```lyric
match Auth.verifyJwt(token, secret, { algorithm: "HS256" }) {
  case Ok(claims) -> // Token is valid
  case Err(e)     -> // Token is invalid
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

Extract individual claims from the verified token:

```lyric
val userId = Auth.extractClaim(verifiedClaims, "sub")  // subject
val issuer = Auth.extractClaim(verifiedClaims, "iss")  // issuer
val custom = Auth.extractClaim(verifiedClaims, "org")  // custom claim
```

## API key verification

Use constant-time comparison to prevent timing attacks:

```lyric
import Auth

// Store the API key hash, never the plain key
val userApiKeyHash = computeHash(userProvidedKey)

if Auth.verifyApiKey(providedKeyFromRequest, userApiKeyHash) {
  // Grant access
}
```

The `verifyApiKey` function performs constant-time comparison, preventing attackers from determining valid characters by measuring response times.

## Role-based access control

Validate user roles against required permissions:

```lyric
import Auth

val userRoles = extractRolesFromToken(claims)
val requiredRoles = ["admin"]

if Auth.rolesContain(userRoles, requiredRoles) {
  // User has admin role
}
```

The `rolesContain` function supports both single-role and multi-role checks:

```lyric
// Single role check
if Auth.rolesContain(userRoles, "admin") {
  // ...
}

// Multiple acceptable roles
if Auth.rolesContain(userRoles, ["admin", "moderator"]) {
  // User has at least one of the roles
}
```

## Low-level API

### `verifyJwt`

Verify a JWT token and extract claims.

```lyric
pub func verifyJwt(
  token: in String,
  secret: in String,
  options: in JwtOptions
): Result[Claims, AuthError]
```

| Parameter | Description |
|---|---|
| `token` | The JWT string to verify |
| `secret` | The secret or public key (format depends on algorithm) |
| `options` | Configuration including the expected algorithm |

### `extractClaim`

Extract a claim value from verified claims.

```lyric
pub func extractClaim(
  claims: in Claims,
  claimName: in String
): Option[String]
```

| Parameter | Description |
|---|---|
| `claims` | The verified claims object |
| `claimName` | The claim name to extract (e.g., `"sub"`, `"iss"`, `"org"`) |

Returns `None` if the claim is not present.

### `verifyApiKey`

Verify an API key using constant-time comparison.

```lyric
pub func verifyApiKey(
  providedKey: in String,
  storedHash: in String
): Bool
```

| Parameter | Description |
|---|---|
| `providedKey` | The API key provided by the client |
| `storedHash` | The hash of the valid API key (from storage) |

### `rolesContain`

Check if a user's roles contain a required role.

```lyric
pub func rolesContain(
  userRoles: in [String],
  requiredRoles: in [String]
): Bool
```

| Parameter | Description |
|---|---|
| `userRoles` | The user's assigned roles |
| `requiredRoles` | The required role(s) |

Returns `true` if the user has at least one of the required roles.

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
