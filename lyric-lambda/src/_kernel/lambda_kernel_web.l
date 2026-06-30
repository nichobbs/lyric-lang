//! Lambda.Kernel.WebBridge — extern boundary for Web.Router ↔ LambdaRouter token registration.
//!
//! Compiled only when the `web` feature is active.
//!
//! Provides createRouterToken(router: Web.Router): LambdaRouter, which:
//!   1. Constructs a fresh LambdaRouter CLR instance (opaque, no fields).
//!   2. Registers it in Lambda.Kernel.Net's ConditionalWeakTable<LambdaRouter, Router>.
//!   3. Returns the token.
//!
//! The Lambda runtime dispatch loop (Lambda.Kernel.Runtime) reads
//! app.httpRouter: Option[LambdaRouter] via reflection; if Some(lr), it calls
//! Lambda.Kernel.Net.lookupRouter(lr) to retrieve the Web.Router for dispatch.
//!
//! See docs/35-lambda-library.md §Kernel, decision log D062.
@cfg(feature = "web")
package Lambda.Kernel.WebBridge

import Lambda
import Web

@axiom("Lambda.Kernel.Net .NET BCL shim: ConditionalWeakTable<LambdaRouter, Router> router token registry")
extern package Lambda.Kernel.Net {
  /// Register a Web.Router with the kernel's router registry.
  /// Returns a fresh LambdaRouter CLR instance as an opaque identity token.
  pub func createRouterToken(router: Web.Router): Lambda.LambdaRouter
}

pub func createRouterToken(router: in Web.Router): LambdaRouter {
  Lambda.Kernel.Net.createRouterToken(router)
}
