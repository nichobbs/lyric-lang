//! tests/lambda_webbridge_tests.l — proves `Lambda.Kernel.WebBridge`'s
//! `ConditionalWeakTable<LambdaRouter, Web.Router>` registry (the issue
//! #5412 feasibility spike) actually round-trips: register a `Web.Router`,
//! resolve its `LambdaRouter` token back to the same router (with no
//! cross-token collision), and confirm `Lambda.withRouter` itself wires the
//! same registry end to end. See `_kernel/lambda_kernel_web.l`'s
//! header comment for the full write-up of what was proven and what
//! remains out of scope (full API Gateway event -> Router dispatch).
//!
//! The whole module is gated by a file-level `@cfg(feature = "web")`: without
//! that feature (the default, and every `--features local`/`jvm` run) it reports
//! `0 test(s), module gated by inactive @cfg` and exits 0. `ConditionalWeakTable`
//! is .NET-only, so with `web` active this runs on `--target dotnet`:
//!   lyric test --manifest lyric-lambda/lyric.toml --features web
@cfg(feature = "web")
@test_module
package Lambda.WebBridgeTests

import Std.Core
import Std.Testing
import Web
import Lambda
import Lambda.Kernel.WebBridge as WebBridge

test "createRouterToken + lookupRouter: a registered router resolves back to itself" {
  val router = Web.prefix(Web.create(), "/mock-a")
  val token = WebBridge.createRouterToken(router)
  match WebBridge.lookupRouter(token) {
    case Some(resolved) -> assertEqual(
      resolved.pathPrefix,
      "/mock-a",
      "resolved router is the one registered under this token"
    )
    case None -> assertTrue(false, "expected the registered router to resolve, got None")
  }
}

test "createRouterToken + lookupRouter: two tokens resolve independently (no collision)" {
  val routerA = Web.prefix(Web.create(), "/mock-b1")
  val routerB = Web.prefix(Web.create(), "/mock-b2")
  val tokenA = WebBridge.createRouterToken(routerA)
  val tokenB = WebBridge.createRouterToken(routerB)
  match WebBridge.lookupRouter(tokenA) {
    case Some(resolved) -> assertEqual(resolved.pathPrefix, "/mock-b1", "token A resolves to router A")
    case None -> assertTrue(false, "expected token A to resolve")
  }
  match WebBridge.lookupRouter(tokenB) {
    case Some(resolved) -> assertEqual(resolved.pathPrefix, "/mock-b2", "token B resolves to router B")
    case None -> assertTrue(false, "expected token B to resolve")
  }
}

test "Lambda.withRouter: attaching a router populates LambdaApp.httpRouter with a resolvable token" {
  val router = Web.prefix(Web.create(), "/mock-c")
  val app = Lambda.withRouter(Lambda.newApp(), router)
  match app.httpRouter {
    case Some(lr) -> {
      match WebBridge.lookupRouter(lr) {
        case Some(resolved) -> assertEqual(
          resolved.pathPrefix,
          "/mock-c",
          "Lambda.withRouter's token resolves back to the exact router passed in"
        )
        case None -> assertTrue(false, "expected the withRouter-registered token to resolve")
      }
    }
    case None -> assertTrue(false, "expected Lambda.withRouter to populate httpRouter")
  }
}
