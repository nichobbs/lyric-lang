//! AwsSecrets.Kernel.Net (aws) — .NET AWS SDK extern boundary.
//!
//! NOT_IMPLEMENTED (issue #5411). This file used to be a bare `extern
//! package` block (`Amazon.SecretsManager { ... }` / `Amazon.
//! SimpleSystemsManagement { ... }`) — `extern package` emits no IL on any
//! backend, so every call through it was a silent runtime no-op trap, not
//! a real binding. It is now real (if not-yet-implemented) pure Lyric, so
//! a build under the `aws` feature at least fails loudly and predictably
//! rather than compiling a phantom call.
//!
//! Why this stays NOT_IMPLEMENTED rather than a real binding, precisely:
//!
//!   `#5411`'s original text claimed no `extern type` + auto-FFI
//!   precedent exists anywhere in this repo for a `Task<T>`-returning
//!   BCL/SDK async call — that claim is WRONG. `Std.HttpHost`
//!   (`lyric-stdlib/std/_kernel/http_host.l`) already binds
//!   `HttpClient.SendAsync`/`GetAsync`/`PostAsync` — all real
//!   `Task<HttpResponseMessage>`-returning BCL methods — via
//!   `@externInstance @externTarget("...") async func ...(...): T = ()`,
//!   and callers `await` them (`hostSendSafe`, etc.). The AWS .NET SDK's
//!   `AmazonSecretsManagerClient.GetSecretValueAsync(GetSecretValueRequest)`
//!   / `AmazonSimpleSystemsManagementClient.GetParameterAsync(...)` are
//!   the exact same shape (a plain instance method, non-generic, returning
//!   `Task<TResponse>`) — this is NOT blocked by #6581 (that issue is
//!   about generic-declaring-type ctors with a GENERICINST parameter and
//!   MethodSpec emission for user `@externTarget` GENERIC methods; these
//!   AWS SDK calls are neither).
//!
//!   The REAL blocker is a public-API-shape decision, not a compiler gap:
//!   `Std.HttpHost`'s callers are async all the way up (`Std.Http`'s
//!   entire public surface is `async func`, see `http.l`), but
//!   `AwsSecrets`'s public surface (`init()`/`getSecret()`/
//!   `getSecretField()`/`getParameter()`/`getParameterRaw()` in
//!   `secrets.l`) is synchronous, called from synchronous entry points —
//!   `func main(): Int` and every `lyric-lambda` handler registration
//!   (`lyric-lambda/src/direct.l`'s `DirectHandler` family is all plain
//!   `pub func`, not `pub async func`). Binding the real async SDK calls
//!   here would force `AwsSecrets`'s public functions to become `async
//!   func`, cascading into every call site this library's own doc
//!   comments and `docs/35-lambda-library.md` document as synchronous.
//!   That is a deliberate API-shape decision for the library (and
//!   possibly `lyric-lambda`'s handler signatures) to make, not something
//!   a kernel-only PR should force through as a side effect — tracked in
//!   issue #6864.
//!
//! initFromAnnotations(): additionally blocked on a SEPARATE, genuine
//!   compiler gap — scanning a compiled DLL's config-block metadata for
//!   @secretsManager/@parameterStore annotations at runtime has no
//!   supporting capability anywhere in the compiler or runtime (confirmed
//!   by a repo-wide grep; tracked in issue #6866). This would stay
//!   NOT_IMPLEMENTED even once the async-API-shape decision above is made.
//!
//! Enabled only when the "aws" feature flag is active.
//! See docs/35-lambda-library.md §6, docs/14-native-stdlib-plan.md.
@cfg(feature = "aws")
package AwsSecrets.Kernel.Net

import Std.Core
import AwsSecrets

func notImplemented(name: in String, detail: in String): AwsSecrets.SecretsError {
  NetworkError(
    name = name,
    message = "NOT_IMPLEMENTED on the aws (.NET) feature: " + detail +
      ". See lyric-aws-secrets/src/_kernel/secrets_kernel_aws.l's header for the precise reason (a public-API-shape decision, not a missing compiler capability; issue #6864, and #6866 for initFromAnnotations)."
  )
}

@stable(since = "0.1")
pub func initFromAnnotations(ttlSeconds: in Int): Result[Unit, AwsSecrets.SecretsError]
  requires: ttlSeconds >= 0
{
  return Err(
    error = notImplemented(
      "initFromAnnotations",
      "config-block annotation scanning has no supporting compiler capability (separate from the async-API-shape issue below)"
    )
  )
}

@stable(since = "0.1")
pub func fetchSecret(
  name: in String, key: in Option[String], ttlSeconds: in Int
): Result[String, AwsSecrets.SecretsError]
  requires: name.length > 0
  requires: ttlSeconds >= 0
{
  return Err(
    error = notImplemented(
      name,
      "AWSSDK.SecretsManager's GetSecretValueAsync needs AwsSecrets's public API to become async"
    )
  )
}

@stable(since = "0.1")
pub func fetchParameter(path: in String, decrypt: in Bool, ttlSeconds: in Int): Result[String, AwsSecrets.SecretsError]
  requires: path.length > 0
  requires: ttlSeconds >= 0
{
  return Err(
    error = notImplemented(
      path,
      "AWSSDK.SimpleSystemsManagement's GetParameterAsync needs AwsSecrets's public API to become async"
    )
  )
}
