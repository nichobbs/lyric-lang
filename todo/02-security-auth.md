# Tier 2 — Security: lyric-auth JWT Library

## Issues
- **#1093** — `writeRuntimeConfigWithProbing` builds JSON via unescaped string concatenation (injection vector)
- **#1090** — `verifyJwt` returns `false` for RS256 and other unsupported algorithms with no diagnostic
- **#1089** — JWT `aud` claim in JSON array form silently rejected (RFC 7519 §4.1.3 non-compliance)
- **#1079** — `getStringClaimFromJson` does not handle JSON escape sequences in claim values
- **#1081** — No clock-skew leeway in JWT `exp`/`nbf` validation
- **#1088** — `parseLong` returns `-1i64` for two distinct failure cases (parse error and overflow)
- **#1091** — JWT overflow regression tests use pre-computed HMAC signatures with no construction comments
- **#1094** — `verifyJwtImpl`/`extractClaimImpl` rename is a named workaround for alias-rewriter bug (root issue untracked)

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else.

Your task is to fix all eight security and correctness issues in the `lyric-auth` JWT library listed above. These are all in Lyric source (`.l` files) — no F# changes are needed or permitted. Work on a new branch named `fix/tier2-auth-security`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

The `lyric-auth` library is safety-critical. Every fix must be accompanied by tests in `lyric-auth/tests/auth_security_tests.l` (runnable via `lyric test --manifest lyric-auth/lyric.toml`) that would have caught the bug. Do not add pre-computed test values without construction comments explaining exactly how they were derived.

---

### #1093 — JSON injection in `writeRuntimeConfigWithProbing`

Locate `writeRuntimeConfigWithProbing` (likely in `lyric-compiler/lyric/cli.l` or a build helper). It builds JSON via string concatenation. If any interpolated value contains `"` or `\`, the output is invalid JSON and potentially injectable.

**Fix:** Use `Std.Json` to construct the JSON object properly, or escape all string values through a dedicated escape helper before interpolation. Do not use raw string concatenation for JSON construction anywhere in the compiler or CLI.

---

### #1090 — `verifyJwt` returns `false` for unsupported algorithms

`verifyJwt` must return a typed `Err(...)` result when the algorithm (`alg` header claim) is not in the caller-supplied `allowedAlgorithms` list, not a bare `false`. Returning `false` conflates "signature verification failed" with "algorithm rejected" — callers cannot distinguish them.

**Fix:** Change the return type path for algorithm rejection to `Err(JwtError(message = "algorithm not permitted: <alg>", code = "ALG_REJECTED"))` or equivalent. Callers already handle `Result`; this is an existing code path that needs to return `Err` instead of `Ok(false)`.

Add a test: a token signed with RS256 when only `["HS256"]` is allowed must return `Err` (not `Ok(false)`).

---

### #1089 — JWT `aud` claim array form silently rejected

RFC 7519 §4.1.3 defines `aud` as either a single string or a JSON array of strings. `verifyJwt` currently only handles the single-string form; a token with `"aud": ["api.example.com", "admin"]` is silently rejected (treated as invalid rather than verified against the expected audience).

**Fix:** In `getStringClaimFromJson` (or the `aud`-specific extraction path), detect when the claim value starts with `[` and parse it as a JSON array. Verify the expected audience appears in the array. Add tests for:
- Single-string `aud` match
- Array `aud` containing the expected audience (should pass)
- Array `aud` not containing the expected audience (should fail)
- Malformed `aud` value (should return `Err`)

---

### #1079 — `getStringClaimFromJson` corrupts escaped claim values

`getStringClaimFromJson` uses string search to extract claim values from the JWT payload JSON. It does not handle JSON escape sequences, so a claim value containing `\"`, `\n`, `\\`, or `\uXXXX` is extracted with the raw backslash-escaped bytes rather than the decoded string.

**Fix:** After locating the claim value substring, run it through a proper JSON string decoder (using `Std.Json` or a dedicated unescape helper) before returning it. The decoder must handle at minimum: `\\`, `\"`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f`, `\uXXXX`.

Add tests: a JWT with a `sub` claim of `"O'Brien"` (no escaping needed), then `"O\"Brien"` (quote escaped), then `"line1\nline2"` (newline escaped) — all must extract correctly.

---

### #1081 — No clock-skew leeway in JWT `exp`/`nbf` validation

`verifyJwt` rejects tokens where `exp <= now` or `nbf > now` with strict equality. A token that expires at exactly `now` (same second) or a `nbf` one second in the future due to issuer/verifier clock drift is incorrectly rejected.

**Fix:** Add a configurable `clockSkewSeconds: Int` parameter (default `60`) to the verification function. Apply it as:
- Token valid if `exp >= now - clockSkewSeconds`
- Token valid if `nbf <= now + clockSkewSeconds`

The default of 60 seconds is industry standard (used by Auth0, AWS Cognito, etc.). Document this in the function's doc-comment.

Add tests for tokens that are expired by less than 60 seconds (should pass with default leeway) and more than 60 seconds (should fail).

---

### #1088 — `parseLong` dual-sentinel `-1i64`

`parseLong` returns `-1i64` for both a parse error (non-numeric input) and an overflow (value outside `Int64` range). Callers cannot distinguish the two failure modes, which matters when `-1` is a valid expected value.

**Fix:** Change `parseLong` to return `Result[Int, String]` — `Ok(value)` on success, `Err("parse_error")` or `Err("overflow")` on failure. Update all callers within `lyric-auth` to pattern-match on the result.

If `parseLong` is defined in `lyric-stdlib`, make the stdlib change there and propagate. If it is local to `lyric-auth`, fix it in place.

---

### #1091 — Pre-computed HMAC test values without construction comments

The JWT overflow regression tests (added for #1078) use hardcoded HMAC-SHA256 signatures. Anyone reading the tests cannot verify the values are correct or regenerate them after a change.

**Fix:** Add a comment block above each pre-computed value explaining exactly how it was derived:
```
// HMAC-SHA256 of "<header_b64>.<payload_b64>" with key "<key_hex>"
// Generated by: echo -n "<header>.<payload>" | openssl dgst -sha256 -hmac "<key>"
```

Alternatively, compute the expected HMAC inline in the test using `Std.Crypto.hmacSha256` (if available) so the test is self-verifying. Do not leave pre-computed magic bytes with no derivation trail.

---

### #1094 — `verifyJwtImpl`/`extractClaimImpl` rename workaround for alias-rewriter bug

These functions were renamed (adding `Impl` suffix) as a workaround for an untracked compiler alias-rewriter bug. The public API then re-exports them under the original names.

**Fix:**
1. File a GitHub issue for the root alias-rewriter bug, with a minimal reproduction case.
2. Once the alias-rewriter bug is fixed in the self-hosted compiler, remove the `Impl` suffix and the re-export layer.
3. If the alias-rewriter bug is out of scope for this tier, the issue filing is still required so it does not go untracked.

---

## Acceptance Criteria

- [ ] `verifyJwt` returns `Err` (not `Ok(false)`) when the algorithm is not in `allowedAlgorithms`
- [ ] `verifyJwt` accepts RFC 7519 array-form `aud` claim and verifies audience membership correctly
- [ ] `getStringClaimFromJson` correctly decodes all standard JSON escape sequences (`\\`, `\"`, `\n`, `\r`, `\t`, `\b`, `\f`, `\uXXXX`)
- [ ] `verifyJwt` applies 60-second default clock-skew leeway to `exp` and `nbf`; leeway is configurable
- [ ] `parseLong` returns `Result[Int, String]` with distinct `Err` variants for parse failure vs overflow
- [ ] `writeRuntimeConfigWithProbing` uses proper JSON construction (no raw string concatenation of user values)
- [ ] All pre-computed HMAC test values have derivation comments or are computed inline
- [ ] GitHub issue filed for alias-rewriter bug with minimal reproduction; linked from the workaround code
- [ ] `verifyJwtImpl`/`extractClaimImpl` rename removed once alias-rewriter bug is fixed (or deferred with issue link if out of scope)
- [ ] `lyric test --manifest lyric-auth/lyric.toml` passes with all new tests
- [ ] Each fix has at least one test that would have caught the bug before the fix
- [ ] No new F# code
- [ ] No pre-computed test values without derivation comments
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
