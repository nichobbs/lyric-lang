//! Editor.Host — a minimal editor that hosts language servers as protocol
//! plugins (docs/69 §4.3).
//!
//! It discovers the plugins in the directory given as its argument, reads
//! their `LanguageServer` contributions without starting them, opens a
//! supervised session with each, and speaks LSP 3.17 to it over the
//! session's process with Content-Length framing. The server's
//! `workspace/applyEdit` requests go through the `WorkspaceEdit` capability
//! on the server's behalf (`WorkspaceEditAs`), so the grant, revocation and
//! the capability's `requires:` guard decide whether an edit is applied.
//!
//! It exercises `example.todo-lsp` (../todo-server) and prints one `ok` or
//! `not ok` line per check; the exit status is the number of failures.
//! `scripts/ci/plugin-lsp-e2e.sh` runs it.
package Editor.Host

import Std.Core
import Std.Collections
import Std.Environment
import Std.String as Str
import Std.Process
import Std.JsonValue
import Std.JsonRpc
import Std.JsonRpc.Stdio
import Std.Plugin
import Editor.Lang

val todoServer: String = "example.todo-lsp"

val workspaceDoc: String = "file:///workspace/notes.txt"

val outsideDoc: String = "file:///elsewhere/secret.txt"

// ── The workspace: the editor's documents and the WorkspaceEdit capability ──
pub ref record Workspace {
  var documents: Map[String, String]
}

// The character offset of a zero-based (line, character) position.
func offsetOf(text: in String, line: in Int, character: in Int): Int {
  var offset = 0
  var l = 0
  while l < line {
    match Str.indexOfFrom(text, "\n", offset) {
      case Some(at) -> offset = at + 1
      case None -> return text.length
    }
    l = l + 1
  }
  offset + character
}

func applyTextEdits(text: in String, edits: in List[TextEdit]): String {
  // Apply from the end of the document backwards so earlier offsets stay valid.
  val ordered: List[TextEdit] = newList()
  for e in edits {
    var at = ordered.count
    var i = 0
    while i < ordered.count {
      val o = ordered[i]
      if e.startLine > o.startLine or (e.startLine == o.startLine and e.startCharacter > o.startCharacter) {
        at = i
        break
      }
      i = i + 1
    }
    ordered.insert(at, e)
  }
  var result = text
  for e in ordered {
    val start = offsetOf(result, e.startLine, e.startCharacter)
    val end = offsetOf(result, e.endLine, e.endCharacter)
    result = Str.substring(result, 0, start) + e.newText + Str.substring(result, end)
  }
  result
}

impl WorkspaceEdit for Workspace {
  func applyEdit(edit: in DocumentEdit): Result[Bool, String] {
    match self.documents.get(edit.uri) {
      case Some(text) -> {
        self.documents.set(edit.uri, applyTextEdits(text, edit.edits))
        Ok(value = true)
      }
      case None -> Ok(value = false)
    }
  }
}

// ── The LSP client side ────────────────────────────────────────────────────
func field(name: in String, v: in JsonValue): JsonField {
  JsonField(name = name, value = v)
}

func obj(fields: in List[JsonField]): JsonValue {
  JObject(fields = fields)
}

func str(s: in String): JsonValue {
  JString(value = s)
}

func intAt(v: in JsonValue, key: in String): Int {
  match getInt(v, key) {
    case Some(n) -> n.toInt()
    case None -> 0
  }
}

// An LSP `TextEdit` object as an Editor.Lang.TextEdit.
func textEditOf(v: in JsonValue): Option[TextEdit] {
  val r = match getField(v, "range") { case Some(x) -> x; case None -> return None }
  val s = match getField(r, "start") { case Some(x) -> x; case None -> return None }
  val e = match getField(r, "end") { case Some(x) -> x; case None -> return None }
  val newText = match getString(v, "newText") { case Some(t) -> t; case None -> return None }
  Some(
    value = TextEdit(
      startLine = intAt(s, "line"),
      startCharacter = intAt(s, "character"),
      endLine = intAt(e, "line"),
      endCharacter = intAt(e, "character"),
      newText = newText
    )
  )
}

pub ref record Client {
  host: PluginHost
  pluginId: String
  var diagnostics: Map[String, Int]
  var lastFailure: String
}

func applied(ok: in Bool, reason: in String): JsonValue {
  if ok {
    obj([field("applied", JBool(value = true))])
  } else {
    obj([field("applied", JBool(value = false)), field("failureReason", str(reason))])
  }
}

// Route one `workspace/applyEdit` through WorkspaceEdit, as the server.
func routeApplyEdit(client: in Client, params: in Option[JsonValue]): JsonValue {
  val changes = match params {
    case Some(p) -> match getField(p, "edit") {
      case Some(edit) -> match getField(edit, "changes") { case Some(c) -> c; case None -> return applied(false, "no changes") }
      case None -> return applied(false, "no edit")
    }
    case None -> return applied(false, "no params")
  }
  val docs = match changes { case JObject(fs) -> fs; case _ -> return applied(false, "changes is not an object") }
  val workspace = WorkspaceEditAs(host = client.host, pluginId = client.pluginId)
  for d in docs {
    val edits: List[TextEdit] = newList()
    match d.value {
      case JArray(items) -> for it in items {
        match textEditOf(it) {
          case Some(te) -> edits.add(te)
          case None -> return applied(false, "malformed TextEdit")
        }
      }
      case _ -> return applied(false, "the edits of " + d.name + " are not an array")
    }
    match workspace.applyEdit(DocumentEdit(uri = d.name, edits = edits)) {
      case Ok(done) -> if not done {
        return applied(false, "the editor declined the edit to " + d.name)
      }
      case Err(e) -> {
        val reason = match e {
          case App(msg) -> msg
          case Boundary(b) -> boundaryErrorMessage(b)
        }
        client.lastFailure = reason
        return applied(false, reason)
      }
    }
  }
  applied(true, "")
}

impl RpcHandler for Client {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if method == "workspace/applyEdit" {
      return Ok(value = routeApplyEdit(self, params))
    }
    Err(error = RpcError(code = methodNotFound, message = "method not found: " + method, data = None))
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
    if method == "textDocument/publishDiagnostics" {
      match params {
        case Some(p) -> match (getString(p, "uri"), getArray(p, "diagnostics")) {
          case (Some(uri), Some(items)) -> self.diagnostics.set(uri, items.count)
          case _ -> ()
        }
        case None -> ()
      }
    }
  }
}

// ── Checks ─────────────────────────────────────────────────────────────────
pub ref record Report {
  var failures: Int
}

func check(report: in Report, ok: in Bool, label: in String): Unit {
  if ok {
    println("ok - " + label)
  } else {
    println("not ok - " + label)
    report.failures = report.failures + 1
  }
}

func didOpen(peer: inout RpcPeer, uri: in String, text: in String): Unit {
  val doc = obj([field("uri", str(uri)), field("languageId", str("plaintext")), field("version", JInt(value = 1i64)), field("text", str(text))])
  val _ = notify(peer, "textDocument/didOpen", Some(value = obj([field("textDocument", doc)])))
}

func markDone(peer: inout RpcPeer, uri: in String): Option[Bool] {
  val params = obj([field("command", str("todo.markDone")), field("arguments", JArray(items = [str(uri)]))])
  match call(peer, "workspace/executeCommand", Some(value = params)) {
    case Ok(v) -> getBool(v, "applied")
    case Err(e) -> {
      println("# executeCommand failed: " + e.message)
      None
    }
  }
}

func answered(o: in Option[Bool], expected: in Bool): Bool {
  match o {
    case Some(b) -> b == expected
    case None -> false
  }
}

func hostConfig(workspace: in Workspace): PluginHostConfig {
  val providers: List[CapabilityProvider] = newList()
  providers.add(workspaceEditProvider(workspace))
  PluginHostConfig(
    points = [languageServerPointInfo()],
    providers = providers,
    policy = GrantAllRequested(),
    startTimeoutMs = 60000,
    callTimeoutMs = 60000
  )
}

func run(pluginsDir: in String): Int {
  val report = Report(failures = 0)
  val workspace = Workspace(documents = newMap())
  workspace.documents.set(workspaceDoc, "buy milk\nTODO: call bob\nfix TODO later\n")
  workspace.documents.set(outsideDoc, "TODO: not yours\n")
  val host = newPluginHost(hostConfig(workspace))
  for issue in discoverPlugins(host, [pluginsDir]) {
    println("# load issue: " + pluginLoadIssueMessage(issue))
  }
  val contributions = languageServerContributions(host)
  check(report, contributions.count == 1, "one language server is catalogued")
  if contributions.count != 1 {
    return 1
  }
  check(
    report,
    contributions[0].value.languageIds.contains("plaintext"),
    "its contributions are read without starting it"
  )
  val session = match openLanguageServerSession(host, contributions[0].pluginId) {
    case Ok(s) -> s
    case Err(b) -> {
      println("not ok - open the session: " + boundaryErrorMessage(b))
      return 1
    }
  }
  val proc = match protocolProcess(session) { case Ok(p) -> p; case Err(_) -> return 1 }
  val client = Client(host = host, pluginId = session.pluginId, diagnostics = newMap(), lastFailure = "")
  var peer = newPeerWithTimeout(newContentLengthTransportOverProcess(proc), client, 60000)

  val init = obj([field("processId", JNull), field("rootUri", str("file:///workspace/")), field("capabilities", obj([]))])
  match call(peer, "initialize", Some(value = init)) {
    case Ok(v) -> {
      val commands = match getField(v, "capabilities") {
        case Some(c) -> match getField(c, "executeCommandProvider") {
          case Some(e) -> unwrapOr(getArray(e, "commands"), newList())
          case None -> newList()
        }
        case None -> newList()
      }
      var found = false
      for c in commands {
        match c { case JString(s) -> if s == "todo.markDone" { found = true }; case _ -> () }
      }
      check(report, found, "initialize: the server offers todo.markDone")
    }
    case Err(e) -> check(report, false, "initialize: " + e.message)
  }
  val _ = notify(peer, "initialized", Some(value = obj([])))

  didOpen(peer, workspaceDoc, unwrapOr(workspace.documents.get(workspaceDoc), ""))
  check(report, answered(markDone(peer, workspaceDoc), true), "markDone in the workspace is applied")
  check(report, unwrapOr(client.diagnostics.get(workspaceDoc), 0) == 2, "didOpen published two TODO diagnostics")
  check(
    report,
    unwrapOr(workspace.documents.get(workspaceDoc), "") == "buy milk\nDONE: call bob\nfix DONE later\n",
    "the edit went through WorkspaceEdit"
  )

  didOpen(peer, outsideDoc, unwrapOr(workspace.documents.get(outsideDoc), ""))
  check(report, answered(markDone(peer, outsideDoc), false), "an edit outside the grant is refused")
  check(report, Str.contains(client.lastFailure, "denied"), "by the capability's requires: guard")
  check(report, unwrapOr(workspace.documents.get(outsideDoc), "") == "TODO: not yours\n", "the document is unchanged")

  revokeCapability(host, session.pluginId, "Editor.Lang.WorkspaceEdit")
  workspace.documents.set(workspaceDoc, "TODO again\n")
  didOpen(peer, workspaceDoc, "TODO again\n")
  check(report, answered(markDone(peer, workspaceDoc), false), "a revoked capability refuses the edit")
  check(report, Str.contains(client.lastFailure, "revoked"), "and says it was revoked")

  match call(peer, "shutdown", None) {
    case Ok(_) -> check(report, true, "shutdown")
    case Err(e) -> check(report, false, "shutdown: " + e.message)
  }
  val _ = notify(peer, "exit", None)
  closeProtocolSession(session)
  report.failures
}

func main(): Int {
  val args = getArgs()
  if args.count != 1 {
    println("usage: Editor.Host <plugins-directory>")
    return 2
  }
  run(args[0])
}
