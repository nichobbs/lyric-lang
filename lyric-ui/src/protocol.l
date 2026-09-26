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
//!   {"t":"session","id":"9f2c..."}       the session id to quote on reconnect
//!
//! Host to server:
//!
//!   {"t":"hello","pv":2,"url":"/customers/7","sid":"9f2c..."}   sid only on reconnect
//!   {"t":"event","v":12,"p":[0,"cust-42",1],"e":"input","d":"Acme","iv":7}
//!   {"t":"sync"}                          request a full re-render
//!
//! An event path names each node on the way down by its key when it has
//! one (a JSON string) and by its child index otherwise (a number), so an
//! event still reaches the node it was aimed at, or is dropped, when the
//! tree changed in between (D138, Q-UI-005).  Patch paths are child indices
//! only: patches apply in order to a tree that matches the session's.
//!
//! Patch operations and wire nodes are documented on `encodePatch` and
//! `encodeNode`.  JSON is produced and parsed with the cross-target
//! `JsonRpc.Json` value model, so the protocol is identical on every target.
@runtime_checked
package Ui.Protocol

import Std.Core
import JsonRpc.Json.{JsonValue, JsonField, JNull, JBool, JInt, JString, JArray, JObject, parseValue, writeValue, getString, getInt, getArray, asInt, asString, JsonParseError}
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, Patch, Replace, Insert, Remove, Move, SetProp, RemoveProp, SetText, SetEvents}

/// The protocol version the TypeScript runtime must match.
pub val protocolVersion: Int = 2

// ─── Host to server ───────────────────────────────────────────────────────────
/// One step of an event path: a child found by its key, or by its index
/// when it has no key.
pub union NodeRef {
  case At(index: Int)
  case Keyed(key: String)
}

/// An interaction reported by a host: the node path, the event name, the
/// event data (the input's text for `input`/`change`), and the input
/// version for text inputs (0 when not applicable; docs/65 §9.4).
pub record Event {
  renderVersion: Int
  path: List[NodeRef]
  name: String
  data: String
  inputVersion: Int
}

/// A message from a host.  `sessionId` is empty on a first connection and
/// carries the id from the server's `session` message on a reconnect.
pub union ClientMessage {
  case Hello(protocolVersion: Int, url: String, sessionId: String)
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
  val t = match getString(v, "t") { case Some(s) -> s; case None -> return Err(error = "missing message type") }
  if t == "sync" {
    return Ok(value = Sync)
  }
  if t == "hello" {
    val pv = match getInt(v, "pv") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "hello: missing protocol version")
    }
    val url = match getString(v, "url") { case Some(s) -> s; case None -> "/" }
    val sid = match getString(v, "sid") { case Some(s) -> s; case None -> "" }
    return Ok(value = Hello(protocolVersion = pv, url = url, sessionId = sid))
  }
  if t == "event" {
    val rv = match getInt(v, "v") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "event: missing render version")
    }
    val items = match getArray(v, "p") { case Some(xs) -> xs; case None -> return Err(error = "event: missing path") }
    val path: List[NodeRef] = newList()
    for item in items {
      match decodeRef(item) {
        case Some(r) -> path.add(r)
        case None -> return Err(error = "event: path steps must be non-negative indices or non-empty keys")
      }
    }
    val name = match getString(v, "e") { case Some(s) -> s; case None -> return Err(error = "event: missing event name") }
    val data = match getString(v, "d") { case Some(s) -> s; case None -> "" }
    val iv = match getInt(v, "iv") { case Some(n) -> n.toInt(); case None -> 0 }
    return Ok(
      value = EventMsg(event = Event(renderVersion = rv, path = path, name = name, data = data, inputVersion = iv))
    )
  }
  return Err(error = "unknown message type '" + t + "'")
}

// A path step: a non-negative index, or a non-empty key.
func decodeRef(item: in JsonValue): Option[NodeRef] {
  match asInt(item) {
    case Some(n) -> if n >= 0 and n <= 1_000_000 { return Some(value = At(index = n.toInt())) }
    case None -> ()
  }
  match asString(item) {
    case Some(k) -> if k.length > 0 { return Some(value = Keyed(key = k)) }
    case None -> ()
  }
  return None
}

// ─── Server to host ───────────────────────────────────────────────────────────
/// The input version to send with a `value` update at a patch path (keyed
/// by `pathKey`), so the host can ignore a stale echo of its own typing
/// (docs/65 §9.4).
pub record ValueEcho {
  pathKey: String
  version: Int
}

/// A canonical string key for a patch path, e.g. `"0.3.1"`.
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

/// A canonical, unambiguous string key for an event path.  Keys are
/// length-prefixed, so no key text can make two different paths collide.
pub func refsKey(path: in List[NodeRef]): String {
  var s = ""
  for r in path {
    match r {
      case At(i) -> {
        s = s + "i" + i.toString() + ";"
      }
      case Keyed(k) -> {
        s = s + "k" + k.length.toString() + ":" + k
      }
    }
  }
  return s
}

/// The echo version for the value at patch path `path`, or 0.
pub func echoVersionAt(echoes: in List[ValueEcho], path: in List[Int]): Int {
  val k = pathKey(path)
  for e in echoes {
    if e.pathKey == k {
      return e.version
    }
  }
  return 0
}

/// The session id message, sent once when a session starts.
pub func encodeSession(id: in String): String {
  val fs: List[JsonField] = newList()
  fs.add(fld("t", JString(value = "session")))
  fs.add(fld("id", JString(value = id)))
  return writeValue(JObject(fields = fs))
}

/// A patch message for render `version`.
pub func encodePatches(version: in Int, patches: in List[Patch], echoes: in List[ValueEcho]): String {
  val ops: List[JsonValue] = newList()
  for p in patches {
    ops.add(encodePatch(p, echoes))
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
pub func encodePatch(p: in Patch, echoes: in List[ValueEcho]): JsonValue {
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
        val iv = echoVersionAt(echoes, path)
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
