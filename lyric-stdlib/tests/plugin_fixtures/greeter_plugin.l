//! tests/plugin_fixtures/greeter_plugin.l — a hand-written plugin for
//! `plugin_e2e_tests.l`, implementing `Std.Plugin.PluginServer` directly
//! (the code `Lyric.PluginExpand` would generate for a `@plugin` record).
//!
//! It implements point `Fixture.Api.Greeter` 1.1, requires capability
//! `Fixture.Api.Secrets` (grant `{"keys": [...]}`) and may use
//! `Fixture.Api.Net`. Its methods exercise each part of the protocol:
//! `greet` (a plain point call), `secret` and `fetch` (capability calls back
//! into the host, granted and not), `slow` (a call that outlives the host's
//! timeout), `count` (state that a restart resets) and `crash` (the process
//! exits mid-call). `scripts/ci/plugin-e2e.sh` builds it.
package PluginFixture.Greeter

import Std.Core
import Std.Collections
import Std.Environment
import Std.Time
import Std.JsonValue
import Std.JsonRpc
import Std.Plugin

val greeterPoint: String = "Fixture.Api.Greeter"

val secretsCapability: String = "Fixture.Api.Secrets"

@cfg(target = "dotnet")
func crashNow(): Unit {
  exitCode(3)
}

@cfg(target = "jvm")
func crashNow(): Unit {
  exitCode(3)
}

// `exitCode` has no native lowering yet (#6901); a panic aborts a native
// program, which is the crash this method exists to cause.
@cfg(target = "native")
func crashNow(): Unit {
  panic("greeter_plugin: crashing on request")
}

func obj(fields: in List[JsonField]): JsonValue {
  JObject(fields = fields)
}

func one(name: in String, v: in JsonValue): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = name, value = v))
  JObject(fields = fields)
}

func strings(xs: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  var i = 0
  while i < xs.count {
    items.add(JString(value = xs[i]))
    i = i + 1
  }
  JArray(items = items)
}

func okString(s: in String): Result[JsonValue, RpcError] {
  Ok(value = one("ok", JString(value = s)))
}

func paramString(params: in Option[JsonValue], key: in String): String {
  match params {
    case Some(p) -> match getString(p, key) { case Some(s) -> s; case None -> "" }
    case None -> ""
  }
}

func paramInt(params: in Option[JsonValue], key: in String): Int {
  match params {
    case Some(p) -> match getInt(p, key) { case Some(n) -> n.toInt(); case None -> 0 }
    case None -> 0
  }
}

// The result of a capability call as this plugin's own result: the host's
// `{"ok"}`/`{"err"}` object, or `{"err": "boundary: <message>"}`.
func relay(r: in Result[JsonValue, BoundaryError]): Result[JsonValue, RpcError] {
  match r {
    case Ok(v) -> Ok(value = v)
    case Err(b) -> Ok(value = one("err", JString(value = "boundary: " + boundaryErrorMessage(b))))
  }
}

pub ref record GreeterServer {
  var conn: Option[PluginConnection]
  var calls: Int
}

impl PluginServer for GreeterServer {
  func describe(): JsonValue {
    val point: List[JsonField] = newList()
    point.add(JsonField(name = "point", value = JString(value = greeterPoint)))
    point.add(JsonField(name = "version", value = JString(value = "1.1")))
    point.add(JsonField(name = "contributions", value = one("greeting", JString(value = "hello"))))
    val points: List[JsonValue] = newList()
    points.add(obj(point))
    val secrets: List[JsonField] = newList()
    secrets.add(JsonField(name = "name", value = JString(value = secretsCapability)))
    secrets.add(JsonField(name = "grant", value = one("keys", strings(["alpha", "beta"]))))
    val required: List[JsonValue] = newList()
    required.add(obj(secrets))
    val optional: List[JsonValue] = newList()
    optional.add(one("name", JString(value = "Fixture.Api.Net")))
    val caps: List[JsonField] = newList()
    caps.add(JsonField(name = "required", value = JArray(items = required)))
    caps.add(JsonField(name = "optional", value = JArray(items = optional)))
    val fields: List[JsonField] = newList()
    fields.add(JsonField(name = "schema", value = JInt(value = 1i64)))
    fields.add(JsonField(name = "id", value = JString(value = "lyric.test.greeter")))
    fields.add(JsonField(name = "version", value = JString(value = "1.0.0")))
    fields.add(JsonField(name = "publisher", value = JString(value = "lyric")))
    fields.add(JsonField(name = "points", value = JArray(items = points)))
    fields.add(JsonField(name = "capabilities", value = obj(caps)))
    obj(fields)
  }

  func attach(conn: in PluginConnection, grants: in List[GrantedCapability]): Result[Unit, BoundaryError] {
    var granted = false
    var i = 0
    while i < grants.count {
      if grants[i].capability == secretsCapability {
        granted = true
      }
      i = i + 1
    }
    if not granted {
      return Err(error = NotGranted(capability = secretsCapability))
    }
    self.conn = Some(value = conn)
    Ok(value = ())
  }

  func pointMethods(): List[PluginPointMethods] {
    val ms: List[PluginPointMethods] = newList()
    ms.add(
      PluginPointMethods(
        point = greeterPoint,
        version = "1.1",
        methods = ["greet", "secret", "fetch", "slow", "count", "crash"]
      )
    )
    ms
  }

  func dispatch(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    val conn = match self.conn {
      case Some(c) -> c
      case None -> return Err(error = boundaryErrorToRpc(Protocol(detail = "dispatch before attach")))
    }
    if method == "Fixture.Api.Greeter/greet" {
      okString("hello, " + paramString(params, "name"))
    } else if method == "Fixture.Api.Greeter/secret" {
      relay(callHost(conn, "cap/Fixture.Api.Secrets/read", one("key", JString(value = paramString(params, "key")))))
    } else if method == "Fixture.Api.Greeter/fetch" {
      relay(callHost(conn, "Fixture.Api.Net/fetch", one("url", JString(value = "https://example.com"))))
    } else if method == "Fixture.Api.Greeter/slow" {
      sleepMillis(paramInt(params, "ms"))
      okString("slept")
    } else if method == "Fixture.Api.Greeter/count" {
      self.calls = self.calls + 1
      Ok(value = one("ok", JInt(value = self.calls.toLong())))
    } else if method == "Fixture.Api.Greeter/crash" {
      crashNow()
      okString("unreachable")
    } else {
      Err(error = boundaryErrorToRpc(Unsupported(method = method)))
    }
  }
}

func main(): Int {
  runPlugin(GreeterServer(conn = None, calls = 0))
}
