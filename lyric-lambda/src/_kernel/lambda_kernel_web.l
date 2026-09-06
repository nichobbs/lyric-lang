//! Lambda.Kernel.WebBridge — extern boundary for Web.Router ↔ LambdaRouter
//! token registration.
//!
//! ## Feasibility spike result (issue #5412): the ConditionalWeakTable
//! pattern IS proven in this codebase
//!
//! The issue that motivated this file's original design flagged binding
//! `System.Runtime.CompilerServices.ConditionalWeakTable\`2[LambdaRouter,
//! Router]` — a closed BCL generic with two Lyric-native type arguments —
//! as "a pattern not yet proven anywhere else in the codebase, needing a
//! feasibility spike first". That framing undersold how close a precedent
//! already existed: `lyric-stdlib/std/_kernel/collections_host.l` binds
//! `extern type Map[K, V] = "System.Collections.Generic.Dictionary\`2"`
//! (plus `TryGetValue` via `@externInstance`) as the *entire* implementation
//! of `Std.Collections.Map` — the exact same "generic BCL container keyed by
//! two Lyric type arguments, .Add + .TryGetValue" shape this file needs.
//! `ConditionalWeakTable\`2` differs from `Dictionary\`2` in exactly one way
//! that matters here: the CLR constrains both its type parameters to
//! `class` (reference types) — `Dictionary\`2` has no such constraint.  That
//! made `LambdaRouter` (previously a zero-field `opaque type`, which this
//! codebase's compiler represents like every record/opaque type: not the
//! struct-or-class-by-size split `docs/09-msil-emission.md` originally
//! spec'd, which the self-hosted MSIL backend never implemented — searched
//! and confirmed absent) safe to use as `TKey` without a runtime
//! `TypeLoadException`; `Web.Router` (a multi-field record, always a
//! reference type here too) is safe as `TValue`.  Verified end-to-end by
//! `tests/lambda_webbridge_tests.l`: register a router, look it up by its
//! token, confirm it comes back unchanged, confirm an unregistered token
//! looks up `None`.
//!
//! The one genuinely new wrinkle `Dictionary\`2` didn't have: opaque-type
//! construction is restricted to the type's declaring package (T0100), so
//! this package (a different package from `Lambda`, where `LambdaRouter` is
//! declared) cannot call `LambdaRouter()` directly — `Lambda.newLambdaRouter()`
//! (an `internal` cross-package construction seam, see `lambda.l`) is used
//! instead.
//!
//! ## What this file provides, and what it still does NOT provide
//!
//! `createRouterToken`/`lookupRouter` are the complete, real
//! register-a-router / resolve-a-token-back-to-a-router primitive — the
//! literal "resolve a `LambdaRouter` token back to the `Web.Router` it
//! wraps" gap `Lambda.Dispatch.dispatchHttp`'s header comment named as
//! missing. What this file does NOT provide is the separate, larger feature
//! of actually routing an API Gateway v1/v2/ALB event *through* the resolved
//! `Web.Router` (extracting method/path/headers/body per event-shape,
//! running the router's match-and-dispatch logic, mapping the result back
//! to `ApiGwResponse`, applying CORS) — `docs/35-lambda-library.md` §4
//! describes that mapping in full, and it is real, scoped work independent
//! of this file's token-registry spike, tracked as a dedicated follow-up
//! (see `Lambda.Dispatch.dispatchHttp`'s updated header comment). Wiring
//! the registry here does not by itself make `Lambda.withRouter` traffic
//! dispatch — `dispatchHttp` still fails closed for API Gateway/ALB events,
//! now with a message naming the *actual* remaining gap instead of the
//! (now resolved) registry lookup.
//!
//! `LambdaRouter` values are compiler-generated opaque tokens, not ordinary
//! Lyric values a consumer could construct or inspect — CLR reference
//! identity is exactly the key `ConditionalWeakTable` needs, and exactly
//! why `Web.Router` (which has no meaningful `==`) never needs to implement
//! equality for this registry to work correctly.
//!
//! Compiled only when the `web` feature is active. Not target-gated beyond
//! that: `ConditionalWeakTable` is .NET-only, so a `--target jvm` build with
//! `feature = "web"` active would fail at the extern-type resolution stage
//! (there is no JVM binding for this BCL type) — tracked as a documented gap
//! rather than a silent skip, matching this file's original header note
//! that `web` was "mistakenly not target-gated". A JVM-side router bridge
//! (a plain `Map[LambdaRouter, Web.Router]`-shaped registry needs no weak
//! table at all, since the JVM target has no equivalent GC-pinning concern
//! for this use case) is out of scope here and untracked pending a real JVM
//! `feature = "web"` consumer.
//!
//! See docs/35-lambda-library.md §Kernel, decision log D062.
@cfg(feature = "web")
package Lambda.Kernel.WebBridge

import Std.Core
import Lambda
import Web

@axiom("System.Runtime.CompilerServices.ConditionalWeakTable<LambdaRouter, Router> conforms to its documented .NET contract")
extern type RouterRegistry[K, V] = "System.Runtime.CompilerServices.ConditionalWeakTable`2"

@externTarget("System.Runtime.CompilerServices.ConditionalWeakTable`2..ctor")
func newRouterRegistry[K, V](): RouterRegistry[K, V] = ()

/// `ConditionalWeakTable.Add` throws `ArgumentException` if the key is
/// already present — never the case here since every `LambdaRouter` token
/// is a freshly-constructed identity (`createRouterToken` below), used
/// exactly once as a key.
@externInstance
@externTarget("System.Runtime.CompilerServices.ConditionalWeakTable`2.Add")
func registryAdd[K, V](t: in RouterRegistry[K, V], key: in K, value: in V): Unit = ()

@externInstance
@externTarget("System.Runtime.CompilerServices.ConditionalWeakTable`2.TryGetValue")
func registryTryGetValue[K, V](t: in RouterRegistry[K, V], key: in K, value: out V): Bool = ()

// One process-wide registry.  A `LambdaApp` (and the `LambdaRouter` token it
// carries) is built once at startup and lives for the process's lifetime,
// so a `ConditionalWeakTable`'s "entries can be GC'd once the key is
// unreachable" behaviour is inert here in practice — it is simply the
// correct BCL type for "identity-keyed side table with no risk of leaking
// the table itself", not a design that depends on early collection.
val registry: RouterRegistry[LambdaRouter, Web.Router] = newRouterRegistry()

/// Register `router` and return a fresh opaque `LambdaRouter` token
/// identifying it.  Called by `Lambda.withRouter`.
pub func createRouterToken(router: in Web.Router): LambdaRouter {
  val lr = newLambdaRouter()
  registryAdd(registry, lr, router)
  return lr
}

/// Resolve a `LambdaRouter` token back to the `Web.Router` it wraps, or
/// `None` if the token was never registered (should not happen for a token
/// obtained via `createRouterToken`, but the lookup fails closed rather
/// than assuming).
pub func lookupRouter(lr: in LambdaRouter): Option[Web.Router] {
  var value: Web.Router = default()
  if registryTryGetValue(registry, lr, value) {
    return Some(value = value)
  }
  return None
}
