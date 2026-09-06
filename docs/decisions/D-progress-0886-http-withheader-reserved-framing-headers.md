# D-progress-886 — `Std.Http.withHeader` rejects reserved framing headers instead of producing a duplicate header line on the wire (#6658)

**Status:** Shipped, all three kernels (dotnet, JVM, native).

**The bug.** `hostWithHeader` (`_kernel/http_host.l`, `_kernel_jvm/http_host.l`,
`_kernel_native/http_host.l`) let a caller add an arbitrary header
name/value pair to a request with no check against the framing headers
each kernel generates automatically once the request is sent: `Host` and
`Connection` (every kernel), plus `Content-Type`/`Content-Length` once a
body is attached via `withJsonBody`/`withTextBody`. A caller doing e.g.
`withHeader(req, "Content-Length", "0")` produced a duplicate header line
on the wire once the kernel appended its own — request-smuggling-adjacent,
since which of two duplicate headers a peer honors is implementation-defined
(RFC 9112 §5.1). Raised as a non-blocking SUGGESTION on #6623's review,
scoped as its own cross-kernel follow-up since it predates and is
independent of that PR's native-only CRLF-injection fix (#6635).

**The fix.** Each kernel's `hostWithHeader` now checks the caller-supplied
name against the four reserved names, case-insensitively (RFC 9110 §5.1 —
header field names are case-insensitive), and returns
`Result[HttpRequestMessage, String]` instead of the bare handle: `Err(key)`
for a reserved name, `Ok(request)` otherwise. The dotnet and JVM kernels
compare via the intrinsic `.toLower()`; the native kernel reuses its
existing hand-rolled `asciiEqualsCaseInsensitive` (module header item 4:
`.toLower()`/`.toUpper()` are unsupported on that target). `Std.Http`'s
public `withHeader(request, key, value): Result[HttpRequest, HttpError]`
(previously an infallible `HttpRequest`) maps the kernel's `Err` to a new
`HttpError.ReservedHeader(url, name)` case — a genuine, documented breaking
signature change to a `@stable(since = "1.0")` function, bumped to
`@stable(since = "1.2")` (the current stdlib stability version) alongside
the `HttpError` union itself.

**Design decision.** Reject with a typed `Result` rather than silently
drop the header (the issue's other suggested direction) — silent dropping
would leave a caller's bug invisible, exactly the failure mode this
project's production-readiness standard treats as unacceptable. The guard
lives in `hostWithHeader` itself (not only in `Std.Http.withHeader`)
because that is the exact point closest to where the duplicate would be
produced on each target, and because `hostWithHeader` is `Std.HttpHost`'s
only call site reachable from `Std.Http`, so there is no coverage gap from
putting the check there.

**Call-site fallout.** `Std.Rest.applyAuth`/`sendRequest`
(`lyric-stdlib/std/rest.l`) threaded the new `Result` through and, along
the way, deleted a pre-existing dead call:
`sendRequest`'s `contentType` parameter was passed to `withHeader(req,
"Content-Type", contentType)` immediately before `withJsonBody(req, json)`
unconditionally overwrote the request's content type to
`"application/json"` regardless — every call site already passed
`"application/json"` as `contentType`, so the parameter had no observable
effect even before this fix, and would have started rejecting with
`ReservedHeader` on every JSON-bodied request after it. Removed the
parameter (and its `withHeader` call) from `sendRequest` and all five call
sites (`get`/`post`/`put`/`patch`/`delete`) rather than leave a
now-actively-broken no-op in place. `lyric-search/src/search.l`'s
`buildRequest` (a caller-configured `authHeaderName`) now propagates a
`ReservedHeader` as a typed `SearchError` instead of assuming success;
`lyric-lambda/src/dispatch.l`'s fixed literal header name cannot hit the
reserved set, so its call site just unwraps.

**Verification.** New tests: `lyric-stdlib/tests/http_tests.l` (dotnet)
asserts all eight case variants of the four reserved names are rejected
with the exact caller-supplied name and URL, a normal header still
succeeds, and `HttpError.message` renders `ReservedHeader`.
`lyric-stdlib/tests/http_version_tests.l` (wired on both `--target dotnet`
and `--target jvm` already, per `.github/workflows/ci.yml`'s ~500,000-byte
ceiling, #6781 — no new CI step added) carries a dual-target copy of the
same reserved/non-reserved assertions. Native: verified with a standalone
`--target native` program exercising both the reject and accept paths
(exit code confirms both); the pre-existing `llvm_http_client_self_test.l`
(not wired into CI or `make test-native` before or after this change) was
updated to match the new `Result`-returning signature and re-verified to
compile and format cleanly, though its own listener-based cases could not
be executed in this sandbox (missing `libclang_rt.asan`, pre-existing gap).
`lyric-compiler/lyric/stdlib_jvm_kernels_self_test.l` (32/32, JVM,
including "request headers cross the boundary: withHeader ->
requestHeaders map") and `lyric-compiler/lyric/http_roundtrip_self_test.l`
(dotnet, fmt-verified; a live-listener case not run in this sandbox) were
updated for the new signature. `lyric-stdlib/tests/rest_tests.l` (dotnet,
`lyric run`) re-verified passing after the `Std.Rest` rewrite.

**Related:** #6658 (this issue), #6623 (where it was raised), #6635 (the
adjacent native-only CRLF-injection fix), `docs/10-stdlib-plan.md` (updated
`withHeader` signature + `HttpError` union).
