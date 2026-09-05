//! tests/lambda_webbridge_tests.l — proves `Lambda.Kernel.WebBridge`'s
//! `ConditionalWeakTable<LambdaRouter, Web.Router>` registry (the issue
//! #5412 feasibility spike) actually round-trips: register a `Web.Router`,
//! resolve its `LambdaRouter` token back to the same router (with no
//! cross-token collision), and confirm `Lambda.withRouter` itself wires the
//! same registry end to end. See `_kernel/lambda_kernel_web.l`'s
//! header comment for the full write-up of what was proven and what
//! remains out of scope (full API Gateway event -> Router dispatch).
//!
//! **Not registered in `[project.tests]`** — and deliberately has no
//! `@cfg(feature = "web")` guard either, because both were tried and both
//! break `lyric test` for every OTHER `[project.tests]` entry in this
//! manifest whenever `web` is inactive (the default: CI's
//! `lyric test --manifest lyric-lambda/lyric.toml` and `--features local`
//! invocations never pass `web`). Filed as #6868: `Lyric.TestSynth`
//! synthesises `main()`'s calls to every `test { }` block in the file
//! *before* `Lyric.Cfg`'s erasure pass runs (confirmed via two isolated
//! repros — a file-level `@cfg` on the whole module compiles clean but
//! crashes at runtime with `System.MissingMethodException: Entry point not
//! found` once everything, including the synthesised `main`, erases; an
//! item-level `@cfg` on one `test { }` block among several in the same
//! file makes `main()`'s call to that block's synthesised function name a
//! genuine `T0020 unknown name` **compile** error, since erasure removes
//! the callee but `TestSynth` already emitted the call). This is a real,
//! previously-undiscovered gap in `@cfg`+`lyric test` interaction, not
//! specific to this file's content — until #6868 lands, a
//! `[project.tests]` entry that only compiles under a non-default feature
//! combination has no safe way to opt out of the default invocations.
//!
//! Verified manually against this exact tree (`--features web` only, no
//! `aws`/`local`/`jvm` needed — `ConditionalWeakTable` is .NET-only, so
//! this only ever runs `--target dotnet`): temporarily add
//! `"Lambda.WebBridgeTests" = "tests/lambda_webbridge_tests.l"` under
//! `[project.tests]` in `lyric.toml`, then:
//!   lyric test --manifest lyric-lambda/lyric.toml --features web
//! All 3 cases passed (see this PR's description for the captured output).
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
