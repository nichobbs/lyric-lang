//! tests/plugin_fixtures/greeter_component.l — a hand-written component
//! plugin for `plugin_component_e2e_tests.l`: the exports and imports the P5
//! contract (§2) asks `Lyric.PluginExpand` to generate for a `@plugin` record,
//! written out directly so the host's component mode is tested against the
//! contract rather than against the generator.
//!
//! Built with `--target native --triple wasm32-wasi --shape component`, it is
//! the WIT package `lyric:greeter`, exporting interface `lyric:greeter/greeter`:
//!
//!   - `plugin-describe`, `plugin-attach`, `plugin-methods` and
//!     `plugin-type-hints`;
//!   - the methods of point `Fixture.Api.Greeter` as `greeter-<method>`:
//!     `greet` (a point call), `secret` and `fetch` (capability imports,
//!     granted, narrowed by the grant and not granted), `shape` (a union
//!     result, named by the type hints), `count` (state a restart resets),
//!     `crash` (a trap), `spin` (a CPU loop that never yields) and `hog`
//!     (memory growth, capped by the host).
//!
//! The capabilities are imports `fixture-api-secrets.read` and
//! `fixture-api-net.fetch`, each returning `result<string, call-error-wire>`.
//! `scripts/ci/plugin-component-e2e.sh` builds it.
package Greeter

import Std.Core
import Std.Collections
import Std.String as Str

/// The boundary error of a capability call, as contract §2 generates it.
pub union CallErrorWire {
  case App(error: String)
  case Denied(reason: String)
  case NotGranted(capability: String)
  case Revoked(capability: String)
  case Unsupported(method: String)
  case ContractViolated(detail: String)
  case Timeout(timeoutMs: Int)
  case Crashed(detail: String)
  case Protocol(detail: String)
  case Stale
}

/// A union result: `Circle(radius)` or `Named(label)`.
pub union Shape {
  case Circle(radius: Double)
  case Named(label: String)
}

@wasmImport("fixture-api-secrets")
extern func secretsRead(key: String): Result[String, CallErrorWire] = "read"

@wasmImport("fixture-api-net")
extern func netFetch(url: String): Result[String, CallErrorWire] = "fetch"

record GreeterState {
  var attached: Bool
  var calls: Int
}

val state: GreeterState = GreeterState(attached = false, calls = 0)

val manifest: String = "{\"schema\":1,\"id\":\"lyric.test.greeter-component\",\"version\":\"1.0.0\"," + "\"publisher\":\"lyric\",\"points\":[{\"point\":\"Fixture.Api.Greeter\",\"version\":\"1.1\"," + "\"contributions\":{\"greeting\":\"hello\"}}],\"capabilities\":{\"required\":[{\"name\":" + "\"Fixture.Api.Secrets\",\"grant\":{\"keys\":[\"alpha\",\"beta\"]}}],\"optional\":[{\"name\":" + "\"Fixture.Api.Net\"}]}}"

val hints: String = "{\"exports\":{\"greeter-shape\":{\"result\":{\"result\":{\"ok\":{\"variant\":{\"circle\":" + "{\"field\":\"radius\"},\"named\":{\"field\":\"label\"}}}}}}}," + "\"imports\":{}}"

pub func pluginDescribe(): String {
  manifest
}

pub func pluginAttach(grants: String): Result[Unit, String] {
  if not Str.contains(grants, "\"Fixture.Api.Secrets\"") {
    return Err(error = "capability 'Fixture.Api.Secrets' is not granted")
  }
  state.attached = true
  Ok(value = ())
}

pub func pluginMethods(): List[String] {
  [
    "Fixture.Api.Greeter/greet",
    "Fixture.Api.Greeter/secret",
    "Fixture.Api.Greeter/fetch",
    "Fixture.Api.Greeter/shape",
    "Fixture.Api.Greeter/count",
    "Fixture.Api.Greeter/crash",
    "Fixture.Api.Greeter/spin",
    "Fixture.Api.Greeter/hog"
  ]
}

pub func pluginTypeHints(): String {
  hints
}

func describeError(e: in CallErrorWire): String {
  match e {
    case App(m) -> m
    case Denied(r) -> "boundary: denied: " + r
    case NotGranted(c) -> "boundary: not granted: " + c
    case Revoked(c) -> "boundary: capability '" + c + "' has been revoked"
    case Unsupported(m) -> "boundary: unsupported: " + m
    case ContractViolated(d) -> "boundary: contract violated: " + d
    case Timeout(ms) -> "boundary: timed out after " + ms.toString() + " ms"
    case Crashed(d) -> "boundary: crashed: " + d
    case Protocol(d) -> "boundary: protocol: " + d
    case Stale -> "boundary: stale"
  }
}

pub func greeterGreet(name: String): Result[String, String] {
  if not state.attached {
    return Err(error = "called before plugin-attach")
  }
  Ok(value = "hello, " + name)
}

pub func greeterSecret(key: String): Result[String, String] {
  match secretsRead(key) {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = describeError(e))
  }
}

pub func greeterFetch(): Result[String, String] {
  match netFetch("https://example.com") {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> Err(error = describeError(e))
  }
}

pub func greeterShape(round: Bool): Result[Shape, String] {
  if round {
    Ok(value = Circle(radius = 2.5))
  } else {
    Ok(value = Named(label = "square"))
  }
}

pub func greeterCount(): Result[Int, String] {
  state.calls = state.calls + 1
  Ok(value = state.calls)
}

pub func greeterCrash(): Result[String, String] {
  panic("greeter_component: crashing on request")
}

// Never yields and never returns: only the host's epoch deadline stops it.
pub func greeterSpin(): Result[String, String] {
  var n = 0
  while n != -1 {
    n = (n + 7) % 1000003
  }
  Ok(value = "unreachable")
}

// Grows a string to at least `megabytes` MiB.
pub func greeterHog(megabytes: Int): Result[Int, String] {
  var s = "0123456789abcdef"
  while s.length < megabytes * 1048576 {
    s = s + s
  }
  Ok(value = s.length / 1048576)
}
