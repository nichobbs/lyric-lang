//! TodoLsp — a small language server, packaged as a protocol plugin for the
//! editor in ../editor (docs/69 §4.3). It speaks LSP 3.17 over its stdin and
//! stdout with Content-Length framing, and needs nothing from the plugin
//! runtime: a server written in any language plugs in the same way.
//!
//! - `textDocument/didOpen` and `textDocument/didChange` (full sync) publish
//!   a warning for every line that contains `TODO`;
//! - `workspace/executeCommand` with `todo.markDone` and a document URI asks
//!   the editor, through `workspace/applyEdit`, to replace each `TODO` with
//!   `DONE`, and answers whether the editor applied the edit.
package TodoLsp

import Std.Core
import Std.Collections
import Std.Environment
import Std.Console as Console
import Std.String as Str
import Std.JsonValue
import Std.JsonRpc
import Std.JsonRpc.Stdio

val markDone: String = "todo.markDone"

func field(name: in String, v: in JsonValue): JsonField {
  JsonField(name = name, value = v)
}

func obj(fields: in List[JsonField]): JsonValue {
  JObject(fields = fields)
}

func str(s: in String): JsonValue {
  JString(value = s)
}

func int(n: in Int): JsonValue {
  JInt(value = n.toLong())
}

func position(line: in Int, character: in Int): JsonValue {
  obj([field("line", int(line)), field("character", int(character))])
}

func range(line: in Int, start: in Int, end: in Int): JsonValue {
  obj([field("start", position(line, start)), field("end", position(line, end))])
}

/// The zero-based line and character of every `TODO` in `text`.
record Mark {
  line: Int
  character: Int
}

func todoMarks(text: in String): List[Mark] {
  val acc: List[Mark] = newList()
  val lines = Str.split(text, "\n")
  var i = 0
  while i < lines.count {
    var from = 0
    while true {
      match Str.indexOfFrom(lines[i], "TODO", from) {
        case Some(at) -> {
          acc.add(Mark(line = i, character = at))
          from = at + 4
        }
        case None -> break
      }
    }
    i = i + 1
  }
  acc
}

func diagnosticsFor(uri: in String, text: in String): JsonValue {
  val items: List[JsonValue] = newList()
  for m in todoMarks(text) {
    items.add(
      obj(
        [
          field("range", range(m.line, m.character, m.character + 4)),
          field("severity", int(2)),
          field("source", str("todo-lsp")),
          field("message", str("TODO remains"))
        ]
      )
    )
  }
  obj([field("uri", str(uri)), field("diagnostics", JArray(items = items))])
}

func doneEdit(uri: in String, text: in String): JsonValue {
  val edits: List[JsonValue] = newList()
  for m in todoMarks(text) {
    edits.add(obj([field("range", range(m.line, m.character, m.character + 4)), field("newText", str("DONE"))]))
  }
  val changes = obj([field(uri, JArray(items = edits))])
  obj([field("label", str("Mark TODOs done")), field("edit", obj([field("changes", changes)]))])
}

func textDocumentUri(params: in Option[JsonValue]): Option[String] {
  match params {
    case Some(p) -> match getField(p, "textDocument") {
      case Some(td) -> getString(td, "uri")
      case None -> None
    }
    case None -> None
  }
}

pub ref record Server {
  var peer: Option[RpcPeer]
  var documents: Map[String, String]
}

func publish(server: in Server, uri: in String): Unit {
  val text = match server.documents.get(uri) { case Some(t) -> t; case None -> return }
  match server.peer {
    case Some(p) -> {
      var peer = p
      val _ = notify(peer, "textDocument/publishDiagnostics", Some(value = diagnosticsFor(uri, text)))
    }
    case None -> ()
  }
}

func badParams(message: in String): RpcError {
  RpcError(code = invalidParams, message = message, data = None)
}

impl RpcHandler for Server {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if method == "initialize" {
      val commands = JArray(items = [str(markDone)])
      val caps = obj(
        [field("textDocumentSync", int(1)), field("executeCommandProvider", obj([field("commands", commands)]))]
      )
      return Ok(
        value = obj(
          [field("capabilities", caps), field("serverInfo", obj([field("name", str("todo-lsp")), field("version", str("1.0.0"))]))]
        )
      )
    }
    if method == "shutdown" {
      return Ok(value = JNull)
    }
    if method == "workspace/executeCommand" {
      val p = match params { case Some(v) -> v; case None -> return Err(error = badParams("executeCommand needs params")) }
      val command = unwrapOr(getString(p, "command"), "")
      if command != markDone {
        return Err(error = badParams("unknown command: " + command))
      }
      val uri = match getArray(p, "arguments") {
        case Some(args) -> if args.count == 1 {
          match args[0] { case JString(s) -> s; case _ -> return Err(error = badParams("the argument is a URI")) }
        } else {
          return Err(error = badParams("todo.markDone takes one URI"))
        }
        case None -> return Err(error = badParams("todo.markDone takes one URI"))
      }
      val text = match self.documents.get(uri) {
        case Some(t) -> t
        case None -> return Err(error = badParams("document is not open: " + uri))
      }
      var peer = match self.peer { case Some(pr) -> pr; case None -> return Err(error = badParams("not connected")) }
      return match call(peer, "workspace/applyEdit", Some(value = doneEdit(uri, text))) {
        case Ok(answer) -> Ok(value = obj([field("applied", JBool(value = unwrapOr(getBool(answer, "applied"), false)))]))
        case Err(e) -> Err(error = e)
      }
    }
    Err(error = RpcError(code = methodNotFound, message = "method not found: " + method, data = None))
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
    if method == "exit" {
      exitCode(0)
    }
    if method == "textDocument/didOpen" {
      match params {
        case Some(p) -> match getField(p, "textDocument") {
          case Some(td) -> match (getString(td, "uri"), getString(td, "text")) {
            case (Some(uri), Some(text)) -> {
              self.documents.set(uri, text)
              publish(self, uri)
            }
            case _ -> ()
          }
          case None -> ()
        }
        case None -> ()
      }
    } else if method == "textDocument/didChange" {
      val uri = match textDocumentUri(params) { case Some(u) -> u; case None -> return }
      match params {
        case Some(p) -> match getArray(p, "contentChanges") {
          case Some(changes) -> if changes.count > 0 {
            match getString(changes[changes.count - 1], "text") {
              case Some(text) -> {
                self.documents.set(uri, text)
                publish(self, uri)
              }
              case None -> ()
            }
          }
          case None -> ()
        }
        case None -> ()
      }
    }
  }
}

func main(): Int {
  val server = Server(peer = None, documents = newMap())
  var peer = newPeer(newContentLengthTransport(), server)
  server.peer = Some(value = peer)
  match runLoop(peer) {
    case Ok(_) -> 0
    case Err(e) -> {
      Console.error("todo-lsp: " + e)
      1
    }
  }
}
