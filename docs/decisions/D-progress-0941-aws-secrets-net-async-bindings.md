# D-progress-941 — lyric-aws-secrets: real AWS SDK for .NET v3 bindings ship; `AwsSecrets`'s public API stays synchronous (#6864)

**Status:** shipped

**Context.** Issue #6864 (filed by the #5411 PR that shipped the real JVM
`AwsSecrets.Kernel.Net` bindings) asked whether binding the AWS SDK for
.NET v3's `AmazonSecretsManagerClient.GetSecretValueAsync`/
`AmazonSimpleSystemsManagementClient.GetParameterAsync` — both real,
non-generic, `Task<TResponse>`-returning instance methods, verified via
.NET reflection against the restored `AWSSDK.SecretsManager`/
`AWSSDK.SimpleSystemsManagement` 3.7.400 assemblies — would force
`AwsSecrets`'s public API (`init()`/`getSecret()`/`getSecretField()`/
`getParameter()`/`getParameterRaw()`, all plain synchronous `pub func`s)
to become `async func`, cascading into `lyric-lambda`'s synchronous
`DirectHandler` family and `func main(): Int` itself.

**Decision.** No API-shape change was needed. The self-hosted MSIL
emitter already supports `await` inside a **plain (non-`async`)
function**: `Lyric.AwaitHoist`'s own module doc states "plain functions
and lambdas resolve `await` with a blocking `GetAwaiter().GetResult()`
shim that has no suspension," and `EAwait`'s codegen
(`lyric-compiler/msil/codegen.l`, `emitBlockingAwait`) dispatches to this
blocking path whenever the enclosing function is not itself an async
state machine (`fctx.phaseBCtx.count == 0`). This is the exact mechanism
`async_sm_self_test.l`/`async_spawn_self_test.l` already exercise on the
MSIL path. Verified directly against a real `Task<T>`-returning BCL call
(`System.IO.File.ReadAllTextAsync`, bound the same T-declared-return
`@externTarget async func` shape `Std.HttpHost` uses for
`HttpClient.SendAsync`) before writing the AWS SDK binding itself: a
plain `func` awaiting the extern compiled and ran correctly, unwrapping
the real `Task<string>` with no suspension machinery involved.

`secrets_kernel_aws.l`'s `fetchSecret`/`fetchParameter` therefore stay
plain `func`s, mirroring the shape `secrets_kernel_jvm.l` already has
(where the JVM SDK's client methods are natively synchronous, so no
async question ever arose there). `AwsSecrets`'s public surface is
byte-for-byte unchanged from before this PR.

**Implementation.** Client/request/response binding mirrors
`Std.HttpHost`'s explicit `extern type` + `@externTarget` idiom (ctor +
`set_<Prop>` for writes, bare `<Prop>` for reads — auto-FFI resolves a
bare property name to its getter even when a setter also exists, per
`HttpResponseMessage.StatusCode`'s established precedent).
`GetSecretValueAsync`/`GetParameterAsync` take an explicit
`Std.Task.noCancellation()` argument rather than relying on an omitted
optional parameter: reflection confirmed these are single CLR methods
with a C# *optional* trailing `CancellationToken` parameter, not a
genuine method-overload pair the way `HttpClient.SendAsync` is — the CLR
itself has no concept of an omittable argument, so a call site must
always supply one explicitly regardless of what the auto-FFI resolver
does with arity.

Error classification mirrors the jvm kernel's `classifySecretsError`/
`classifyParameterError` exactly: best-effort substring matching against
the AWS SDK's service-side error messages (shared verbatim across every
AWS SDK language binding, since the text originates from the service's
JSON error response), because Lyric's `catch Bug as b` boundary only
exposes the flattened `Exception.Message` (confirmed directly against the
MSIL emitter's `.message` accessor, which casts to `System.Exception` and
calls `get_Message()` — not `ToString()`, and not the also-available but
never-otherwise-used `.typeName` accessor, kept unused here for
consistency with the established, widely-exercised `.message` idiom).

**A genuine, separate compiler-gap-adjacent bug found and fixed along the
way.** The jvm kernel's own module-level client-cache workaround (#6891:
sidestep a `newConcurrentDict[K, V]()` monomorphisation gap over an
extern-typed `V` by declaring two dedicated, non-generic
`ConcurrentHashMap`-backed cache types) does not port to .NET as-is.
JVM generics are erased, so a raw (type-argument-free)
`ConcurrentHashMap` works directly; reproduced the identical #6891
monomorphisation failure on MSIL too (`newConcurrentDict[String,
AmazonSecretsManagerClient]()` — the exact same "an explicit type
argument does not resolve to a known type in this compilation unit"
diagnostic), confirming the gap is in the shared `Lyric.Mono`
middle-end pass, not backend-specific. But .NET generics are *reified*:
an `extern type SmClientCache = "...ConcurrentDictionary\`2"` with no
type arguments anywhere cannot be constructed — `ConcurrentDictionary\`2`
is an open generic type, and the CLR has no notion of a `newobj` against
an unclosed TypeSpec. This was reproduced directly (a `.cctor` runtime
crash, "The type initializer ... threw an exception," with no useful
inner detail surfaced through `lyric test`) before being root-caused via
an isolated probe. The fix: name the bracketed generic instantiation
directly in the `extern type` target string, using the CLR's
bracket-nested generic-instantiation syntax (`Type\`N[[Arg1],[Arg2]]`) —
`"System.Collections.Concurrent.ConcurrentDictionary\`2[[System.String],[Amazon.SecretsManager.AmazonSecretsManagerClient]]"`.
Traced through `typeExprToMsilCtx` in `lyric-compiler/msil/codegen.l`
(~line 7069): the real mechanism is not "closed generic construction" —
any `extern type` FQN containing `[` is erased to `object` wholesale
(the same object-erasure escape hatch `lyric-grpc`'s
`NetGrpcChannelDict` idiom already relies on), so no Lyric-side type
parameter, and therefore no monomorphisation, is ever invoked. Member
calls on the erased value still route through `emitGenericExternMember`,
which builds the real closed GENERICINST TypeSpec and `castclass`es the
receiver — so construction and access both work, but via object
erasure with consistent load/store on both sides, not via a genuine
closed-generic local variable type. Verified working via an isolated
probe before applying it to the real kernel file.

**Verification.** This session had genuine from-source build capability
(`make lyric`, unlike the #5411 PR's NuGet-tool-only sandbox), so the
async-in-plain-function design was validated directly against a real BCL
`Task<T>` call before implementation, the AWS SDK's actual API shape was
confirmed via .NET reflection against the restored NuGet assemblies
(construction/property signatures, not assumed from memory), and the
`ConcurrentDictionary` fix was isolated and confirmed via a minimal
repro before being applied to the shipped file. Full local verification
across all four feature-matrix combinations, `lyric test
--manifest lyric-aws-secrets/lyric.toml`:

- bare (default → `local`) — 27/27
- `--features local` — 27/27
- `--no-default-features --features aws` — 27/27 (the new real content:
  `init()` still correctly NOT_IMPLEMENTED per #6866,
  `getSecret`/`getParameter` never panic without live AWS
  credentials/region and correctly surface a typed `NetworkError`,
  `classifySecretsError`/`classifyParameterError`/`extractSecretField`/
  `extractSecretValue`/`secretCacheKeyFor`/`parameterCacheKeyFor` all
  covered pure-logic, mirroring the jvm kernel's own test structure)
- `--target jvm --no-default-features --features jvm` — 27/27 (confirms
  zero regression on the untouched jvm kernel)

No live or mocked AWS Secrets Manager/SSM endpoint round-trip was
attempted (same documented limitation as the #5411 JVM shipment) — the
"no credentials configured" failure path is what this sandbox can
exercise, and it is exercised for real (a genuine SDK call reaches the
network layer and fails with the SDK's own "No RegionEndpoint or
ServiceURL configured" message, correctly classified).

**Related:** #6864 (this entry), #5411/D-progress-891 (the parent
investigation and JVM shipment), #6866 (the separate, still-open
`initFromAnnotations()` compiler gap), #6891 (the JVM-side
monomorphisation gap this entry's fix works around differently for MSIL),
`lyric-stdlib/std/_kernel/http_host.l` (the `Std.HttpHost` precedent this
binding mirrors).
