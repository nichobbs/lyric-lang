# D-progress-886 — lyric-aws-secrets: real JVM Secrets Manager/SSM bindings ship; the .NET `aws` async-FFI "blocker" is corrected (a real precedent exists) but stays NOT_IMPLEMENTED pending an API-shape decision (#5411)

**Status:** shipped

**Context.** #5411 (and three prior triage passes on it) treated
`lyric-aws-secrets`'s `aws`/`jvm` `extern package` kernels as blocked on two
hard prerequisites: (1) no `extern type` + auto-FFI precedent anywhere in the
repo for binding a `Task<T>`-returning BCL/SDK async call, and (2) no
compiler capability to read custom config-block annotations
(`@secretsManager`/`@parameterStore`) at runtime. Both were re-investigated
from scratch rather than re-asserted.

**Finding 1 — the async-FFI claim was wrong.** `Std.HttpHost`
(`lyric-stdlib/std/_kernel/http_host.l`) already binds
`HttpClient.SendAsync`/`GetAsync`/`PostAsync` — real `Task<T>`-returning BCL
methods — via `@externInstance @externTarget("...") async func ...(...): T
= ()`, with callers `await`-ing the result. This is not blocked by #6581
(generic-declaring-type ctors / generic-method MethodSpec emission; the AWS
SDK calls in question are neither). The REAL blocker is that adopting this
for `lyric-aws-secrets` would force its entire public API (`init()`,
`getSecret()`, etc.) to become `async func`, cascading to every caller —
`func main(): Int` and every `lyric-lambda` handler (`direct.l`'s
`DirectHandler` family) are synchronous today. That is a deliberate
API-shape decision, not a compiler gap, so `secrets_kernel_aws.l` stays
NOT_IMPLEMENTED (converted from a bare `extern package` no-op trap to a real
pure-Lyric file that fails loudly and honestly) with the corrected reasoning
recorded in its header. Filed as issue #6864.

**Finding 2 — the JVM v2 SDK's default clients are synchronous.** Unlike
.NET, `SecretsManagerClient`/`SsmClient`'s `getSecretValue`/`getParameter`
are plain blocking interface methods (`SecretsManagerAsyncClient` is a
separate, unused type) — so the JVM feature has NO async-FFI prerequisite
at all. Real bindings ship in `secrets_kernel_jvm.l`: client construction via
the same static-factory + fluent-builder auto-FFI idiom `lyric-web`'s JVM
kernel already proved (`JUndertow.builder()...build()`), request/response
POJOs (`GetSecretValueRequest`/`Response`, `GetParameterRequest`/`Response`/
`Parameter`) via the same pattern, `Std.Json` (pure Lyric, cross-platform
since D-progress-555) for the `getSecretField` JSON-key-extraction path, and
a process-global `ConcurrentHashMap`-backed TTL cache mirroring
`lyric-web`/`lyric-resilience`'s existing JVM-kernel caching idiom. Class
shapes were verified against the real
`software.amazon.awssdk:secretsmanager`/`ssm` 2.25.70 JARs via `javap`
before writing the bindings, not guessed.

**Error classification is honestly best-effort.** Lyric's `catch Bug as b`
boundary exposes only a flattened `b.message` string — there is no
typed-exception-hierarchy pattern match across the FFI boundary — so
`classifySecretsError`/`classifyParameterError` (both `pub`, so the test
suite can exercise them directly) do substring matching on the AWS SDK's own
exception messages, falling back to `NetworkError` for anything
unrecognised. This is documented as a known limitation in the kernel's
header and the README, not silently papered over.

**A genuine self-hosted-compiler monomorphisation gap was found and worked
around, not silently avoided.** A module-level
`newConcurrentDict[String, JSecretsManagerClient]()` call (the generic
`ConcurrentDict[K, V]` idiom already used elsewhere, instantiated over an
`extern type` rather than a plain Lyric record) fails with "an explicit type
argument does not resolve to a known type in this compilation unit" — the
same call shape instantiated over a plain record (`CacheEntry`, used for the
TTL cache two lines above) monomorphises fine, so this is specific to
extern-typed generic arguments. Worked around with two dedicated
non-generic `ConcurrentHashMap` bindings (one per client type) rather than
forcing the generic path; documented in the kernel file as a two-line
workaround worth revisiting, not a design requirement.

**A client-construction failure previously panicked uncaught, now returns a
typed `Err`.** `JSecretsManagerClient.builder().build()`/
`JSsmClient.builder().build()` resolve the region/credentials chain eagerly
and throw `SdkClientException` if neither can be determined (e.g. running
the `jvm` feature outside Lambda with no `AWS_REGION` and no instance
profile). That call originally ran before the `try`/`catch Bug` boundary,
which only wrapped `getSecretValue`/`getParameter` — fixed by widening the
`try` block in `fetchSecret`/`fetchParameter` to cover client construction
too, so it is classified and returned as `Err` like every other SDK failure
path in this file (issue #6979).

**A `Std.Json.getString` panic on a non-string JSON field was converted to a
typed `ParseError`.** `extractSecretField` extracted the JSON-parsing logic
into its own directly-testable function and wraps the `getString` call in a
`try`/`catch Bug` so an ordinary non-string secret field (e.g. a numeric
`dbPort` alongside a string `dbPassword`) returns `Err(ParseError(...))`
instead of crashing the whole call (issue #6875).

**initFromAnnotations() stays NOT_IMPLEMENTED on every feature except
`local`.** Re-confirmed via a repo-wide grep against current `main`: no
capability to read custom user annotations off a compiled config-block
field at runtime exists anywhere in the compiler or JVM/MSIL runtime hosts.
Filed as issue #6866, with a menu of three candidate approaches (MSIL
`CustomAttribute` + reflection, JVM `RuntimeVisibleAnnotations` + reflection
mirroring the existing `@LyricTest` precedent from docs/32, or a
compile-time-only synthesis of `initFromAnnotations()`'s body that avoids
new runtime reflection surface entirely). `docs/35-lambda-library.md` §7.2
is updated with a caveat that this path only works on `local` today.

**Verification.** `lyric test --manifest lyric-aws-secrets/lyric.toml`
(bare, default `local` feature — the existing CI baseline per #5135) plus
explicit `--features local`, `--no-default-features --features aws`, and
`--target jvm --no-default-features --features jvm` all pass 17/17. The jvm
run is a genuine `--target jvm` compile through the self-hosted `Jvm.Bridge`
against the real Maven-resolved SDK JARs (not a stub) followed by a real
`java` execution of the resulting JAR — this fails loudly if any binding is
wrong, which is exactly how the try/catch value-position type-inference
issue, the monomorphisation gap above, and the client-construction panic
were caught. What is NOT verified: a live or mocked AWS Secrets Manager/SSM
network round-trip (no AWS account in this environment; both SDKs support
an endpoint override for exactly this kind of local-mock testing, but
standing one up was scoped out of this PR — see the kernel file headers and
the PR description for the honest unverified-vs-verified split).

**Related:** #5411 (parent issue, closed by this — three prior triage passes
on it correctly identified the two blockers as real concerns worth
re-investigating, but had not yet found the `Std.HttpHost` precedent or
tried the JVM sync-client path), #6864 (new, the .NET async-API-shape
decision), #6866 (new, the config-block annotation-reflection compiler
gap), #6875 (getSecretField panic, fixed), #6979 (client-construction panic,
fixed), #6891 (new, the `ConcurrentDict`/extern-type monomorphisation gap),
#6581 (a different, unrelated generic-BCL-binding gap — confirmed not
the blocker here), #733/#783 (the original, incompletely-fixed secrets
kernel restoration this traces back to).
