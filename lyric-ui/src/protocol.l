//! Ui.Protocol — the JSON wire format between a session and a host
//! (docs/65-ui-library-sketch.md §9.3).
//! Stability: @experimental — Phase U1 of docs/65.  The format is versioned
//! by `protocolVersion`; the TypeScript runtime checks it on connect.
//!
//! Server to host, one JSON object per message:
//!
//!   {"t":"patch","v":12,"ops":[...]}      patches for render version 12
//!   {"t":"navigate","url":"/customers"}   change the address, keep the session
//!   {"t":"back"}                          history back
//!   {"t":"toast","m":"Saved","level":"success"}
//!
//! Host to server:
//!
//!   {"t":"hello","pv":1,"url":"/customers/7"}
//!   {"t":"event","v":12,"p":[0,3,1],"e":"input","d":"Acme","iv":7}
//!   {"t":"sync"}                          request a full re-render
//!
//! Patch operations and wire nodes are documented on `encodePatch` and
//! `encodeNode`.  JSON is produced and parsed with the cross-target
//! `JsonRpc.Json` value model, so the protocol is identical on every target.
@runtime_checked
package Ui.Protocol

import Std.Core
import JsonRpc.Json.{JsonValue, JsonField, JNull, JBool, JInt, JString, JArray, JObject, parseValue, writeValue, getString, getInt, getArray, asInt, JsonParseError}
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, Patch, Replace, Insert, Remove, Move, SetProp, RemoveProp, SetText, SetEvents}

/// The protocol version the TypeScript runtime must match.
pub val protocolVersion: Int = 1

// ─── Host to server ───────────────────────────────────────────────────────────
/// An interaction reported by a host: the node path, the event name, the
/// event data (the input's text for `input`/`change`), and the input
/// version for text inputs (0 when not applicable; docs/65 §9.4).
pub record Event {
  renderVersion: Int
  path: List[Int]
  name: String
  data: String
  inputVersion: Int
}

/// A message from a host.
pub union ClientMessage {
  case Hello(protocolVersion: Int, url: String)
  case EventMsg(event: Event)
  case Sync
}

/// Decodes one host message.  Unknown message types and malformed fields
/// are errors; the caller logs and drops them.
pub func decodeClient(text: in String): Result[ClientMessage, String] {
  val v = match parseValue(text) {
    case Ok(j) -> j
    case Err(e) -> return Err(error = "malformed JSON: " + JsonParseError.message(e))
  }
  val t = match getString(v, "t") {
    case Some(s) -> s
    case None -> return Err(error = "missing message type")
  }
  if t == "sync" {
    return Ok(value = Sync)
  }
  if t == "hello" {
    val pv = match getInt(v, "pv") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "hello: missing protocol version")
    }
    val url = match getString(v, "url") {
      case Some(s) -> s
      case None -> "/"
    }
    return Ok(value = Hello(protocolVersion = pv, url = url))
  }
  if t == "event" {
    val rv = match getInt(v, "v") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "event: missing render version")
    }
    val items = match getArray(v, "p") {
      case Some(xs) -> xs
      case None -> return Err(error = "event: missing path")
    }
    val path: List[Int] = newList()
    for item in items {
      match asInt(item) {
        case Some(n) -> path.add(n.toInt())
        case None -> return Err(error = "event: path must be integers")
      }
    }
    val name = match getString(v, "e") {
      case Some(s) -> s
      case None -> return Err(error = "event: missing event name")
    }
    val data = match getString(v, "d") {
      case Some(s) -> s
      case None -> ""
    }
    val iv = match getInt(v, "iv") {
      case Some(n) -> n.toInt()
      case None -> 0
    }
    return Ok(value = EventMsg(event = Event(renderVersion = rv, path = path, name = name, data = data, inputVersion = iv)))
  }
  return Err(error = "unknown message type '" + t + "'")
}

// ─── Server to host ───────────────────────────────────────────────────────────
/// The input version last processed for the input at a path key (see
/// `pathKey`).  Sent with `value` updates so hosts can ignore stale echoes.
pub record InputVersion {
  pathKey: String
  version: Int
}

/// A canonical string key for a path, e.g. `"0.3.1"`.
pub func pathKey(path: in List[Int]): String {
  var s = ""
  var first = true
  for p in path {
    if not first {
      s = s + "."
    }
    s = s + p.toString()
    first = false
  }
  return s
}

/// The recorded input version for `path`, or 0.
pub func inputVersionAt(ivs: in List[InputVersion], path: in List[Int]): Int {
  val k = pathKey(path)
  for iv in ivs {
    if iv.pathKey == k {
      return iv.version
    }
  }
  return 0
}

/// A patch message for render `version`.
pub func encodePatches(version: in Int, patches: in List[Patch], ivs: in List[InputVersion]): String {
  val ops: List[JsonValue] = newList()
  for p in patches {
    ops.add(encodePatch(p, ivs))
  }
  val fs: List[JsonField] = newList()
  fs.add(fld("t", JString(value = "patch")))
  fs.add(fld("v", JInt(value = version.toLong())))
  fs.add(fld("ops", JArray(items = ops)))
  return writeValue(JObject(fields = fs))
}

/// A navigation message.
pub func encodeNavigate(url: in String): String {
  val fs: List[JsonField] = newList()
  fs.add(fld("t", JString(value = "navigate")))
  fs.add(fld("url", JString(value = url)))
  return writeValue(JObject(fields = fs))
}

/// A history-back message.
pub func encodeBack(): String {
  val fs: List[JsonField] = newList()
  fs.add(fld("t", JString(value = "back")))
  return writeValue(JObject(fields = fs))
}

/// A toast message.
pub func encodeToast(message: in String, level: in String): String {
  val fs: List[JsonField] = newList()
  fs.add(fld("t", JString(value = "toast")))
  fs.add(fld("m", JString(value = message)))
  fs.add(fld("level", JString(value = level)))
  return writeValue(JObject(fields = fs))
}

/// One patch operation:
///
///   {"op":"replace","p":[..],"n":NODE}
///   {"op":"insert","p":[..],"i":2,"n":NODE}
///   {"op":"remove","p":[..],"i":2}
///   {"op":"move","p":[..],"from":4,"to":1}
///   {"op":"setProp","p":[..],"k":"value","v":"Acme","iv":7}   (iv only for value)
///   {"op":"removeProp","p":[..],"k":"disabled"}
///   {"op":"setText","p":[..],"v":"Saving..."}
///   {"op":"setEvents","p":[..],"e":["click"]}
pub func encodePatch(p: in Patch, ivs: in List[InputVersion]): JsonValue {
  val fs: List[JsonField] = newList()
  match p {
    case Replace(path, node) -> {
      fs.add(fld("op", JString(value = "replace")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("n", encodeNode(node)))
    }
    case Insert(path, index, node) -> {
      fs.add(fld("op", JString(value = "insert")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("i", JInt(value = index.toLong())))
      fs.add(fld("n", encodeNode(node)))
    }
    case Remove(path, index) -> {
      fs.add(fld("op", JString(value = "remove")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("i", JInt(value = index.toLong())))
    }
    case Move(path, from, to) -> {
      fs.add(fld("op", JString(value = "move")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("from", JInt(value = from.toLong())))
      fs.add(fld("to", JInt(value = to.toLong())))
    }
    case SetProp(path, name, value) -> {
      fs.add(fld("op", JString(value = "setProp")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("k", JString(value = name)))
      fs.add(fld("v", JString(value = value)))
      if name == "value" {
        val iv = inputVersionAt(ivs, path)
        if iv > 0 {
          fs.add(fld("iv", JInt(value = iv.toLong())))
        }
      }
    }
    case RemoveProp(path, name) -> {
      fs.add(fld("op", JString(value = "removeProp")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("k", JString(value = name)))
    }
    case SetText(path, value) -> {
      fs.add(fld("op", JString(value = "setText")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("v", JString(value = value)))
    }
    case SetEvents(path, events) -> {
      fs.add(fld("op", JString(value = "setEvents")))
      fs.add(fld("p", encodePath(path)))
      fs.add(fld("e", encodeStrings(events)))
    }
  }
  return JObject(fields = fs)
}

/// A wire node:
///
///   {"t":"el","k":"button","key":"","p":{"label":"Save"},"e":["click"],"c":[...]}
///   {"t":"text","v":"Hello"}
///   {"t":"empty"}
pub func encodeNode(n: in WireNode): JsonValue {
  val fs: List[JsonField] = newList()
  match n {
    case WElement(kind, key, props, events, children) -> {
      fs.add(fld("t", JString(value = "el")))
      fs.add(fld("k", JString(value = kind)))
      if key.length > 0 {
        fs.add(fld("key", JString(value = key)))
      }
      val ps: List[JsonField] = newList()
      for p in props {
        ps.add(fld(p.name, JString(value = p.value)))
      }
      fs.add(fld("p", JObject(fields = ps)))
      fs.add(fld("e", encodeStrings(events)))
      val cs: List[JsonValue] = newList()
      for c in children {
        cs.add(encodeNode(c))
      }
      fs.add(fld("c", JArray(items = cs)))
    }
    case WText(s) -> {
      fs.add(fld("t", JString(value = "text")))
      fs.add(fld("v", JString(value = s)))
    }
    case WEmpty -> fs.add(fld("t", JString(value = "empty")))
  }
  return JObject(fields = fs)
}

func encodePath(path: in List[Int]): JsonValue {
  val items: List[JsonValue] = newList()
  for p in path {
    items.add(JInt(value = p.toLong()))
  }
  return JArray(items = items)
}

func encodeStrings(xs: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for x in xs {
    items.add(JString(value = x))
  }
  return JArray(items = items)
}

func fld(name: in String, value: in JsonValue): JsonField {
  return JsonField(name = name, value = value)
}
