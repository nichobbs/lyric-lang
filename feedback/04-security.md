# Security Review — Lyric Ecosystem Libraries

**Review date:** 2026-05-17
**Scope:** lyric-auth, lyric-aws-secrets, lyric-aws-xray, lyric-lambda, lyric-web,
lyric-ws, lyric-session, lyric-storage, lyric-grpc, lyric-proto, lyric-db, lyric-mail,
lyric-validation, lyric-feature-flags, lyric-i18n, stdlib/std/http.l, stdlib/std/rest.l,
stdlib/std/_kernel/process_host.l, stdlib/std/process.l

---

## Executive Summary

The Lyric library ecosystem shows a genuinely security-conscious design. Cookie defaults
are secure (HttpOnly=true, Secure=true, SameSite=Lax), the DB interface is parameterised
only, constant-time API-key comparison is correctly specified, and the CORS config is
explicit rather than implicit. The aspect-based auth model cleanly separates JWT
verification from transport concerns.

However, the review found 21 substantive findings ranging from a CRITICAL algorithmic
flaw (alg=none / symmetric-to-asymmetric confusion in JWT), through several HIGH issues
(CORS wildcard default, session fixation, path traversal escape, log injection, TLS
not enforced on the remote flag poller), to a cluster of MEDIUM/LOW issues affecting
defence in depth.

---

## Critical Vulnerabilities

### FINDING-01 — JWT Algorithm Confusion / alg=none Attack

**Severity:** CRITICAL
**Vulnerability type:** Broken Authentication (OWASP A07:2021)
**CWE:** CWE-347 (Improper Verification of Cryptographic Signature)
**Location:** `lyric-auth/src/_kernel/net/auth_kernel.l:21-27`,
`lyric-auth/src/auth.l:44-53`

**Description:**
`Auth.verifyJwt` accepts `secret: String` and is documented to support both
HMAC-SHA256 (HS256) and RS256. The kernel declaration is:

```
pub func verifyJwt(token: String, secret: String, issuer: String, audience: String): Bool
```

When the underlying `System.IdentityModel.Tokens.Jwt` implementation reads the
algorithm from the token header rather than from a caller-supplied allowed-algorithms
list, three attack classes become possible:

1. **alg=none** — An attacker forges a token with `"alg":"none"` and no signature.
   If the BCL implementation is configured to allow it (older or misconfigured versions),
   `verifyJwt` returns `true`.
2. **HS256/RS256 confusion** — If the server uses RS256 but the public key is known
   (e.g. downloaded from a JWKS endpoint), an attacker signs a token with HS256 using
   the public key as the HMAC secret. A naive validator that accepts both algorithms
   without pinning the expected one will verify the forged token as valid.
3. **kid injection** — The `secret` parameter carries a single scalar; there is no
   `kid`-to-key mapping. If the BCL shim performs any header-field lookup, an attacker
   controlling the `kid` header value may steer key selection.

The API surface (`secret: String`) cannot distinguish whether that string is an HMAC
symmetric key or an RSA public key. There is no `expectedAlgorithm` or `allowedAlgorithms`
parameter anywhere in the call chain.

**Exploit scenario:**
Attacker POSTs a crafted JWT to an API protected by `Web.Aspects.RequiresAuth`. The
token header contains `"alg":"none"`, the payload claims are arbitrary. The BCL
`JwtSecurityTokenHandler` returns success if algorithm validation is absent. The
aspect proceeds, treating the request as authenticated.

**Impact:** Complete authentication bypass across all HTTP, WebSocket, and gRPC
endpoints protected by RequiresAuth, RequiresRole, WsAuth, RequiresGrpcAuth.

**Remediation:**
1. Add an `allowedAlgorithms: [String]` parameter to `Auth.verifyJwt` and forward it
   to `TokenValidationParameters.ValidAlgorithms` in the BCL shim.
2. Set `TokenValidationParameters.RequireSignedTokens = true` and
   `TokenValidationParameters.ValidateIssuerSigningKey = true` in the BCL shim.
3. Fail closed when `allowedAlgorithms` is empty rather than accepting any algorithm.
4. Default to `["HS256"]` when only a symmetric secret is supplied; never accept
   `"none"`.

**OWASP reference:** A07:2021 — Identification and Authentication Failures;
JWT Security Best Practices (RFC 8725 §3.1).

---

### FINDING-02 — Session Fixation: `set()` Creates Sessions for Unknown IDs

**Severity:** CRITICAL
**Vulnerability type:** Session Fixation (OWASP A07:2021)
**CWE:** CWE-384
**Location:** `lyric-session/src/session.l:199-219` (`NativeSessionStore.set`),
`lyric-session/src/session.l:342-365` (`InProcessSessionStore.set`)

**Description:**
Both `NativeSessionStore.set` and `InProcessSessionStore.set` contain a
`case None` branch that constructs a full `SessionData` using the caller-supplied
`sessionId` without verifying that the ID was issued by the server:

```
case None ->
  val ts = nowMs()
  SessionData(
    id             = sessionId,   // <-- attacker-controlled
    ...
  )
```

An attacker who knows or guesses a target user's session ID (or who plants a
`LYRIC_SESSION` cookie in the victim's browser via a fixation vector) can call
`set()` to materialise a session for that ID before the legitimate user logs in.
When the user authenticates, the application may elevate the existing session rather
than issuing a new one.

**Exploit scenario:**
Attacker tricks a victim into visiting a URL that sets `LYRIC_SESSION=<known-value>`
(via a link, XSS, or subdomain cookie taint). Victim logs in; the application calls
`Session.set(store, knownId, "userId", "42")`, creating a session the attacker can
reuse because they already know its ID.

**Impact:** Account takeover for any user who accepts the planted cookie.

**Remediation:**
1. Remove the `case None` creation branch from `set()`, `delete()`, and `clear()`.
   These operations should fail (return an appropriate error) when the session does
   not already exist rather than auto-creating one.
2. Ensure authentication and privilege escalation handlers call `Session.destroy()` on
   the old session and `Session.create()` to obtain a fresh ID before binding
   credentials to the session. Document this as a required pattern.
3. In `InProcessSessionStore.load()`, confirm that TTL expiry is checked on every
   access path; it is currently checked in `load` but the `set` bypass sidesteps it.

---

## High-Priority Issues

### FINDING-03 — CORS Default Allows All Origins (`allowedOrigins = "*"`)

**Severity:** HIGH
**Vulnerability type:** Security Misconfiguration (OWASP A05:2021)
**CWE:** CWE-942
**Location:** `lyric-web/src/web.l:278`

**Description:**
The `Cors` config block defaults `allowedOrigins` to `"*"`:

```
config Cors {
  enabled:        Bool   = false
  allowedOrigins: String = "*"
  ...
}
```

Although CORS is disabled by default (`enabled = false`), when a developer enables
it by setting `LYRIC_CONFIG_WEB_CORS_ENABLED=true`, the effective policy immediately
becomes `Access-Control-Allow-Origin: *` unless `allowedOrigins` is also overridden.
This is a dangerous default: enabling a feature flag should not silently open a
cross-origin backdoor.

A wildcard CORS policy combined with `Access-Control-Allow-Credentials: true` would
be a critical finding. The current CORS config has no `allowCredentials` field, so
that specific combination is not currently reachable; however the wildcard still
allows any origin to read non-credentialed responses, which matters for APIs that
rely on network topology as a security boundary.

**Exploit scenario:**
Developer sets `LYRIC_CONFIG_WEB_CORS_ENABLED=true` to unblock a front-end integration
test without changing the origins list. An attacker-controlled page at any origin
can now make cross-site requests to the API and read responses.

**Remediation:**
Change the default to an empty string and require explicit configuration:
```
config Cors {
  enabled:        Bool   = false
  allowedOrigins: String = ""   // required when enabled = true
  ...
}
```
Validate at startup that `allowedOrigins` is non-empty when `enabled = true`, and
document that `"*"` must never be used with authenticated APIs.

---

### FINDING-04 — Path Traversal Bypass in `Storage.Aspects.ValidateKey`

**Severity:** HIGH
**Vulnerability type:** Path Traversal (OWASP A01:2021)
**CWE:** CWE-22
**Location:** `lyric-storage/src/storage_aspects.l:119-133`

**Description:**
The `ValidateKey` aspect rejects keys containing the literal substring `".."`, but
the implementation comment itself flags the incompleteness:

```
// Assumption: the kernel pre-decodes percent-encoded paths and normalises
// path separators before the key reaches this aspect.  URL-encoded variants
// (%2e%2e, ..%2f) and Windows backslash separators are not caught here.
```

No evidence exists in the kernel declaration (`storage_kernel.l:121-157`) that any
normalisation actually occurs before the Lyric-side key is stored. Keys stored to the
local filesystem backend pass through as raw strings. The following sequences escape
the check and traverse directories:

- `%2e%2e/secret` (URL-encoded)
- `..%2ffile` (mixed)
- `..\file` (Windows backslash)
- `....//` (after naive collapsing)

**Exploit scenario:**
Caller invokes `Storage.put(bucket, "../../../etc/passwd", ...)` or passes a
percent-encoded variant. The `containsDotDot` helper sees no literal `..`, the
aspect passes, and the local backend writes or reads outside the configured
`basePath`.

**Impact:** Arbitrary file read/write outside the configured storage root on the local
filesystem backend. S3 and Azure backends treat keys as opaque object names so the
impact there is limited to object enumeration beyond the intended prefix.

**Remediation:**
1. Decode percent-encoding in the key before running the `containsDotDot` check.
2. Normalise path separators (replace `\` with `/`) before checking.
3. After normalisation, verify the resolved path still begins with the configured
   `basePath` (for the local backend, perform an absolute path prefix check inside
   the kernel rather than in the Lyric-side aspect).
4. Reject keys that are empty, start with `/`, or contain null bytes.

---

### FINDING-05 — Feature-Flag Remote Poller Does Not Enforce TLS

**Superseded (D-progress-627):** `Flags.connectRemote()` never actually
existed in `flags.l` — it was aspirational documentation only, quoted
here as if it were real code. `lyric-feature-flags/src/_kernel/`
(the second location cited below) was deleted entirely in
D-progress-627 as confirmed 100% dead code with zero callers. This
finding is moot against code that no longer exists (and, per
D-progress-627's investigation, never did). If a real remote-polling
`FlagStore` is built in the future, its URL scheme validation should
be revisited against this finding's underlying concern.

**Severity:** HIGH
**Vulnerability type:** Sensitive Data Exposure / Insufficient Transport Layer Security (OWASP A02:2021)
**CWE:** CWE-319
**Location:** `lyric-feature-flags/src/flags.l:217-228`,
`lyric-feature-flags/src/_kernel/net/flags_kernel.l:24-46`

**Description:**
`Flags.connectRemote()` accepts an arbitrary `Remote.url` string and passes it
directly to the kernel HTTP polling client without requiring the `https://` scheme:

```
pub func connectRemote(): Result[FlagStore, FlagError] {
  match Flags.Kernel.Net.connect(
    Remote.url,
    Remote.apiKey,
    ...
```

The `Remote.url` config field has no scheme validation (contrast with `Std.Http.Url.tryFrom`
which explicitly requires `http://` or `https://`). A misconfigured deployment that
sets `LYRIC_CONFIG_REMOTE_URL=http://flags.internal/` will transmit `Remote.apiKey`
(a `@sensitive` field) in plaintext. Because the polling loop runs in the background,
the plaintext transmission is recurring.

**Exploit scenario:**
An internal network attacker (or a misconfigured DNS entry pointing the flag endpoint
to an attacker-controlled host) receives the `apiKey` header in plaintext on every
poll cycle (default: every 30 seconds). The key is then used to inject malicious flag
values that disable security controls (e.g. set `auth-enabled = false`).

**Impact:** Credential theft; flag store manipulation; potential disabling of
authentication or other kill-switch flags.

**Remediation:**
1. Validate `Remote.url` at `connectRemote()` time using `Std.Http.Url.tryFrom` or
   equivalent, and reject `http://` URLs when `apiKey` is non-empty.
2. Prefer requiring `https://` unconditionally.
3. Add a startup assertion in the kernel client to refuse plaintext connections.

---

### FINDING-06 — Log Injection via User-Controlled Data in AwsXRay Tracing Aspect

**Severity:** HIGH
**Vulnerability type:** Log Injection (OWASP A09:2021)
**CWE:** CWE-117
**Location:** `lyric-aws-xray/src/xray.l:119`

**Description:**
The `AwsXRay.Tracing` aspect captures the error value from a handler's `Err(e)`
result and passes it directly to `XRayKernel.addAnnotation` as the value:

```
match ret {
  Err(e) => XRayKernel.addAnnotation(seg, "error", e.toString())
  _      => ()
}
```

X-Ray annotation values appear in the AWS X-Ray console and are searchable via
filter expressions. If `e.toString()` contains user-controlled content (e.g. a
validation error that echoes back the submitted value, a parsed field from a
malicious request body), an attacker can inject arbitrary annotation key-value
content. Depending on how the downstream trace viewer renders annotations, this
can mislead operators, produce false-positive or false-negative security alerts,
or — in a naive console viewer — introduce XSS if annotations are rendered as HTML
without escaping.

Beyond X-Ray, the same pattern appears in `Lambda.Aspects.EventLogging`:

```
val outcome = match ret { Ok(_) => "ok"; Err(_) => "err" }
Std.Core.log(logLevel, call.qualifiedName + " " + outcome + " " + elapsedMs.toString() + "ms")
```

Here `outcome` is safe, but any future expansion that logs `Err` content must apply
the same scrutiny.

**Exploit scenario:**
A malicious request causes a handler to return `Err(ApiError(message = "<script>alert(1)</script> OR 1=1"))`.
The X-Ray console renders the annotation value without HTML encoding. An operator
viewing the trace experiences a stored XSS payload in the AWS console.

**Remediation:**
1. Before passing error strings to `addAnnotation`, strip or escape newlines (`\n`,
   `\r`), null bytes, and angle brackets.
2. Define a `sanitizeAnnotationValue(s: String): String` helper in `AwsXRay` that
   enforces a safe character set (printable ASCII, max length) and use it in the
   `Tracing` aspect.
3. For general logging, define a `Std.Log.sanitize(s: String): String` helper and
   document its use whenever user-supplied content enters a log message.

---

### FINDING-07 — Redis URL Contains Credentials in Plaintext Config

**Severity:** HIGH
**Vulnerability type:** Sensitive Data Exposure (OWASP A02:2021)
**CWE:** CWE-312
**Location:** `lyric-session/src/session.l:417-421`

**Description:**
The `RedisSession.url` config field is a plain `String` with no `@sensitive`
annotation:

```
config RedisSession {
  url:       String
  keyPrefix: String = "session:"
}
```

Redis connection strings routinely embed authentication credentials:
`redis://:password@host:6379/0` or `rediss://user:password@host:6379`. Because
`url` lacks `@sensitive`, the config framework will not mask the value in log
output, diagnostic dumps, or error messages that echo configuration. This means
the Redis password can appear in structured logs shipped to a log aggregator,
where it is retained and accessible to anyone with log-read access.

**Remediation:**
Mark `url` as `@sensitive`:
```
config RedisSession {
  @sensitive
  url:       String
  keyPrefix: String = "session:"
}
```
Alternatively, split the connection string into separate host/port and `@sensitive`
password fields so only the credential portion is masked.

---

### FINDING-08 — Presigned URL Has No Maximum TTL Cap

**Severity:** HIGH
**Vulnerability type:** Broken Access Control (OWASP A01:2021)
**CWE:** CWE-285
**Location:** `lyric-storage/src/storage.l:128-129`, `lyric-storage/src/storage.l:343-351`

**Description:**
The `StorageBucket.presignedUrl` interface contract only requires `expiresInSeconds >= 1`:

```
func presignedUrl(
  key:              in String,
  expiresInSeconds: in Int
): Result[String, StorageError]
  requires: key.length > 0
  requires: expiresInSeconds >= 1
```

There is no upper bound. A caller can request a presigned URL valid for
`expiresInSeconds = 2147483647` (24+ years). AWS S3 caps presigned URLs at 7 days
for SigV4 signatures, but the Lyric layer accepts any positive integer and makes no
attempt to warn or cap. Azure SAS tokens have similar limits. An internal bug or
a compromised caller that emits extremely long-lived URLs creates persistent,
unrevocable access to objects.

**Exploit scenario:**
An internal service generates a presigned URL for a customer document with a 10-year
TTL. The URL leaks (via logs, cache, a shared link). The customer's document is
permanently accessible to anyone who obtains the URL, even after account deletion
or data-retention policies are applied.

**Remediation:**
Add a maximum TTL to the `presignedUrl` contract:
```
func presignedUrl(
  key:              in String,
  expiresInSeconds: in Int
): Result[String, StorageError]
  requires: key.length > 0
  requires: expiresInSeconds >= 1
  requires: expiresInSeconds <= 604800   // 7 days maximum
```
Expose a `StorageConfig.maxPresignedUrlTtlSeconds` config field (default: 3600)
to let operators tighten this further.

---

### FINDING-09 — WebSocket Auth Disabled by Default When `jwtSecret` Is Empty

**Severity:** HIGH
**Vulnerability type:** Broken Authentication (OWASP A07:2021)
**CWE:** CWE-287
**Location:** `lyric-ws/src/ws.l:202-209`

**Description:**
`WsAuthConfig` declares `enabled = true` and `jwtSecret = ""` (empty string default):

```
config WsAuthConfig {
  enabled:    Bool   = true
  @sensitive
  jwtSecret:  String = ""
  issuer:     String = ""
  audience:   String = ""
}
```

`Auth.verifyJwt` has a contract `requires: secret.length > 0`. If `jwtSecret` is
empty and `enabled = true`, calling `verifyJwt` with an empty secret will violate
the contract and panic (or produce an undefined verification result, depending on
how the BCL shim handles a zero-length HMAC key). There is no startup validation
that enforces `jwtSecret.length > 0` when `WsAuthConfig.enabled = true`.

Furthermore, there is no evidence in `ws.l` or `ws_aspects.l` that the `WsAuthConfig`
block's `jwtSecret`, `issuer`, and `audience` fields are plumbed to the actual
`Ws.Aspects.WsAuth` template. `WsAuth` requires its own `jwtSecret` config field.
If a developer enables `WsAuthConfig` but does not instantiate the `WsAuth` aspect,
authentication is silently absent.

**Exploit scenario:**
Developer sets `LYRIC_CONFIG_WS_AUTH_ENABLED=true` to signal intent, but does not
add a `WsAuth` aspect instantiation. All WebSocket connections are accepted without
any token check because the config block is not wired to the kernel authentication
path.

**Remediation:**
1. At WebSocket server startup, validate that `WsAuthConfig.enabled = false` OR
   `WsAuthConfig.jwtSecret.length > 0` holds; fail fast otherwise.
2. Either make `WsAuthConfig` drive authentication at the kernel level (the kernel
   calls `Auth.verifyJwt` before accepting the upgrade), or remove `WsAuthConfig`
   and document that authentication is handled exclusively via the `WsAuth` aspect.
3. Document clearly that declaring `WsAuthConfig` without a matching `WsAuth` aspect
   provides no security.

---

### FINDING-10 — `rolesContain` Does Not Validate Against Whitespace-Only Roles

**Severity:** HIGH
**Vulnerability type:** Broken Access Control / Business Logic Flaw (OWASP A01:2021)
**CWE:** CWE-863
**Location:** `lyric-auth/src/auth.l:126-143`

**Description:**
`Auth.rolesContain` splits `allowedRoles` on commas and compares candidates with
`==`. If `allowedRoles` is `"admin, manager"` (note the space after the comma), the
extracted candidate becomes `" manager"` (with a leading space), which never matches
a JWT `role` claim of `"manager"`. A developer who follows the common pattern of
space-separated comma lists will silently break role enforcement: the role check
always returns `false`, and the `RequiresRole` aspect always returns 403 Forbidden.
This is a correctness issue that also manifests as a security issue if the developer
works around it by broadening the `allowedRoles` config.

More critically, if a JWT claim contains a role like `","` or `"admin,"` (trailing
comma), `rolesContain("admin,", "admin,")` will find a match for the empty string
after the trailing comma and could grant access unexpectedly when `allowedRoles`
itself contains a trailing comma.

**Remediation:**
Trim whitespace from each candidate after splitting:
```
val candidate = allowedRoles.substring(start, i).trim()
```
Reject any role string in `allowedRoles` that contains only whitespace after trimming.
Add a `requires: not allowedRoles.contains(",,")` and trimming validation.

---

## Medium-Priority Findings

### FINDING-11 — `Validation.email` Accepts Many Invalid Addresses as Valid

**Severity:** MEDIUM
**Vulnerability type:** Improper Input Validation (OWASP A03:2021)
**CWE:** CWE-20
**Location:** `lyric-validation/src/validation.l:177-205`

**Description:**
The email validator accepts any string containing exactly one `@` followed by at
least one `.` after it. This accepts:
- `@.` (one char before `@`, one `.` in domain — technically valid under the
  check, practically invalid)
- `a@b.` (trailing dot)
- `a@.b` (domain starts with dot)
- `" "@example.com` (quoted local parts, accepted)
- `a@b.c.d.e.f.g` with 100-character TLDs

While the comment acknowledges this is not RFC 5322 compliant, applications that
depend on this validator for security-relevant decisions (e.g. determining whether
to send a password-reset link to a verified address) may be deceived into sending
to addresses that don't parse correctly on the receiving MTA, causing silent
delivery failures that mask account-enumeration behaviour.

More concretely, the `sendSimple` function in `lyric-mail` does not call any
validation before invoking `Mail.makeAddress(to)`. A caller who passes user input
directly can cause outbound mail to be sent to arbitrary addresses including
`attacker@evil.com\r\nBcc: victim@example.com` (header injection if `to` is placed
in a MIME header without quoting).

**Remediation:**
1. Add header-injection protection to `Mail.makeAddress`: reject any address string
   containing `\r`, `\n`, or `\0` characters before it reaches the kernel.
2. Strengthen `Validation.email` to also require: non-empty local part, non-empty
   domain part, no leading/trailing dots in local or domain parts.
3. Document the limitation clearly and recommend a DNS-based deliverability check
   for high-stakes flows.

---

### FINDING-12 — Mail Header Injection via `subject`, `displayName`, and `attachment.filename`

**Severity:** MEDIUM
**Vulnerability type:** Header Injection (OWASP A03:2021)
**CWE:** CWE-93
**Location:** `lyric-mail/src/mail.l:300-321` (`serialiseMessage`)

**Description:**
`serialiseMessage` places `msg.subject`, `addr.displayName`, `att.filename`, and
`att.contentType` into a JSON payload via `jsonString()`. The JSON escaper correctly
handles `\n`, `\r`, `\t`, `"`, and `\`. However, the Lyric layer delegates to
`Mail.Kernel.Net` which reconstructs MIME headers from the JSON payload. If the
kernel side places these values directly into MIME headers without additional
encoding (RFC 2047 folding / encoded-words), a value like:

```
subject = "Order Confirmed\r\nBcc: attacker@evil.com"
```

will be JSON-safe after `jsonString()` (the `\r\n` become `\\r\\n` in JSON), but
when the kernel reconstructs the MIME message and does `Subject: <value>`, it must
decode the JSON string back to the raw value before putting it into the header —
at which point the CRLF is present.

The `jsonString` escaping is correct for the JSON wire format but does not prevent
the kernel from writing the decoded value into a MIME header. Whether this is
exploitable depends entirely on the BCL kernel implementation (MailKit typically
encodes headers automatically), but the Lyric layer makes no defence.

**Remediation:**
1. In `Mail.makeAddress` and the convenience send functions, reject any string
   parameter containing `\r`, `\n`, or `\0` with a typed validation error before
   serialisation.
2. Apply the same check to `subject`, `filename`, and `contentType` in
   `EmailMessage`.
3. Document that the kernel shim must use RFC 2047 encoded-word encoding for all
   non-ASCII and special-character header values.

---

### FINDING-13 — AWS Secrets Cache Holds Plaintext Secrets in Process Memory With No Zeroing

**Severity:** MEDIUM
**Vulnerability type:** Sensitive Data Exposure (OWASP A02:2021)
**CWE:** CWE-312
**Location:** `lyric-aws-secrets/src/secrets.l:169-171`

**Description:**
`AwsSecrets` caches fetched secret values in process memory for up to
`SecretCache.ttlSeconds` (default 300 seconds). The cache is held in the BCL
shim (`AwsSecrets.Kernel.Net`). The Lyric layer has no mechanism to request
zeroing of the cached values when a secret is rotated, when the process shuts down,
or when a secret is no longer needed. On the JVM and .NET, the GC may not zero
memory before collection, meaning secret strings can persist in memory for an
arbitrary duration after cache expiry and be discoverable via memory dumps or
heap analysis tools.

This is an inherent limitation of managed-runtime string handling, but the design
should document the risk and provide a `clearCache()` function for callers who
need to minimise the window.

**Remediation:**
1. Add `pub func clearCache(): Unit` that instructs the kernel to zero and evict
   all cached secret values.
2. Document the memory-retention limitation in the module doc comment.
3. For `@sensitive` fields, consider storing values in `SecureString`
   (Windows) or equivalent so the runtime can pin and zero the memory; note this
   is not straightforward across platforms.

---

### FINDING-14 — InProcessSessionStore Is Not Thread-Safe; Stale Session Data Under Concurrency

**Severity:** MEDIUM
**Vulnerability type:** Race Condition (CWE-362)
**CWE:** CWE-362
**Location:** `lyric-session/src/session.l:269-272`

**Description:**
The module documentation for `InProcessSessionStore` states:

```
/// Not thread-safe; wrap in a protected type for
/// concurrent access once the protected-type weaver ships.
```

The `set`, `delete`, and `clear` methods each perform a load-modify-save
round-trip on the mutable `sessions` map without any locking. Under concurrent
requests two handlers can read the same `SessionData`, modify independent keys,
and write back stale versions, causing lost updates. In the worst case, an
authentication flag stored in the session (`userId`, `role`) can be silently lost,
causing an authenticated session to appear unauthenticated or vice versa.

The same race is documented for `NativeSessionStore` (Redis):

```
/// **NOTE:** `set`, `delete`, `clear`, and `touch` perform load-modify-save
/// round-trips without atomic Redis transactions.
```

This affects the Redis implementation even though Redis is single-threaded per key,
because the race occurs at the network round-trip level between the Lyric process
and Redis.

**Remediation:**
1. For `InProcessSessionStore`: use a thread-safe concurrent map (e.g.
   `ConcurrentDictionary` in the BCL kernel) and perform atomic compare-and-swap
   updates, or require callers to wrap in a `protected type`.
2. For `NativeSessionStore`: implement atomic update using a Redis Lua script (EVAL)
   that performs load-if-unchanged-save atomically. Expose this as the default.
3. Until fixed, document that `InProcessSessionStore` is single-threaded only and
   add a compile-time guard or runtime assertion that detects concurrent access.

---

### FINDING-15 — `Std.Process.run` Argument Quoting Incomplete on Paths With Backslashes

**Severity:** MEDIUM
**Vulnerability type:** OS Command Injection (OWASP A03:2021)
**CWE:** CWE-78
**Location:** `stdlib/std/process.l:22-37`

**Description:**
`buildArgString` quotes arguments that contain spaces or double-quotes, but it does
not handle Windows backslash sequences. The Windows command-line argument parser
(used by .NET's `Process.Start` on Windows) uses `\"` to escape a double-quote
inside a quoted argument, but a trailing backslash before `"` is interpreted as
an escape for the quote character itself. The quoting logic:

```
result = result + "\"" + arg.replace("\"", "\\\"") + "\""
```

is vulnerable when `arg` ends with a backslash: `"C:\path\"` produces a string
where the `\` before the closing `"` escapes the quote, breaking out of the quoted
argument and allowing the next token to be treated as a separate argument. An
argument `"C:\dir\"` becomes `C:\dir"` (unquoted continuation), which could permit
argument injection if any argument following it is attacker-controlled.

**Exploit scenario:**
Caller passes `args = ["C:\\evil\\", "--config=safe"]`. After quoting, the string
becomes `"C:\evil\" "--config=safe"`, which the Windows CRT argument parser splits
as `C:\evil"` and `--config=safe"` — the second argument loses its leading `--` and
may be misinterpreted.

**Remediation:**
Before closing the quote, escape any trailing backslashes to prevent them from
escaping the terminating `"`:
```
val escaped = arg.replace("\\", "\\\\").replace("\"", "\\\"")
result = result + "\"" + escaped + "\""
```
Alternatively, adopt the standard algorithm described in the Microsoft documentation
for `CommandLineToArgvW` which handles multiple trailing backslashes correctly.

---

### FINDING-16 — gRPC Reflection Enabled by Default for Production Endpoints

**Severity:** MEDIUM
**Vulnerability type:** Security Misconfiguration / Information Disclosure (OWASP A05:2021)
**CWE:** CWE-200
**Location:** `lyric-grpc/src/grpc.l:305-309`

**Description:**
`GrpcServer.reflectionEnabled` defaults to `false`:

```
config GrpcServer {
  ...
  reflectionEnabled:   Bool   = false
  ...
}
```

This is the safe default. However, the field exists with a boolean toggle and no
additional guards. When a developer sets `LYRIC_CONFIG_GRPCSERVER_REFLECTIONENABLED=true`
in production to ease integration, the gRPC reflection service exposes the complete
proto schema of all registered services. Combined with the metadata-based auth
extraction (`"authorization"` header), the schema reveals service method names,
input/output types, and field names — sufficient for an attacker to craft valid
proto-encoded payloads without access to the original `.proto` files.

**Remediation:**
1. Add a startup warning log when `reflectionEnabled = true` and a
   `LYRIC_GRPC_ALLOW_REFLECTION=1` environment variable required to suppress the
   warning in production, making the risk explicit.
2. Document that reflection must be disabled in production deployments.
3. Consider requiring a separate `reflectionSecret` credential for the reflection
   service when `reflectionEnabled = true`.

---

### FINDING-17 — `Validation.matches` Does Not Actually Match; Always Returns Valid for Non-Empty Values

**Severity:** MEDIUM
**Vulnerability type:** Improper Input Validation / Business Logic Flaw (OWASP A03:2021)
**CWE:** CWE-20
**Location:** `lyric-validation/src/validation.l:138-150`

**Description:**
`Validation.matches` is documented as a pattern validator but its body does nothing
more than check whether a value is non-empty when a pattern is provided:

```
pub func matches(...): [ValidationError] {
  if pattern.length > 0 and value.length == 0 {
    return err(field, "pattern", field + " must match " + patternDesc)
  }
  return []
}
```

The function body is marked `@experimental` and the comment acknowledges "full
regular-expression matching is deferred". The problem is that callers seeing the
function signature `matches(value, field, pattern, patternDesc)` will reasonably
expect that their pattern is being enforced. If a caller uses:

```
Validation.matches(userInput, "phone", "^\\+?[0-9]{7,15}$", "E.164 phone number")
```

they receive no validation errors regardless of the content of `userInput` (as long
as it is non-empty). This is a silent security regression: callers believe their
inputs are validated, but they are not.

**Remediation:**
1. Remove or rename `matches` to `notEmpty` or deprecate it until the regex engine
   ships.
2. If the function must exist as a placeholder, make it panic or return an error
   indicating that pattern matching is not implemented, so callers are alerted at
   development time.
3. Implement regex matching backed by `Std.Regex` (already present in the stdlib
   at `stdlib/std/_kernel/regex.l`) and remove the `@experimental` marker.

---

### FINDING-18 — `I18n.substitutePlaceholders` Allows Recursive Expansion if Vars Contain `{}`

**Severity:** MEDIUM
**Vulnerability type:** Template Injection / Unexpected Behaviour (OWASP A03:2021)
**CWE:** CWE-94
**Location:** `lyric-i18n/src/i18n.l:336-365`

**Description:**
`substitutePlaceholders` scans the template for `{varName}` tokens and replaces them
with values from the `vars` map. Replacement values are inserted verbatim without a
second-pass guard:

```
case Some(value) -> out = out + value
```

If a `vars` value itself contains `{anotherVar}`, the current implementation does
not re-process it (it is a single-pass scanner). However, this is a subtle contract
that is not enforced or documented. A future optimisation that changes to multi-pass
or recursive substitution would introduce template injection.

More immediately, if `vars` values contain `}` without a matching `{`, the output
string can differ structurally from the template in ways that confuse downstream
HTML renderers or parsers consuming the translated string.

Additionally, there is no maximum substitution length or result length guard. A
translation template `{x}` with `vars = { "x": "<10 MB string>" }` produces a very
large output string with no bounds check.

**Remediation:**
1. Document explicitly that substitution values are inserted verbatim and are not
   re-scanned for further placeholders.
2. Add a `maxOutputLength` guard: if the accumulated output exceeds a configurable
   limit (e.g. 1 MB), return a truncation error or the key itself.
3. For HTML contexts, HTML-escape substitution values unless the call site explicitly
   opts into raw insertion.

---

## Low-Priority Findings

### FINDING-19 — `Std.Random` Exposes `System.Random` Which Is Not Cryptographically Secure

**Severity:** LOW
**Vulnerability type:** Use of Insufficiently Random Values (OWASP A02:2021)
**CWE:** CWE-338
**Location:** `stdlib/std/_kernel/random.l`

**Description:**
`Std.Random` is built on `System.Random`, which is a pseudo-random number generator
not suitable for security-sensitive operations. The module does not document this
limitation. A developer who imports `Std.Random` to generate tokens, nonces, or
sampling keys for rate-limiting may inadvertently use a predictable PRNG.

The `Std.Uuid` module correctly uses `System.Guid.NewGuid()` which is backed by
a CSPRNG on all .NET platforms (`RNGCryptoServiceProvider` or `CNG`). Session IDs
generated via `Std.Uuid.newUuid()` in `InProcessSessionStore.create()` are
therefore secure. The risk is that developers reaching for `Std.Random` for
security-adjacent use (e.g. a nonce, a CSRF token) will get an insecure source.

**Remediation:**
Add a module-level warning to `Std.Random`:
```
/// WARNING: Std.Random is NOT cryptographically secure.
/// Use Std.Crypto.Random (when available) for security-sensitive values.
```
Provide a separate `Std.Crypto` or `Std.SecureRandom` module backed by
`System.Security.Cryptography.RandomNumberGenerator` for generating tokens,
nonces, and similar values.

---

### FINDING-20 — `Db.Connection.url` Contains Database Credentials Without `@sensitive`

**Severity:** LOW
**Vulnerability type:** Sensitive Data Exposure (OWASP A02:2021)
**CWE:** CWE-312
**Location:** `lyric-db/src/db.l:232-240`

**Description:**
`Db.Connection.url` is a plain string that typically embeds database credentials
(`postgres://user:password@host/dbname`). Unlike `Connection.password`, which is
marked `@sensitive`, the `url` field has no such annotation:

```
config Connection {
  url:               String
  poolSize:          Int range 1 ..= 100   = 10
  ...
  @sensitive
  password:          String = ""
}
```

This means the full connection URL (including embedded credentials) may appear in
log output, diagnostic dumps, and error messages. The `password` override field is
`@sensitive` but is described as an "optional override" — the primary path (embedding
the password in `url`) is unprotected.

**Remediation:**
Mark `url` as `@sensitive`:
```
@sensitive
url: String
```
Or, as with the Redis session config, split the URL into host/port and a separate
`@sensitive` password field, and construct the DSN internally.

---

### FINDING-21 — `Grpc.metadataString` Serialises Metadata Key-Value Pairs Without Escaping

**Severity:** LOW
**Vulnerability type:** Injection / Data Integrity (OWASP A03:2021)
**CWE:** CWE-116
**Location:** `lyric-grpc/src/grpc.l:54-60`

**Description:**
`metadataString` serialises the `GrpcCallOptions.metadata` list into a
comma-colon delimited string:

```
func metadataString(opts: in GrpcCallOptions): String {
  var result: String = ""
  for entry in opts.metadata {
    if result.length > 0 { result = result + "," }
    result = result + entry.key + ":" + entry.value
  }
  return result
}
```

If a metadata key or value contains a literal `,` or `:` character, the kernel-side
parser will misinterpret the boundary and either corrupt the metadata map or assign
values to wrong keys. An attacker who controls metadata values (e.g. a service that
reflects request headers into outbound gRPC metadata) can inject additional
key-value pairs.

**Remediation:**
Use a proper serialisation format for the metadata wire (e.g. percent-encoding or
JSON) rather than a home-rolled comma-colon format, and ensure the kernel parser
uses the same format. At minimum, validate that keys and values do not contain
`,` or `:` before serialising.

---

## Positive Security Practices

The following design choices reflect good security engineering and should be
preserved:

1. **Secure cookie defaults** — `Session.SessionConfig` defaults `httpOnly = true`,
   `secure = true`, `sameSite = "Lax"`. These protect session cookies against XSS
   theft and CSRF by default without requiring operator action.

2. **Constant-time API key comparison** — `Auth.verifyApiKey` is correctly specified
   to use BCL `CryptographicOperations.FixedTimeEquals` (via `System.Security.Cryptography`),
   preventing timing oracle attacks on API keys.

3. **Parameterised queries only** — `Db.DbConnection.query` and `execute` accept
   `params: [String]` separately from `sql: String`; there is no string-concatenation
   query construction surface in the public API. SQL injection is structurally
   prevented at the interface level.

4. **`@sensitive` annotations on credential fields** — JWT secrets, SMTP passwords,
   AWS credentials, and API keys are consistently marked `@sensitive` across the
   config blocks, enabling the framework to mask them in output.

5. **Fail-closed auth aspects** — `RequiresAuth`, `RequiresRole`, `WsAuth`, and
   `RequiresGrpcAuth` return denial errors by default (not allow-by-default); the
   `enabled = false` bypass requires explicit configuration.

6. **Opaque session IDs** — `InProcessSessionStore.create()` uses `Std.Uuid.newUuid()`
   (backed by `System.Guid.NewGuid()`, a CSPRNG), producing cryptographically
   unpredictable session IDs.

7. **`ValidateKey` aspect for storage** — The opt-in `Storage.Aspects.ValidateKey`
   aspect provides path traversal protection at the library level; the gap
   (FINDING-04) is in the implementation, not the design intent.

8. **Typed error unions** — `SecretsError`, `DbError`, `StorageError`, and
   `MailError` are typed unions rather than raw strings, making it structurally
   harder to accidentally log sensitive detail from error messages passed through
   the call stack.

---

## Recommendations

### Strategic

1. **JWT algorithm pinning (immediate)** — Add `allowedAlgorithms: [String]` to
   `Auth.verifyJwt` before any production deployment. The current API surface
   cannot express algorithm restrictions and is therefore vulnerable to all known
   JWT confusion attacks (FINDING-01).

2. **Session regeneration protocol** — Define and document a `regenerateId` operation
   in the `SessionStore` interface that atomically copies session data to a new ID
   and destroys the old one. All authentication and privilege-elevation flows must
   call this. Address the session fixation design flaw (FINDING-02) before any
   auth-sensitive use of `lyric-session`.

3. **Centralised log sanitisation** — Introduce a `Std.Log.sanitize(s: String): String`
   helper that strips ANSI codes, CRLFs, null bytes, and limits length, and
   document it as the required pre-processing step for any user-controlled string
   entering a log statement. Apply it in `AwsXRay.Tracing` and `Lambda.Aspects.EventLogging`
   (FINDING-06).

4. **TLS enforcement for outbound HTTP** — Any Lyric library that polls a remote
   endpoint (lyric-feature-flags, lyric-otel OTLP exporter) must validate that the
   configured URL uses `https://` when authentication credentials are present.
   Add a shared `Std.Http.requiresTls(url: String, hasCredentials: Bool): Result[Unit, String]`
   helper and call it at connection time (FINDING-05).

### Tactical

5. **Audit `@sensitive` coverage** — Run a grep for all `config` blocks in the
   repository and verify that every field whose value is a secret, credential, or
   connection string carrying a secret is marked `@sensitive`. The `url` fields
   in `RedisSession` and `Db.Connection` are the most urgent gaps (FINDING-07,
   FINDING-20).

6. **Path traversal in storage** — Move the key-normalisation logic into the kernel
   (`Lyric.Storage.Local`) so it operates on the filesystem path, not the raw key
   string. The kernel should perform an absolute-path containment check using
   `System.IO.Path.GetFullPath` and verify the result starts with the configured
   `basePath` (FINDING-04).

7. **Replace `Validation.matches` stub** — Either implement regex matching backed
   by the existing `Std.Regex` kernel, or remove the function. Shipping a no-op
   validator under a name that implies enforcement is a latent security regression
   (FINDING-17).
