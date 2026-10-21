//! client.l - Ui.Native.Client: the host side of the session protocol (docs/65 §9, docs/67 G10).
//!
//! The web host's TypeScript runtime mirrors the session's tree and applies patches to it; this is
//! the same job in Lyric for the native host.  `decodeServer` reads the JSON messages an
//! `Ui.Host.Instance` sends through its outbox (the inverse of `Ui.Protocol.encodePatches` and
//! its siblings), and `applyServer` folds a patch message into a `WireNode` tree with the
//! reference applier `Ui.Diff.applyPatches`.  A text input's value patch carries the input version
//! of the edit it answers (`iv`); a patch older than the edit the user has made since is a stale
//! echo and is dropped, as the web runtime does.
//!
//! `eventPath` is the path a host puts in an event: each step is the node's key when it has one
//! and its index otherwise (D138), so the session still finds the node the user acted on, or drops
//! the event, when the tree changed in between.
@pure
package Ui.Native.Client

import Std.Core
import Std.Collections
import Std.JsonValue.{JsonValue, JNull, JBool, JInt, JString, JArray, JObject, parseValue, getString, getInt, getArray, asInt, asString, JsonParseError}
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, Patch, Replace, Insert, Remove, Move, SetProp, RemoveProp, SetText, SetEvents, applyPatch, childrenOfWire}
import Ui.Protocol.{NodeRef, At, Keyed}

/// One patch with the input version its `value` update answers (0 when it has none).
pub record Op {
  patch: Patch
  inputVersion: Int
}

/// A message from the session.
pub union ServerMessage {
  case PatchMsg(version: Int, ops: List[Op])
  case NavigateMsg(url: String)
  case BackMsg
  case ToastMsg(message: String, level: String)
  case SessionIdMsg(id: String)
}

/// Decodes one server message; `Err` names what is malformed.
pub func decodeServer(text: in String): Result[ServerMessage, String] {
  val v = match parseValue(text) {
    case Ok(j) -> j
    case Err(e) -> return Err(error = "malformed JSON: " + JsonParseError.message(e))
  }
  val t = match getString(v, "t") { case Some(s) -> s; case None -> return Err(error = "missing message type") }
  if t == "patch" {
    val version = match getInt(v, "v") { case Some(n) -> n.toInt(); case None -> 0 }
    val items = match getArray(v, "ops") { case Some(xs) -> xs; case None -> return Err(error = "patch: missing ops") }
    val ops: List[Op] = newList()
    for item in items {
      match decodeOp(item) {
        case Ok(op) -> ops.add(op)
        case Err(e) -> return Err(error = "patch: " + e)
      }
    }
    return Ok(value = PatchMsg(version = version, ops = ops))
  }
  if t == "navigate" {
    return Ok(value = NavigateMsg(url = match getString(v, "url") { case Some(s) -> s; case None -> "/" }))
  }
  if t == "back" {
    return Ok(value = BackMsg)
  }
  if t == "toast" {
    val m = match getString(v, "m") { case Some(s) -> s; case None -> "" }
    val level = match getString(v, "level") { case Some(s) -> s; case None -> "info" }
    return Ok(value = ToastMsg(message = m, level = level))
  }
  if t == "session" {
    return Ok(value = SessionIdMsg(id = match getString(v, "id") { case Some(s) -> s; case None -> "" }))
  }
  Err(error = "unknown message type '" + t + "'")
}

func pathOf(v: JsonValue): Option[List[Int]] {
  val items = match getArray(v, "p") { case Some(xs) -> xs; case None -> return None }
  val path: List[Int] = newList()
  for item in items {
    match asInt(item) {
      case Some(n) -> path.add(n.toInt())
      case None -> return None
    }
  }
  Some(value = path)
}

func stringsOf(v: JsonValue, name: String): List[String] {
  val acc: List[String] = newList()
  match getArray(v, name) {
    case Some(xs) -> {
      for x in xs {
        match asString(x) {
          case Some(s) -> acc.add(s)
          case None -> ()
        }
      }
    }
    case None -> ()
  }
  acc
}

/// Decodes a wire node (the inverse of `Ui.Protocol.encodeNode`).
pub func decodeNode(v: in JsonValue): Result[WireNode, String] {
  val t = match getString(v, "t") { case Some(s) -> s; case None -> return Err(error = "node without a type") }
  if t == "empty" {
    return Ok(value = WEmpty)
  }
  if t == "text" {
    return Ok(value = WText(value = match getString(v, "v") { case Some(s) -> s; case None -> "" }))
  }
  if t == "el" {
    val kind = match getString(v, "k") { case Some(s) -> s; case None -> return Err(error = "element without a kind") }
    val key = match getString(v, "key") { case Some(s) -> s; case None -> "" }
    val props: List[Prop] = newList()
    match v {
      case JObject(fields) -> {
        for f in fields {
          if f.name == "p" {
            match f.value {
              case JObject(pf) -> {
                for p in pf {
                  match asString(p.value) {
                    case Some(s) -> props.add(Prop(name = p.name, value = s))
                    case None -> ()
                  }
                }
              }
              case _ -> ()
            }
          }
        }
      }
      case _ -> ()
    }
    val children: List[WireNode] = newList()
    match getArray(v, "c") {
      case Some(xs) -> {
        for x in xs {
          match decodeNode(x) {
            case Ok(c) -> children.add(c)
            case Err(e) -> return Err(error = e)
          }
        }
      }
      case None -> ()
    }
    return Ok(value = WElement(kind = kind, key = key, props = props, events = stringsOf(v, "e"), children = children))
  }
  Err(error = "unknown node type '" + t + "'")
}

func decodeOp(v: JsonValue): Result[Op, String] {
  val op = match getString(v, "op") { case Some(s) -> s; case None -> return Err(error = "operation without a name") }
  val path = match pathOf(v) { case Some(p) -> p; case None -> return Err(error = op + ": bad path") }
  val iv = match getInt(v, "iv") { case Some(n) -> n.toInt(); case None -> 0 }
  if op == "replace" or op == "insert" {
    val nodeJson = match v {
      case JObject(fields) -> {
        var found: Option[JsonValue] = None
        for f in fields {
          if f.name == "n" {
            found = Some(value = f.value)
          }
        }
        found
      }
      case _ -> None
    }
    val node = match nodeJson {
      case Some(j) -> match decodeNode(j) { case Ok(n) -> n; case Err(e) -> return Err(error = op + ": " + e) }
      case None -> return Err(error = op + ": missing node")
    }
    if op == "replace" {
      return Ok(value = Op(patch = Replace(path = path, node = node), inputVersion = 0))
    }
    val index = match getInt(v, "i") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "insert: missing index")
    }
    return Ok(value = Op(patch = Insert(path = path, index = index, node = node), inputVersion = 0))
  }
  if op == "remove" {
    val index = match getInt(v, "i") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "remove: missing index")
    }
    return Ok(value = Op(patch = Remove(path = path, index = index), inputVersion = 0))
  }
  if op == "move" {
    val from = match getInt(v, "from") {
      case Some(n) -> n.toInt()
      case None -> return Err(error = "move: missing from")
    }
    val to = match getInt(v, "to") { case Some(n) -> n.toInt(); case None -> return Err(error = "move: missing to") }
    return Ok(value = Op(patch = Move(path = path, from = from, to = to), inputVersion = 0))
  }
  if op == "setProp" {
    val k = match getString(v, "k") { case Some(s) -> s; case None -> return Err(error = "setProp: missing name") }
    val value = match getString(v, "v") { case Some(s) -> s; case None -> "" }
    return Ok(value = Op(patch = SetProp(path = path, name = k, value = value), inputVersion = iv))
  }
  if op == "removeProp" {
    val k = match getString(v, "k") { case Some(s) -> s; case None -> return Err(error = "removeProp: missing name") }
    return Ok(value = Op(patch = RemoveProp(path = path, name = k), inputVersion = 0))
  }
  if op == "setText" {
    return Ok(
      value = Op(
        patch = SetText(
          path = path,
          value = match getString(v, "v") { case Some(s) -> s; case None -> "" }
        ),
        inputVersion = 0
      )
    )
  }
  if op == "setEvents" {
    return Ok(value = Op(patch = SetEvents(path = path, events = stringsOf(v, "e")), inputVersion = 0))
  }
  Err(error = "unknown operation '" + op + "'")
}

/// The node at `path` below `root`, or `None` when the path does not resolve.
pub func nodeAt(root: in WireNode, path: in List[Int]): Option[WireNode] {
  var n = root
  for i in path {
    val cs = childrenOfWire(n)
    if i < 0 or i >= cs.count {
      return None
    }
    n = cs[i]
  }
  Some(value = n)
}

/// The path of an event aimed at the node at `path`: its key when it has one, else its index.
pub func eventPath(root: in WireNode, path: in List[Int]): List[NodeRef] {
  val refs: List[NodeRef] = newList()
  var n = root
  for i in path {
    val cs = childrenOfWire(n)
    if i >= 0 and i < cs.count {
      n = cs[i]
      val key = keyOfWire(n)
      if key.length > 0 {
        refs.add(Keyed(key = key))
      } else {
        refs.add(At(index = i))
      }
    }
  }
  refs
}

/// A wire node's key ("" for text, empty nodes and unkeyed elements).
pub func keyOfWire(n: in WireNode): String {
  match n {
    case WElement(_, key, _, _, _) -> key
    case _ -> ""
  }
}

/// `root` after the patch message `ops`.  `localVersion(path)` is the input version of the
/// latest edit the user made to the input at that path; a `value` patch carrying an older version
/// is a stale echo and is skipped.
pub func applyServer(root: in WireNode, ops: in List[Op], localVersion: in (List[Int]) -> Int): WireNode {
  var tree = root
  for op in ops {
    var skip = false
    match op.patch {
      case SetProp(path, name, _) -> {
        if name == "value" and op.inputVersion > 0 and op.inputVersion < localVersion(path) {
          skip = true
        }
      }
      case _ -> ()
    }
    if not skip {
      tree = applyPatch(tree, op.patch)
    }
  }
  tree
}
