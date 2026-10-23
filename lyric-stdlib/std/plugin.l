//! std/plugin.l - Std.Plugin: the plugin runtime (docs/69, D207).
//!
//! Both sides of the process-mode plugin protocol (D207 Decision 3):
//!
//! - **Host side.** A `PluginHost` holds a catalogue of plugins read from
//!   `plugin.json` manifests (`discoverPlugins`, `registerPlugin`). Loading a
//!   plugin validates its manifest (D207 Decision 5), matches its points
//!   against the points the host offers, asks the application's
//!   `GrantPolicy` which capabilities to grant, checks each grant against the
//!   request (Q-PLG-004: a list-valued grant field must be a subset of the
//!   requested list, any other field must equal the request; a wider grant is
//!   load issue `K0102`) and chooses the payload to run. Nothing starts until
//!   the first `callPlugin`: that spawns the payload, sends `plugin/hello`
//!   with the grants, and records the methods the plugin implements. While a
//!   point call waits for its answer, the host serves the plugin's
//!   capability calls (`cap/<Pkg>.<C>/<method>`) by handing them to the
//!   registered `CapabilityProvider` with the granted value, so a plugin may
//!   call back into the host from inside a point method. A crashed plugin is
//!   restarted on the next call after an exponential backoff, up to
//!   `maxRestarts` times; after that every call fails with `Crashed`.
//! - **Plugin side.** `runPlugin` answers `--lyric-plugin-manifest` with
//!   `PluginServer.describe()`, otherwise serves the protocol over its own
//!   stdin and stdout: `plugin/hello` attaches the server to the granted
//!   capabilities, other requests go to `PluginServer.dispatch`, and
//!   `callHost` makes a capability call from inside a dispatch.
//!
//! Everything here is synchronous: a host is an ordinary program that calls
//! `callPlugin` and gets the answer, and capability calls are served on the
//! calling thread while it waits. A `PluginHost` is not safe to use from
//! several threads at once.
//!
//! `BoundaryError` covers every failure the boundary itself causes, as
//! JSON-RPC error codes in the implementation-defined server range
//! (`boundaryErrorFromRpc`, `boundaryErrorToRpc`). A plugin's own errors
//! travel inside a successful result as `{"err": ...}`.
@io
package Std.Plugin

import Std.Core
import Std.Collections
import Std.Errors
import Std.Time
import Std.Process
import Std.JsonValue
import Std.JsonRpc
import Std.JsonRpc.Stdio
import Std.PluginHost
import Std.PanicGuardHost
import Std.String as Str
import Std.Path as Path
import Std.File as File
import Std.Environment as Env
import Std.Console as Console

// ── Constants ──────────────────────────────────────────────────────────────
/// The `schema` value of a `plugin.json` this runtime reads.
@experimental
pub val pluginManifestSchema: Int = 1

/// The `protocol` value of `plugin/hello` this runtime speaks.
@experimental
pub val pluginProtocolVersion: Int = 1

/// JSON-RPC error code of `BoundaryError.Denied`.
@experimental
pub val boundaryDeniedCode: Int = -32040

/// JSON-RPC error code of `BoundaryError.NotGranted`.
@experimental
pub val boundaryNotGrantedCode: Int = -32041

/// JSON-RPC error code of `BoundaryError.Stale`.
@experimental
pub val boundaryStaleCode: Int = -32042

/// JSON-RPC error code of `BoundaryError.Unsupported`.
@experimental
pub val boundaryUnsupportedCode: Int = -32043

/// JSON-RPC error code of `BoundaryError.Revoked`.
@experimental
pub val boundaryRevokedCode: Int = -32044

/// JSON-RPC error code of `BoundaryError.ContractViolated`.
@experimental
pub val boundaryContractViolatedCode: Int = -32045

/// JSON-RPC error code of `BoundaryError.Protocol`.
@experimental
pub val boundaryProtocolCode: Int = -32046

// The argument that makes a plugin executable print its manifest and exit
// (D207 Decision 3).
val manifestProbeArgument: String = "--lyric-plugin-manifest"

// Std.JsonRpc's error codes, restated here: the compiler imports this
// package, and the stage-0 seed that builds the compiler's stdlib bundle
// does not resolve another package's `pub val` (D204 item 5 postdates it).
val rpcParseError: Int = -32700

val rpcInvalidRequest: Int = -32600

val rpcMethodNotFound: Int = -32601

val rpcInvalidParams: Int = -32602

val rpcInternalError: Int = -32603

val rpcRequestTimedOut: Int = -32001

// ── Boundary errors ────────────────────────────────────────────────────────
/// A failure caused by the plugin boundary rather than by the plugin's or the
/// host's own code (D207 Decision 7).
@experimental
pub union BoundaryError {
  case Denied(reason: String)
  case NotGranted(capability: String)
  case Stale
  case Unsupported(method: String)
  case Revoked(capability: String)
  case ContractViolated(detail: String)
  case Timeout(timeoutMs: Int)
  case Crashed(detail: String)
  case Protocol(detail: String)
}

/// The error of a call across the boundary: the callee's own error `E`, or a
/// `BoundaryError`.
@experimental
pub union CallError[E] {
  case App(error: E)
  case Boundary(error: BoundaryError)
}

/// A one-line description of `b` for logs and diagnostics.
@experimental
pub func boundaryErrorMessage(b: in BoundaryError): String {
  match b {
    case Denied(r) -> "denied: " + r
    case NotGranted(c) -> "capability '" + c + "' is not granted"
    case Stale -> "stale handle"
    case Unsupported(m) -> "method '" + m + "' is not supported by the plugin"
    case Revoked(c) -> "capability '" + c + "' has been revoked"
    case ContractViolated(d) -> "contract violated: " + d
    case Timeout(ms) -> "timed out after " + ms.toString() + " ms"
    case Crashed(d) -> "plugin crashed: " + d
    case Protocol(d) -> "protocol error: " + d
  }
}

func plDataString(e: in RpcError, key: in String): Option[String] {
  match e.data {
    case None -> None
    case Some(d) -> getString(d, key)
  }
}

/// Map a JSON-RPC error received across the boundary to a `BoundaryError`
/// (D207 Decision 3). `method` names the call, for `Unsupported` when the
/// error does not say which method it was. The standard JSON-RPC codes keep
/// their meanings: `-32601` is `Unsupported`, `-32700`/`-32600`/`-32602` are
/// `Protocol`, and `-32603` (the callee failed inside its handler, a `Bug`)
/// is `ContractViolated`. Any other code is `Protocol`.
@experimental
pub func boundaryErrorFromRpc(e: in RpcError, method: in String): BoundaryError {
  val code = e.code
  if code == rpcRequestTimedOut {
    val ms = match e.data {
      case None -> 0
      case Some(d) -> match getInt(d, "timeoutMs") {
        case Some(n) -> if n >= 0i64 and n <= 2147483647i64 { n.toInt() } else { 0 }
        case None -> 0
      }
    }
    Timeout(timeoutMs = ms)
  } else if code == boundaryDeniedCode {
    Denied(reason = e.message)
  } else if code == boundaryNotGrantedCode {
    NotGranted(capability = unwrapOr(plDataString(e, "capability"), e.message))
  } else if code == boundaryStaleCode {
    Stale
  } else if code == boundaryUnsupportedCode or code == rpcMethodNotFound {
    Unsupported(method = unwrapOr(plDataString(e, "method"), method))
  } else if code == boundaryRevokedCode {
    Revoked(capability = unwrapOr(plDataString(e, "capability"), e.message))
  } else if code == boundaryContractViolatedCode {
    ContractViolated(detail = e.message)
  } else if code == rpcInternalError {
    ContractViolated(detail = "the callee failed while handling '" + method + "': " + e.message)
  } else if code == boundaryProtocolCode or code == rpcParseError or code == rpcInvalidRequest or code == rpcInvalidParams {
    Protocol(detail = e.message)
  } else {
    Protocol(detail = "unexpected error " + code.toString() + " from '" + method + "': " + e.message)
  }
}

func plDataObject(key: in String, v: in JsonValue): Option[JsonValue] {
  val fields: List[JsonField] = newList()
  fields.add(JsonField(name = key, value = v))
  Some(value = JObject(fields = fields))
}

/// The JSON-RPC error that carries `b` across the boundary; the inverse of
/// `boundaryErrorFromRpc`. `Crashed` has no wire code of its own and is sent
/// as `-32603`.
@experimental
pub func boundaryErrorToRpc(b: in BoundaryError): RpcError {
  match b {
    case Denied(r) -> RpcError(code = boundaryDeniedCode, message = r, data = None)
    case NotGranted(c) -> RpcError(
      code = boundaryNotGrantedCode,
      message = "capability '" + c + "' is not granted",
      data = plDataObject("capability", JString(value = c))
    )
    case Stale -> RpcError(code = boundaryStaleCode, message = "stale handle", data = None)
    case Unsupported(m) -> RpcError(
      code = boundaryUnsupportedCode,
      message = "method '" + m + "' is not supported",
      data = plDataObject("method", JString(value = m))
    )
    case Revoked(c) -> RpcError(
      code = boundaryRevokedCode,
      message = "capability '" + c + "' has been revoked",
      data = plDataObject("capability", JString(value = c))
    )
    case ContractViolated(d) -> RpcError(code = boundaryContractViolatedCode, message = d, data = None)
    case Timeout(ms) -> RpcError(
      code = rpcRequestTimedOut,
      message = "timed out after " + ms.toString() + " ms",
      data = plDataObject("timeoutMs", JInt(value = ms.toLong()))
    )
    case Crashed(d) -> RpcError(code = rpcInternalError, message = d, data = None)
    case Protocol(d) -> RpcError(code = boundaryProtocolCode, message = d, data = None)
  }
}

// ── Point, capability and grant descriptions ───────────────────────────────
/// A plugin point the host offers: its qualified id (`<Pkg>.<P>`), its
/// `major.minor` version, the capabilities its plugins may request, whether
/// it declares contributions, and, for a protocol point, the protocol.
@experimental
pub record PluginPointInfo {
  id: String
  version: String
  allows: List[String]
  hasContributions: Bool
  protocol: Option[String]
}

/// A capability the host provides: its qualified id and whether it is
/// parameterised by a grant.
@experimental
pub record CapabilityInfo {
  id: String
  hasGrant: Bool
}

/// The host's implementation of one capability. `serve` receives the method
/// name (without the `cap/<Pkg>.<C>/` prefix), the call's params, and the
/// grant the plugin holds (`None` for a capability without a grant). It
/// returns the call's result object (`{"ok": ...}` or `{"err": ...}`), or a
/// JSON-RPC error; a `BoundaryError` travels as `boundaryErrorToRpc(b)`.
@experimental
pub interface CapabilityProvider {
  func info(): CapabilityInfo

  func serve(method: in String, params: in Option[JsonValue], grant: in Option[JsonValue]): Result[JsonValue, RpcError]
}

/// One granted capability, with the grant value the plugin receives (`None`
/// for a capability without a grant).
@experimental
pub record GrantedCapability {
  capability: String
  grant: Option[JsonValue]
}

/// A grant policy's answer for one plugin. `allow = false` refuses the plugin
/// (`reason` says why); otherwise `grants` lists the capabilities granted.
@experimental
pub record GrantDecision {
  allow: Bool
  reason: String
  grants: List[GrantedCapability]
}

/// The application's decision on what a plugin may use. A grant may be
/// narrower than the request, never wider (`checkGrantWithinRequest`).
@experimental
pub interface GrantPolicy {
  func decide(manifest: in PluginManifest): GrantDecision
}

/// A policy that grants every requested capability, required and optional,
/// with exactly the requested value. For hosts whose plugin directories hold
/// only plugins their owner trusts, such as a compiler running its
/// configured generators.
@experimental
pub record GrantAllRequested {
}

impl GrantPolicy for GrantAllRequested {
  func decide(manifest: in PluginManifest): GrantDecision {
    grantAllRequested(manifest)
  }
}

/// The decision `GrantAllRequested` makes.
@experimental
pub func grantAllRequested(manifest: in PluginManifest): GrantDecision {
  val grants: List[GrantedCapability] = newList()
  var i = 0
  while i < manifest.required.count {
    grants.add(GrantedCapability(capability = manifest.required[i].name, grant = manifest.required[i].grant))
    i = i + 1
  }
  i = 0
  while i < manifest.optional.count {
    grants.add(GrantedCapability(capability = manifest.optional[i].name, grant = manifest.optional[i].grant))
    i = i + 1
  }
  GrantDecision(allow = true, reason = "", grants = grants)
}

// ── Manifest model ─────────────────────────────────────────────────────────
/// One point a plugin implements: the point's qualified id, the
/// `major.minor` version the plugin was built against, and its contributions
/// value (if the point declares contributions).
@experimental
pub record PluginPointDecl {
  point: String
  version: String
  contributions: Option[JsonValue]
}

/// One requested capability and the grant value the plugin asks for.
@experimental
pub record CapabilityRequest {
  name: String
  grant: Option[JsonValue]
}

/// A way to run the plugin (D207 Decision 5). Paths are relative to the
/// plugin directory.
///
/// - `ManagedPayload`: `runtime` is `"dotnet"` with `command` =
///   `["dotnet", "exec", "<dll>", ...]`, or `"jvm"` with `["java", "-jar",
///   "<jar>", ...]`.
/// - `NativePayload`: an executable for one `os` (`linux`, `macos`,
///   `windows`) and `arch` (`x86_64`, `aarch64`); `command[0]` is the
///   executable.
/// - `WasmPayload`: a WASI command module run under `wasmtime run`.
@experimental
pub union PluginPayload {
  case ManagedPayload(runtime: String, command: List[String])
  case NativePayload(os: String, arch: String, command: List[String])
  case WasmPayload(wasmModule: String)
}

/// A parsed `plugin.json` (schema 1). `required` and `optional` are the
/// manifest's `capabilities.required` and `capabilities.optional` lists.
@experimental
pub record PluginManifest {
  id: String
  version: String
  publisher: String
  points: List[PluginPointDecl]
  required: List[CapabilityRequest]
  optional: List[CapabilityRequest]
  payloads: List[PluginPayload]
}

/// Why a plugin was not loaded, or what is wrong with a loaded one. `K0101`,
/// `K0102` and `K0103` are the docs/69 §18 load codes (`pluginIssueCode`).
@experimental
pub union PluginIssueKind {
  // `plugin.json` could not be read, or is not JSON.
  case ManifestUnreadable
  // `plugin.json` is JSON but not a valid schema-1 manifest.
  case ManifestInvalid
  // Another plugin with the same id is already loaded.
  case DuplicatePlugin
  // The plugin implements none of the points the host offers.
  case NoMatchingPoint
  // K0103: the plugin was built against another major version of a point.
  case MajorVersionMismatch
  // The plugin requests a capability none of its points allows.
  case CapabilityNotAllowed
  // The grant policy refused the plugin.
  case PolicyRefused
  // The policy granted a capability that was not requested, or granted one
  // twice.
  case InvalidGrant
  // K0102: a grant is wider than the request.
  case GrantWider
  // The policy did not grant a required capability.
  case RequiredNotGranted
  // A granted capability has no `CapabilityProvider` in the host.
  case MissingProvider
  // No payload can run on this host.
  case NoUsablePayload
  // K0101: a plugin's contributions do not decode as the point's
  // contributions type (reported by the generated `<p>ContributionIssues`).
  case BadContributions
}

/// A plugin that was not loaded: what went wrong, where (the plugin
/// directory, or the manifest source), the plugin id when it is known, and a
/// human-readable message.
@experimental
pub record PluginLoadIssue {
  kind: PluginIssueKind
  location: String
  pluginId: String
  message: String
}

/// The docs/69 §18 diagnostic code of an issue kind, or `""` when it has
/// none.
@experimental
pub func pluginIssueCode(kind: in PluginIssueKind): String {
  match kind {
    case BadContributions -> "K0101"
    case GrantWider -> "K0102"
    case MajorVersionMismatch -> "K0103"
    case _ -> ""
  }
}

/// `issue` as one line: `<location>: [<code>] <message>`.
@experimental
pub func pluginLoadIssueMessage(issue: in PluginLoadIssue): String {
  val code = pluginIssueCode(issue.kind)
  val prefix = if issue.location.length > 0 { issue.location + ": " } else { "" }
  if code.length > 0 {
    prefix + code + " " + issue.message
  } else {
    prefix + issue.message
  }
}

func plIssue(kind: in PluginIssueKind, location: in String, pluginId: in String, message: in String): PluginLoadIssue {
  PluginLoadIssue(kind = kind, location = location, pluginId = pluginId, message = message)
}

// ── Lexical checks ─────────────────────────────────────────────────────────
func plIsDigit(c: in Char): Bool {
  c >= '0' and c <= '9'
}

func plIsLetter(c: in Char): Bool {
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
}

// A decimal component: digits only, no leading zero unless it is "0".
func plIsNumeral(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    if not plIsDigit(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  not (s.length > 1 and Str.charAtOrReplacement(s, 0) == '0')
}

func plSplit(s: in String, sep: in String): List[String] {
  val parts: List[String] = newList()
  var start = 0
  var searching = true
  while searching {
    match Str.indexOfFrom(s, sep, start) {
      case Some(i) -> {
        parts.add(Str.substring(s, start, i - start))
        start = i + sep.length
      }
      case None -> {
        parts.add(Str.substring(s, start))
        searching = false
      }
    }
  }
  parts
}

/// True when `v` is a point version: `major.minor`, two decimal numerals.
@pure
@experimental
pub func isPointVersion(v: in String): Bool {
  val parts = plSplit(v, ".")
  parts.count == 2 and plIsNumeral(parts[0]) and plIsNumeral(parts[1])
}

/// The major component of a `major.minor` version.
func plMajor(v: in String): String {
  match Str.indexOf(v, ".") {
    case Some(i) -> Str.substring(v, 0, i)
    case None -> v
  }
}

/// True when `v` is a plugin version: `major.minor.patch`, optionally
/// followed by `-<pre-release>` and/or `+<build>` made of letters, digits,
/// `.` and `-`.
@pure
@experimental
pub func isPluginVersion(v: in String): Bool {
  var core = v
  var suffix = ""
  var i = 0
  var cut = -1
  while i < v.length and cut < 0 {
    val c = Str.charAtOrReplacement(v, i)
    if c == '-' or c == '+' {
      cut = i
    }
    i = i + 1
  }
  if cut >= 0 {
    core = Str.substring(v, 0, cut)
    suffix = Str.substring(v, cut + 1)
    if suffix.length == 0 {
      return false
    }
    var j = 0
    while j < suffix.length {
      val c = Str.charAtOrReplacement(suffix, j)
      if not (plIsLetter(c) or plIsDigit(c) or c == '.' or c == '-' or c == '+') {
        return false
      }
      j = j + 1
    }
  }
  val parts = plSplit(core, ".")
  parts.count == 3 and plIsNumeral(parts[0]) and plIsNumeral(parts[1]) and plIsNumeral(parts[2])
}

/// True when `id` is a valid plugin id: dot-separated non-empty segments of
/// letters, digits, `-` and `_` (reverse-DNS style, such as
/// `acme.git-tools`).
@pure
@experimental
pub func isPluginId(id: in String): Bool {
  if id.length == 0 {
    return false
  }
  val segs = plSplit(id, ".")
  var i = 0
  while i < segs.count {
    val s = segs[i]
    if s.length == 0 {
      return false
    }
    var j = 0
    while j < s.length {
      val c = Str.charAtOrReplacement(s, j)
      if not (plIsLetter(c) or plIsDigit(c) or c == '-' or c == '_') {
        return false
      }
      j = j + 1
    }
    i = i + 1
  }
  true
}

/// True when `name` is a qualified point or capability id `<Pkg>.<Name>`:
/// two or more dot-separated identifiers.
@pure
@experimental
pub func isQualifiedName(name: in String): Bool {
  val segs = plSplit(name, ".")
  if segs.count < 2 {
    return false
  }
  var i = 0
  while i < segs.count {
    val s = segs[i]
    if s.length == 0 {
      return false
    }
    val first = Str.charAtOrReplacement(s, 0)
    if not (plIsLetter(first) or first == '_') {
      return false
    }
    var j = 1
    while j < s.length {
      val c = Str.charAtOrReplacement(s, j)
      if not (plIsLetter(c) or plIsDigit(c) or c == '_') {
        return false
      }
      j = j + 1
    }
    i = i + 1
  }
  true
}

// A payload path must stay inside the plugin directory: relative, no `.` or
// `..` segment, no empty segment, no NUL, no drive letter.
func plCheckRelativePath(p: in String, what: in String): Result[Unit, String] {
  if p.length == 0 {
    return Err(error = what + " is empty")
  }
  if Str.startsWith(p, "/") or Str.startsWith(p, "\\") or Str.contains(p, ":") or Str.contains(p, "\u{0000}") {
    return Err(error = what + " '" + p + "' must be a relative path inside the plugin directory")
  }
  val segs = plSplit(Str.replace(p, "\\", "/"), "/")
  var i = 0
  while i < segs.count {
    val s = segs[i]
    if s.length == 0 or s == "." or s == ".." {
      return Err(
        error = what + " '" + p +
          "' must be a relative path inside the plugin directory, with no '.', '..' or empty segment"
      )
    }
    i = i + 1
  }
  Ok(value = ())
}

// ── JSON helpers ───────────────────────────────────────────────────────────
func plField(name: in String, v: in JsonValue): JsonField {
  JsonField(name = name, value = v)
}

func plOptJson(v: in Option[JsonValue]): JsonValue {
  match v {
    case Some(x) -> x
    case None -> JNull
  }
}

// `null` and an absent member both mean "no value".
func plNonNull(v: in Option[JsonValue]): Option[JsonValue] {
  match v {
    case None -> None
    case Some(x) -> match x { case JNull -> None; case _ -> Some(value = x) }
  }
}

func plFindField(fields: in List[JsonField], name: in String): Option[JsonValue] {
  var i = 0
  while i < fields.count {
    if fields[i].name == name {
      return Some(value = fields[i].value)
    }
    i = i + 1
  }
  None
}

/// Structural equality of two JSON values. Objects compare as sets of
/// members (order does not matter); numbers compare within their kind
/// (`JInt` with `JInt`, `JFloat` with `JFloat`).
@experimental
pub func jsonValuesEqual(a: in JsonValue, b: in JsonValue): Bool {
  match a {
    case JNull -> match b { case JNull -> true; case _ -> false }
    case JBool(x) -> match b { case JBool(y) -> x == y; case _ -> false }
    case JInt(x) -> match b { case JInt(y) -> x == y; case _ -> false }
    case JFloat(x) -> match b { case JFloat(y) -> x == y; case _ -> false }
    case JString(x) -> match b { case JString(y) -> x == y; case _ -> false }
    case JArray(xs) -> match b {
      case JArray(ys) -> {
        if xs.count != ys.count {
          return false
        }
        var i = 0
        while i < xs.count {
          if not jsonValuesEqual(xs[i], ys[i]) {
            return false
          }
          i = i + 1
        }
        true
      }
      case _ -> false
    }
    case JObject(xs) -> match b {
      case JObject(ys) -> {
        if xs.count != ys.count {
          return false
        }
        var i = 0
        while i < xs.count {
          match plFindField(ys, xs[i].name) {
            case None -> return false
            case Some(yv) -> if not jsonValuesEqual(xs[i].value, yv) { return false }
          }
          i = i + 1
        }
        true
      }
      case _ -> false
    }
  }
}

func plContainsJson(xs: in List[JsonValue], v: in JsonValue): Bool {
  var i = 0
  while i < xs.count {
    if jsonValuesEqual(xs[i], v) {
      return true
    }
    i = i + 1
  }
  false
}

func plContainsString(xs: in List[String], s: in String): Bool {
  var i = 0
  while i < xs.count {
    if xs[i] == s {
      return true
    }
    i = i + 1
  }
  false
}

// ── Grant check (Q-PLG-004) ────────────────────────────────────────────────
/// Check that `granted` is no wider than `requested` (D207, Q-PLG-004).
///
/// Both are a capability's grant values (`None` or `null` for a capability
/// without a grant). When both are objects, they must have the same members;
/// a member whose granted value is an array must be a subset of the
/// requested array (every granted element is equal to a requested one), and
/// any other member must equal the request. Values that are not objects
/// must be equal. `Err` says what is wider.
@experimental
pub func checkGrantWithinRequest(requested: in Option[JsonValue], granted: in Option[JsonValue]): Result[Unit, String] {
  val req = plNonNull(requested)
  val gr = plNonNull(granted)
  match req {
    case None -> match gr {
      case None -> Ok(value = ())
      case Some(_) -> Err(error = "the capability requests no grant value, but the grant has one")
    }
    case Some(rv) -> match gr {
      case None -> Err(error = "the grant value is missing")
      case Some(gv) -> plCheckGrantValue(rv, gv)
    }
  }
}

func plCheckGrantValue(rv: in JsonValue, gv: in JsonValue): Result[Unit, String] {
  match rv {
    case JObject(rfields) -> match gv {
      case JObject(gfields) -> {
        var i = 0
        while i < gfields.count {
          val name = gfields[i].name
          match plFindField(rfields, name) {
            case None -> return Err(error = "field '" + name + "' is not in the request")
            case Some(rmember) -> match plCheckGrantMember(name, rmember, gfields[i].value) {
              case Err(e) -> return Err(error = e)
              case Ok(_) -> ()
            }
          }
          i = i + 1
        }
        var k = 0
        while k < rfields.count {
          match plFindField(gfields, rfields[k].name) {
            case None -> return Err(error = "field '" + rfields[k].name + "' of the request is missing from the grant")
            case Some(_) -> ()
          }
          k = k + 1
        }
        Ok(value = ())
      }
      case _ -> Err(error = "the grant is not an object, but the request is")
    }
    case _ -> if jsonValuesEqual(rv, gv) {
      Ok(value = ())
    } else {
      Err(error = "the grant " + writeValue(gv) + " differs from the request " + writeValue(rv))
    }
  }
}

func plCheckGrantMember(name: in String, rmember: in JsonValue, gmember: in JsonValue): Result[Unit, String] {
  match gmember {
    case JArray(gitems) -> match rmember {
      case JArray(ritems) -> {
        var i = 0
        while i < gitems.count {
          if not plContainsJson(ritems, gitems[i]) {
            return Err(error = "field '" + name + "' grants " + writeValue(gitems[i]) + ", which was not requested")
          }
          i = i + 1
        }
        Ok(value = ())
      }
      case _ -> Err(error = "field '" + name + "' is a list in the grant but not in the request")
    }
    case _ -> if jsonValuesEqual(rmember, gmember) {
      Ok(value = ())
    } else {
      Err(error = "field '" + name + "' grants " + writeValue(gmember) + " but the request is " + writeValue(rmember))
    }
  }
}

// ── Manifest parsing ───────────────────────────────────────────────────────
func plMemberString(obj: in JsonValue, key: in String, ctx: in String): Result[String, String] {
  match getField(obj, key) {
    case None -> Err(error = ctx + ": missing \"" + key + "\"")
    case Some(v) -> match v {
      case JString(s) -> Ok(value = s)
      case _ -> Err(error = ctx + ": \"" + key + "\" must be a string")
    }
  }
}

func plMemberStringList(obj: in JsonValue, key: in String, ctx: in String): Result[List[String], String] {
  match getField(obj, key) {
    case None -> Err(error = ctx + ": missing \"" + key + "\"")
    case Some(v) -> match v {
      case JArray(items) -> {
        val acc: List[String] = newList()
        var i = 0
        while i < items.count {
          match items[i] {
            case JString(s) -> acc.add(s)
            case _ -> return Err(error = ctx + ": \"" + key + "\" must be an array of strings")
          }
          i = i + 1
        }
        Ok(value = acc)
      }
      case _ -> Err(error = ctx + ": \"" + key + "\" must be an array of strings")
    }
  }
}

// An optional array member: absent or null is an empty list.
func plMemberArray(obj: in JsonValue, key: in String, ctx: in String): Result[List[JsonValue], String] {
  match plNonNull(getField(obj, key)) {
    case None -> Ok(value = newList())
    case Some(v) -> match v {
      case JArray(items) -> Ok(value = items)
      case _ -> Err(error = ctx + ": \"" + key + "\" must be an array")
    }
  }
}

func plParsePoint(v: in JsonValue, index: in Int): Result[PluginPointDecl, String] {
  val ctx = "points[" + index.toString() + "]"
  match v {
    case JObject(_) -> ()
    case _ -> return Err(error = ctx + " must be an object")
  }
  val point = match plMemberString(v, "point", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if not isQualifiedName(point) {
    return Err(error = ctx + ": point '" + point + "' is not a qualified name <Pkg>.<Point>")
  }
  val version = match plMemberString(v, "version", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if not isPointVersion(version) {
    return Err(error = ctx + ": version '" + version + "' of point '" + point + "' is not major.minor")
  }
  Ok(value = PluginPointDecl(point = point, version = version, contributions = plNonNull(getField(v, "contributions"))))
}

func plParseCapabilities(
  caps: in List[JsonValue], listName: in String, into: in List[CapabilityRequest]
): Result[Unit, String] {
  var i = 0
  while i < caps.count {
    val ctx = "capabilities." + listName + "[" + i.toString() + "]"
    val v = caps[i]
    match v {
      case JObject(_) -> ()
      case _ -> return Err(error = ctx + " must be an object")
    }
    val name = match plMemberString(v, "name", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    if not isQualifiedName(name) {
      return Err(error = ctx + ": capability '" + name + "' is not a qualified name <Pkg>.<Capability>")
    }
    into.add(CapabilityRequest(name = name, grant = plNonNull(getField(v, "grant"))))
    i = i + 1
  }
  Ok(value = ())
}

func plParsePayload(v: in JsonValue, index: in Int): Result[PluginPayload, String] {
  val ctx = "payloads[" + index.toString() + "]"
  match v {
    case JObject(_) -> ()
    case _ -> return Err(error = ctx + " must be an object")
  }
  val mode = match plMemberString(v, "mode", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if mode == "wasm" {
    val file = match plMemberString(v, "module", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    match plCheckRelativePath(file, ctx + ": module") {
      case Err(e) -> return Err(error = e)
      case Ok(_) -> ()
    }
    if not Str.endsWith(file, ".wasm") {
      return Err(error = ctx + ": module '" + file + "' must be a .wasm file")
    }
    return Ok(value = WasmPayload(wasmModule = file))
  }
  if mode != "process" {
    return Err(error = ctx + ": mode '" + mode + "' is not \"process\" or \"wasm\"")
  }
  val command = match plMemberStringList(v, "command", ctx) { case Ok(c) -> c; case Err(e) -> return Err(error = e) }
  if command.count == 0 {
    return Err(error = ctx + ": command must not be empty")
  }
  match plNonNull(getField(v, "runtime")) {
    case Some(rt) -> {
      val runtime = match rt { case JString(s) -> s; case _ -> return Err(error = ctx + ": \"runtime\" must be a string") }
      if runtime == "dotnet" {
        if command.count < 3 or command[0] != "dotnet" or command[1] != "exec" {
          return Err(error = ctx + ": a dotnet payload's command is [\"dotnet\", \"exec\", \"<dll>\", ...]")
        }
      } else if runtime == "jvm" {
        if command.count < 3 or command[0] != "java" or command[1] != "-jar" {
          return Err(error = ctx + ": a jvm payload's command is [\"java\", \"-jar\", \"<jar>\", ...]")
        }
      } else {
        return Err(error = ctx + ": runtime '" + runtime + "' is not \"dotnet\" or \"jvm\"")
      }
      match plCheckRelativePath(command[2], ctx + ": the " + runtime + " artifact") {
        case Err(e) -> return Err(error = e)
        case Ok(_) -> ()
      }
      Ok(value = ManagedPayload(runtime = runtime, command = command))
    }
    case None -> {
      val os = match plMemberString(v, "os", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
      if not (os == "linux" or os == "macos" or os == "windows") {
        return Err(error = ctx + ": os '" + os + "' is not linux, macos or windows")
      }
      val arch = match plMemberString(v, "arch", ctx) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
      if not (arch == "x86_64" or arch == "aarch64") {
        return Err(error = ctx + ": arch '" + arch + "' is not x86_64 or aarch64")
      }
      match plCheckRelativePath(command[0], ctx + ": the executable") {
        case Err(e) -> return Err(error = e)
        case Ok(_) -> ()
      }
      Ok(value = NativePayload(os = os, arch = arch, command = command))
    }
  }
}

func plParseManifestValue(root: in JsonValue): Result[PluginManifest, String] {
  match root {
    case JObject(_) -> ()
    case _ -> return Err(error = "the manifest must be a JSON object")
  }
  match getField(root, "schema") {
    case None -> return Err(error = "missing \"schema\"")
    case Some(s) -> match s {
      case JInt(n) -> if n != pluginManifestSchema.toLong() {
        return Err(error = "schema " + n.toString() + " is not supported (this runtime reads schema 1)")
      }
      case _ -> return Err(error = "\"schema\" must be an integer")
    }
  }
  val id = match plMemberString(root, "id", "manifest") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if not isPluginId(id) {
    return Err(error = "id '" + id + "' is not a plugin id (dot-separated letters, digits, '-' and '_')")
  }
  val version = match plMemberString(root, "version", "manifest") {
    case Ok(s) -> s
    case Err(e) -> return Err(error = e)
  }
  if not isPluginVersion(version) {
    return Err(error = "version '" + version + "' is not major.minor.patch")
  }
  val publisher = match plMemberString(root, "publisher", "manifest") {
    case Ok(s) -> s
    case Err(e) -> return Err(error = e)
  }
  if publisher.length == 0 {
    return Err(error = "publisher must not be empty")
  }
  val rawPoints = match getField(root, "points") {
    case None -> return Err(error = "missing \"points\"")
    case Some(p) -> match p {
      case JArray(items) -> items
      case _ -> return Err(error = "\"points\" must be an array")
    }
  }
  if rawPoints.count == 0 {
    return Err(error = "\"points\" must list at least one point")
  }
  val points: List[PluginPointDecl] = newList()
  var i = 0
  while i < rawPoints.count {
    match plParsePoint(rawPoints[i], i) {
      case Err(e) -> return Err(error = e)
      case Ok(p) -> {
        var j = 0
        while j < points.count {
          if points[j].point == p.point {
            return Err(error = "point '" + p.point + "' is listed twice")
          }
          j = j + 1
        }
        points.add(p)
      }
    }
    i = i + 1
  }
  val required: List[CapabilityRequest] = newList()
  val optional: List[CapabilityRequest] = newList()
  match plNonNull(getField(root, "capabilities")) {
    case None -> ()
    case Some(caps) -> {
      match caps {
        case JObject(_) -> ()
        case _ -> return Err(error = "\"capabilities\" must be an object")
      }
      match plMemberArray(caps, "required", "capabilities") {
        case Err(e) -> return Err(error = e)
        case Ok(items) -> match plParseCapabilities(items, "required", required) {
          case Err(e) -> return Err(error = e)
          case Ok(_) -> ()
        }
      }
      match plMemberArray(caps, "optional", "capabilities") {
        case Err(e) -> return Err(error = e)
        case Ok(items) -> match plParseCapabilities(items, "optional", optional) {
          case Err(e) -> return Err(error = e)
          case Ok(_) -> ()
        }
      }
    }
  }
  val allCaps: List[String] = newList()
  var r = 0
  while r < required.count {
    if plContainsString(allCaps, required[r].name) {
      return Err(error = "capability '" + required[r].name + "' is requested twice")
    }
    allCaps.add(required[r].name)
    r = r + 1
  }
  var o = 0
  while o < optional.count {
    if plContainsString(allCaps, optional[o].name) {
      return Err(error = "capability '" + optional[o].name + "' is requested twice")
    }
    allCaps.add(optional[o].name)
    o = o + 1
  }
  val payloads: List[PluginPayload] = newList()
  match plMemberArray(root, "payloads", "manifest") {
    case Err(e) -> return Err(error = e)
    case Ok(items) -> {
      var k = 0
      while k < items.count {
        match plParsePayload(items[k], k) {
          case Err(e) -> return Err(error = e)
          case Ok(p) -> payloads.add(p)
        }
        k = k + 1
      }
    }
  }
  Ok(
    value = PluginManifest(
      id = id,
      version = version,
      publisher = publisher,
      points = points,
      required = required,
      optional = optional,
      payloads = payloads
    )
  )
}

/// Parse and validate a schema-1 manifest held as a JSON value. `location`
/// names its source in the issue on failure.
///
/// Validation is strict about what the runtime relies on: `schema` is 1;
/// `id` is a plugin id (`isPluginId`), `version` a plugin version
/// (`isPluginVersion`), `publisher` non-empty; `points` lists at least one
/// point, each a qualified name with a `major.minor` version, none twice;
/// capability names are qualified and none is requested twice; each payload
/// is one of the four shapes of D207 Decision 5 with paths that stay inside
/// the plugin directory. `capabilities` and `payloads` may be absent (the
/// output of `--lyric-plugin-manifest` has no payloads), and unknown members
/// are ignored so a later minor schema can add optional ones.
@experimental
pub func parsePluginManifestValue(v: in JsonValue, location: in String): Result[PluginManifest, PluginLoadIssue] {
  match plParseManifestValue(v) {
    case Ok(m) -> Ok(value = m)
    case Err(e) -> {
      val id = unwrapOr(getString(v, "id"), "")
      Err(error = plIssue(ManifestInvalid, location, id, e))
    }
  }
}

/// Parse and validate a manifest from JSON text, such as a `plugin.json`
/// file or the output of a plugin run with `--lyric-plugin-manifest`.
@experimental
pub func parsePluginManifest(text: in String): Result[PluginManifest, PluginLoadIssue] {
  match parseValue(text) {
    case Err(e) -> Err(error = plIssue(ManifestUnreadable, "", "", "the manifest is not JSON: " + e.message()))
    case Ok(v) -> parsePluginManifestValue(v, "")
  }
}

/// Read and validate `<dir>/plugin.json`.
@experimental
pub func readPluginManifest(dir: in String): Result[PluginManifest, PluginLoadIssue] {
  val path = Path.join(dir, "plugin.json")
  match File.readText(path) {
    case Err(e) -> Err(error = plIssue(ManifestUnreadable, dir, "", "cannot read plugin.json: " + IOError.message(e)))
    case Ok(text) -> match parseValue(text) {
      case Err(e) -> Err(
        error = plIssue(
          ManifestUnreadable,
          dir,
          "",
          "plugin.json is not JSON: " + e.message()
        )
      )
      case Ok(v) -> parsePluginManifestValue(v, dir)
    }
  }
}

func plPayloadToJson(p: in PluginPayload): JsonValue {
  val fields: List[JsonField] = newList()
  match p {
    case ManagedPayload(runtime, command) -> {
      fields.add(plField("mode", JString(value = "process")))
      fields.add(plField("runtime", JString(value = runtime)))
      fields.add(plField("command", plStringArray(command)))
    }
    case NativePayload(os, arch, command) -> {
      fields.add(plField("mode", JString(value = "process")))
      fields.add(plField("os", JString(value = os)))
      fields.add(plField("arch", JString(value = arch)))
      fields.add(plField("command", plStringArray(command)))
    }
    case WasmPayload(file) -> {
      fields.add(plField("mode", JString(value = "wasm")))
      fields.add(plField("module", JString(value = file)))
    }
  }
  JObject(fields = fields)
}

func plStringArray(xs: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  var i = 0
  while i < xs.count {
    items.add(JString(value = xs[i]))
    i = i + 1
  }
  JArray(items = items)
}

func plCapabilityList(caps: in List[CapabilityRequest]): JsonValue {
  val items: List[JsonValue] = newList()
  var i = 0
  while i < caps.count {
    val fields: List[JsonField] = newList()
    fields.add(plField("name", JString(value = caps[i].name)))
    match caps[i].grant {
      case Some(g) -> fields.add(plField("grant", g))
      case None -> ()
    }
    items.add(JObject(fields = fields))
    i = i + 1
  }
  JArray(items = items)
}

/// The `plugin.json` document for `m` (schema 1), the inverse of
/// `parsePluginManifestValue`.
@experimental
pub func pluginManifestToJson(m: in PluginManifest): JsonValue {
  val fields: List[JsonField] = newList()
  fields.add(plField("schema", JInt(value = pluginManifestSchema.toLong())))
  fields.add(plField("id", JString(value = m.id)))
  fields.add(plField("version", JString(value = m.version)))
  fields.add(plField("publisher", JString(value = m.publisher)))
  val points: List[JsonValue] = newList()
  var i = 0
  while i < m.points.count {
    val pf: List[JsonField] = newList()
    pf.add(plField("point", JString(value = m.points[i].point)))
    pf.add(plField("version", JString(value = m.points[i].version)))
    match m.points[i].contributions {
      case Some(c) -> pf.add(plField("contributions", c))
      case None -> ()
    }
    points.add(JObject(fields = pf))
    i = i + 1
  }
  fields.add(plField("points", JArray(items = points)))
  val caps: List[JsonField] = newList()
  caps.add(plField("required", plCapabilityList(m.required)))
  caps.add(plField("optional", plCapabilityList(m.optional)))
  fields.add(plField("capabilities", JObject(fields = caps)))
  val payloads: List[JsonValue] = newList()
  var k = 0
  while k < m.payloads.count {
    payloads.add(plPayloadToJson(m.payloads[k]))
    k = k + 1
  }
  fields.add(plField("payloads", JArray(items = payloads)))
  JObject(fields = fields)
}

/// `m` with `payload` appended to its payloads, for a host or packer that
/// adds the payload it built to a probed manifest.
@experimental
pub func addPluginPayload(m: in PluginManifest, payload: in PluginPayload): PluginManifest {
  val payloads: List[PluginPayload] = newList()
  var i = 0
  while i < m.payloads.count {
    payloads.add(m.payloads[i])
    i = i + 1
  }
  payloads.add(payload)
  PluginManifest(
    id = m.id,
    version = m.version,
    publisher = m.publisher,
    points = m.points,
    required = m.required,
    optional = m.optional,
    payloads = payloads
  )
}

// ── Payload selection ──────────────────────────────────────────────────────
/// Where the host runs: `os` and `arch` in the manifest vocabulary, and the
/// host's own runtime (`"dotnet"`, `"jvm"` or `"native"`).
@experimental
pub record PluginPlatform {
  os: String
  arch: String
  runtime: String
}

/// The platform this program runs on.
@experimental
pub func currentPluginPlatform(): PluginPlatform {
  PluginPlatform(os = hostPluginOs(), arch = hostPluginArch(), runtime = hostPluginRuntime())
}

func plFindWasm(payloads: in List[PluginPayload]): Option[PluginPayload] {
  var i = 0
  while i < payloads.count {
    match payloads[i] {
      case WasmPayload(_) -> return Some(value = payloads[i])
      case _ -> ()
    }
    i = i + 1
  }
  None
}

func plFindManaged(payloads: in List[PluginPayload], runtime: in String): Option[PluginPayload] {
  var i = 0
  while i < payloads.count {
    match payloads[i] {
      case ManagedPayload(r, _) -> if r == runtime { return Some(value = payloads[i]) }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

/// Choose the payload to run (D207 Decisions 5 and 6), or `None` when none
/// can run here. In order: a wasm payload when `preferWasm` and
/// `wasmtimeAvailable`; the native executable for `platform`'s os and arch;
/// the managed payload of the host's own runtime, then the other managed
/// runtime (dotnet before jvm); and last a wasm payload when `wasmtime` is
/// available even though it was not preferred.
@experimental
pub func selectPluginPayload(
  payloads: in List[PluginPayload],
  platform: in PluginPlatform,
  preferWasm: in Bool,
  wasmtimeAvailable: in Bool,
): Option[PluginPayload] {
  val wasm = plFindWasm(payloads)
  if preferWasm and wasmtimeAvailable and isSome(wasm) {
    return wasm
  }
  var i = 0
  while i < payloads.count {
    match payloads[i] {
      case NativePayload(os, arch, _) -> if os == platform.os and arch == platform.arch {
        return Some(value = payloads[i])
      }
      case _ -> ()
    }
    i = i + 1
  }
  val own = plFindManaged(payloads, platform.runtime)
  if isSome(own) {
    return own
  }
  val dotnet = plFindManaged(payloads, "dotnet")
  if isSome(dotnet) {
    return dotnet
  }
  val jvm = plFindManaged(payloads, "jvm")
  if isSome(jvm) {
    return jvm
  }
  if wasmtimeAvailable {
    return wasm
  }
  None
}

/// The `wasmtime` executable: `$LYRIC_WASMTIME` when it is set (and names an
/// existing file), otherwise the first `wasmtime` on `PATH`.
@experimental
pub func findWasmtime(): Option[String] {
  val explicit = Env.getVarOrDefault("LYRIC_WASMTIME", "")
  if explicit.length > 0 {
    if File.fileExists(explicit) {
      return Some(value = explicit)
    }
    return None
  }
  val windows = Env.isWindows()
  val sep = if windows { ";" } else { ":" }
  val exe = if windows { "wasmtime.exe" } else { "wasmtime" }
  val dirs = plSplit(Env.getVarOrDefault("PATH", ""), sep)
  var i = 0
  while i < dirs.count {
    if dirs[i].length > 0 {
      val candidate = Path.join(dirs[i], exe)
      if File.fileExists(candidate) {
        return Some(value = candidate)
      }
    }
    i = i + 1
  }
  None
}

func plWithin(dir: in String, relative: in String): Result[String, String] {
  match Path.joinWithin(dir, Str.replace(relative, "\\", "/")) {
    case Ok(p) -> Ok(value = p)
    case Err(e) -> Err(error = IOError.message(e))
  }
}

/// The command line that runs `payload` from plugin directory `dir`: the
/// payload's artifact path resolved inside `dir`, `java` taken from
/// `$JAVA_HOME/bin` when that is set, and a wasm module run as
/// `wasmtime run -W max-memory-size=<bytes> <module>` with no directories,
/// environment or network (D207 Decision 6).
@experimental
pub func pluginLaunchCommand(
  payload: in PluginPayload,
  dir: in String,
  wasmtime: in Option[String],
  wasmMaxMemoryBytes: in Long,
): Result[List[String], String] {
  val argv: List[String] = newList()
  match payload {
    case ManagedPayload(runtime, command) -> {
      // readPluginManifest enforces this too, but a manifest built in memory
      // and passed to registerPlugin does not go through it.
      if command.count < 3 {
        return Err(error = "a managed payload's command needs a launcher, a flag and the payload file")
      }
      if runtime == "jvm" {
        val javaHome = Env.getVarOrDefault("JAVA_HOME", "")
        val javaExe = if Env.isWindows() { "java.exe" } else { "java" }
        val fromHome = Path.join(Path.join(javaHome, "bin"), javaExe)
        if javaHome.length > 0 and File.fileExists(fromHome) {
          argv.add(fromHome)
        } else {
          argv.add(command[0])
        }
      } else {
        argv.add(command[0])
      }
      argv.add(command[1])
      match plWithin(dir, command[2]) {
        case Ok(p) -> argv.add(p)
        case Err(e) -> return Err(error = e)
      }
      var i = 3
      while i < command.count {
        argv.add(command[i])
        i = i + 1
      }
    }
    case NativePayload(_, _, command) -> {
      if command.count == 0 {
        return Err(error = "a native payload's command must not be empty")
      }
      match plWithin(dir, command[0]) {
        case Ok(p) -> argv.add(p)
        case Err(e) -> return Err(error = e)
      }
      var i = 1
      while i < command.count {
        argv.add(command[i])
        i = i + 1
      }
    }
    case WasmPayload(file) -> {
      val exe = match wasmtime {
        case Some(w) -> w
        case None -> return Err(error = "a wasm payload needs wasmtime on PATH or at $LYRIC_WASMTIME")
      }
      argv.add(exe)
      argv.add("run")
      argv.add("-W")
      argv.add("max-memory-size=" + wasmMaxMemoryBytes.toString())
      match plWithin(dir, file) {
        case Ok(p) -> argv.add(p)
        case Err(e) -> return Err(error = e)
      }
    }
  }
  Ok(value = argv)
}

// ── Host ───────────────────────────────────────────────────────────────────
/// The host's configuration (D207 Decision 7). Timeouts are milliseconds.
/// `restartBackoffMs` is the wait before the first restart of a crashed
/// plugin, doubled for each later one up to `maxRestartBackoffMs`;
/// `shutdownGraceMs` is how long `stopPlugin` waits for a plugin to exit
/// before killing it; `wasmMaxMemoryBytes` bounds a wasm plugin's memory.
@experimental
pub record PluginHostConfig {
  points: List[PluginPointInfo]
  providers: List[CapabilityProvider]
  policy: GrantPolicy
  callTimeoutMs: Int = 60000
  startTimeoutMs: Int = 10000
  maxRestarts: Int = 3
  preferWasm: Bool = true
  restartBackoffMs: Int = 250
  maxRestartBackoffMs: Int = 10000
  shutdownGraceMs: Int = 2000
  wasmMaxMemoryBytes: Long = 268435456i64
}

/// Capabilities revoked from one plugin; shared by its process state and the
/// server that answers its capability calls.
@experimental
pub record PluginRevocations {
  var revoked: List[String]
}

/// The host-side state of one catalogued plugin: what was decided at load
/// time (offered points, grants, the command line) and the running process,
/// if any. Reached through `PluginConnection`; applications do not build it.
@experimental
pub record PluginProcessState {
  manifest: PluginManifest
  dir: String
  points: List[PluginPointInfo]
  grants: List[GrantedCapability]
  revocations: PluginRevocations
  config: PluginHostConfig
  launch: List[String]
  var peer: Option[RpcPeer]
  var process: Option[PipedProcess]
  var methods: List[PluginPointMethods]
  var crashes: Int
  var lastCrashNanos: Long
  var fatal: Option[BoundaryError]
}

/// A connection to one plugin. On the host side (`connectionsFor`) it is the
/// catalogued plugin, started on the first `callPlugin`; on the plugin side
/// (`PluginServer.attach`) it is the link to the host for `callHost`. Every
/// copy refers to the same connection.
@experimental
pub record PluginConnection {
  pluginId: String
  var peer: Option[RpcPeer]
  host: Option[PluginProcessState]
}

/// A plugin's contributions to one point, as JSON, for the generated
/// `<p>Contributions` to decode.
@experimental
pub record PluginContributionJson {
  pluginId: String
  value: JsonValue
}

/// A plugin host: its configuration and its catalogue of loaded plugins.
@experimental
pub record PluginHost {
  config: PluginHostConfig
  var plugins: List[PluginConnection]
}

/// Create a host with an empty catalogue.
@experimental
pub func newPluginHost(config: in PluginHostConfig): PluginHost
  requires: isValidCallTimeout(config.callTimeoutMs) and isValidCallTimeout(config.startTimeoutMs) and
    config.maxRestarts >= 0 and
    config.restartBackoffMs >= 0 and
    config.maxRestartBackoffMs >= config.restartBackoffMs and
    config.shutdownGraceMs >= 0 and
    config.wasmMaxMemoryBytes > 0i64
{
  PluginHost(config = config, plugins = newList())
}

func plSortStrings(xs: in List[String]): List[String] {
  val acc: List[String] = newList()
  val taken: List[Bool] = newList()
  var t = 0
  while t < xs.count {
    taken.add(false)
    t = t + 1
  }
  var n = 0
  while n < xs.count {
    var best = -1
    var i = 0
    while i < xs.count {
      if not taken[i] and (best < 0 or Str.compare(xs[i], xs[best]) < 0) {
        best = i
      }
      i = i + 1
    }
    taken[best] = true
    acc.add(xs[best])
    n = n + 1
  }
  acc
}

/// Load every plugin found in `dirs`: each subdirectory holding a
/// `plugin.json` is one plugin, loaded with `registerPlugin`. Subdirectories
/// are visited in name order; a directory in `dirs` that does not exist is
/// skipped. Returns the plugins that were not loaded and why.
@experimental
pub func discoverPlugins(host: in PluginHost, dirs: in List[String]): List[PluginLoadIssue] {
  val issues: List[PluginLoadIssue] = newList()
  var d = 0
  while d < dirs.count {
    val root = dirs[d]
    if File.dirExists(root) {
      match File.listDirs(root) {
        case Err(e) -> issues.add(
          plIssue(ManifestUnreadable, root, "", "cannot list the plugin directory: " + IOError.message(e))
        )
        case Ok(subdirs) -> {
          val sorted = plSortStrings(subdirs)
          var i = 0
          while i < sorted.count {
            val dir = sorted[i]
            if File.fileExists(Path.join(dir, "plugin.json")) {
              match readPluginManifest(dir) {
                case Err(issue) -> issues.add(issue)
                case Ok(m) -> match registerPlugin(host, m, dir) { case Some(issue) -> issues.add(issue); case None -> () }
              }
            }
            i = i + 1
          }
        }
      }
    }
    d = d + 1
  }
  issues
}

func plFindPoint(points: in List[PluginPointInfo], id: in String): Option[PluginPointInfo] {
  var i = 0
  while i < points.count {
    if points[i].id == id {
      return Some(value = points[i])
    }
    i = i + 1
  }
  None
}

func plFindRequest(m: in PluginManifest, capability: in String): Option[CapabilityRequest] {
  var i = 0
  while i < m.required.count {
    if m.required[i].name == capability {
      return Some(value = m.required[i])
    }
    i = i + 1
  }
  var j = 0
  while j < m.optional.count {
    if m.optional[j].name == capability {
      return Some(value = m.optional[j])
    }
    j = j + 1
  }
  None
}

func plFindProvider(providers: in List[CapabilityProvider], capability: in String): Option[CapabilityProvider] {
  var i = 0
  while i < providers.count {
    if providers[i].info().id == capability {
      return Some(value = providers[i])
    }
    i = i + 1
  }
  None
}

func plFindGrant(grants: in List[GrantedCapability], capability: in String): Option[GrantedCapability] {
  var i = 0
  while i < grants.count {
    if grants[i].capability == capability {
      return Some(value = grants[i])
    }
    i = i + 1
  }
  None
}

func plCheckRequestAllowed(req: in CapabilityRequest, points: in List[PluginPointInfo]): Bool {
  var i = 0
  while i < points.count {
    if plContainsString(points[i].allows, req.name) {
      return true
    }
    i = i + 1
  }
  false
}

// The policy and provider calls run under `runCatchingBug`, so a panic in
// application code refuses the plugin or fails the one capability call
// instead of unwinding through the host (on native a panic ends the process).
record PolicyCall {
  policy: GrantPolicy
  manifest: PluginManifest
  var decision: GrantDecision
}

impl BugGuarded for PolicyCall {
  func invoke(): Unit {
    self.decision = self.policy.decide(self.manifest)
  }
}

record ServeCall {
  provider: CapabilityProvider
  method: String
  params: Option[JsonValue]
  grant: Option[JsonValue]
  var outcome: Result[JsonValue, RpcError]
}

impl BugGuarded for ServeCall {
  func invoke(): Unit {
    self.outcome = self.provider.serve(self.method, self.params, self.grant)
  }
}

/// Load one plugin whose payload paths are relative to `dir`, for a plugin
/// that is not in a catalogue directory (for example one a build tool has
/// just compiled and probed). `None` when it was loaded; otherwise the
/// reason it was not.
///
/// Loading matches the plugin's points with the host's (a plugin built
/// against another major version of a point is `K0103`; one that implements
/// none of them is not loaded), checks that every requested capability is
/// allowed by one of those points, asks the policy, checks each grant
/// against its request (`checkGrantWithinRequest`; a wider grant is
/// `K0102`), requires every required capability to be granted and every
/// granted one to have a provider, and chooses the payload. The plugin
/// itself is started on the first call.
@experimental
pub func registerPlugin(host: in PluginHost, manifest: in PluginManifest, dir: in String): Option[PluginLoadIssue] {
  val id = manifest.id
  var i = 0
  while i < host.plugins.count {
    if host.plugins[i].pluginId == id {
      return Some(value = plIssue(DuplicatePlugin, dir, id, "a plugin with id '" + id + "' is already loaded"))
    }
    i = i + 1
  }
  val offered: List[PluginPointInfo] = newList()
  var p = 0
  while p < manifest.points.count {
    val decl = manifest.points[p]
    match plFindPoint(host.config.points, decl.point) {
      case None -> ()
      case Some(info) -> {
        if plMajor(info.version) != plMajor(decl.version) {
          return Some(
            value = plIssue(
              MajorVersionMismatch,
              dir,
              id,
              "the plugin implements " + decl.point + " " + decl.version + " but this host offers " +
                info.version
            )
          )
        }
        offered.add(info)
      }
    }
    p = p + 1
  }
  if offered.count == 0 {
    return Some(value = plIssue(NoMatchingPoint, dir, id, "the plugin implements none of the points this host offers"))
  }
  var r = 0
  while r < manifest.required.count {
    if not plCheckRequestAllowed(manifest.required[r], offered) {
      return Some(
        value = plIssue(
          CapabilityNotAllowed,
          dir,
          id,
          "capability '" + manifest.required[r].name + "' is not allowed by the plugin's points"
        )
      )
    }
    r = r + 1
  }
  var o = 0
  while o < manifest.optional.count {
    if not plCheckRequestAllowed(manifest.optional[o], offered) {
      return Some(
        value = plIssue(
          CapabilityNotAllowed,
          dir,
          id,
          "capability '" + manifest.optional[o].name + "' is not allowed by the plugin's points"
        )
      )
    }
    o = o + 1
  }
  val wasmtime = findWasmtime()
  val payload = match selectPluginPayload(manifest.payloads, currentPluginPlatform(), host.config.preferWasm, isSome(wasmtime)) {
    case Some(pl) -> pl
    case None -> return Some(value = plIssue(NoUsablePayload, dir, id, "no payload of this plugin can run on this host"))
  }
  val launch = match pluginLaunchCommand(payload, dir, wasmtime, host.config.wasmMaxMemoryBytes) {
    case Ok(argv) -> argv
    case Err(e) -> return Some(value = plIssue(ManifestInvalid, dir, id, e))
  }
  val refusal = GrantDecision(allow = false, reason = "the grant policy failed", grants = newList())
  val policyCall = PolicyCall(policy = host.config.policy, manifest = manifest, decision = refusal)
  val decision = if runCatchingBug(policyCall) { policyCall.decision } else { refusal }
  if not decision.allow {
    val why = if decision.reason.length > 0 { decision.reason } else { "no reason given" }
    return Some(value = plIssue(PolicyRefused, dir, id, "the grant policy refused the plugin: " + why))
  }
  val grants: List[GrantedCapability] = newList()
  var g = 0
  while g < decision.grants.count {
    val granted = decision.grants[g]
    if isSome(plFindGrant(grants, granted.capability)) {
      return Some(value = plIssue(InvalidGrant, dir, id, "capability '" + granted.capability + "' is granted twice"))
    }
    match plFindRequest(manifest, granted.capability) {
      case None -> return Some(
        value = plIssue(
          InvalidGrant,
          dir,
          id,
          "capability '" + granted.capability + "' was granted but not requested"
        )
      )
      case Some(req) -> match checkGrantWithinRequest(req.grant, granted.grant) {
        case Err(e) -> return Some(
          value = plIssue(
            GrantWider,
            dir,
            id,
            "the grant of '" + granted.capability + "' is wider than the request: " + e
          )
        )
        case Ok(_) -> ()
      }
    }
    if isNone(plFindProvider(host.config.providers, granted.capability)) {
      return Some(
        value = plIssue(
          MissingProvider,
          dir,
          id,
          "capability '" + granted.capability + "' is granted but this host has no provider for it"
        )
      )
    }
    grants.add(GrantedCapability(capability = granted.capability, grant = plNonNull(granted.grant)))
    g = g + 1
  }
  var q = 0
  while q < manifest.required.count {
    if isNone(plFindGrant(grants, manifest.required[q].name)) {
      return Some(
        value = plIssue(
          RequiredNotGranted,
          dir,
          id,
          "required capability '" + manifest.required[q].name + "' was not granted"
        )
      )
    }
    q = q + 1
  }
  val state = PluginProcessState(
    manifest = manifest,
    dir = dir,
    points = offered,
    grants = grants,
    revocations = PluginRevocations(revoked = newList()),
    config = host.config,
    launch = launch,
    peer = None,
    process = None,
    methods = newList(),
    crashes = 0,
    lastCrashNanos = 0i64,
    fatal = None
  )
  host.plugins.add(PluginConnection(pluginId = id, peer = None, host = Some(value = state)))
  None
}

/// The manifests of every loaded plugin, in load order.
@experimental
pub func pluginManifests(host: in PluginHost): List[PluginManifest] {
  val acc: List[PluginManifest] = newList()
  var i = 0
  while i < host.plugins.count {
    match host.plugins[i].host {
      case Some(st) -> acc.add(st.manifest)
      case None -> ()
    }
    i = i + 1
  }
  acc
}

func plImplements(st: in PluginProcessState, pointId: in String): Bool {
  isSome(plFindPoint(st.points, pointId))
}

/// A connection to each loaded plugin that implements point `pointId`, in
/// load order. Nothing is started; the first `callPlugin` starts a plugin.
@experimental
pub func connectionsFor(host: in PluginHost, pointId: in String): List[PluginConnection] {
  val acc: List[PluginConnection] = newList()
  var i = 0
  while i < host.plugins.count {
    match host.plugins[i].host {
      case Some(st) -> if plImplements(st, pointId) { acc.add(host.plugins[i]) }
      case None -> ()
    }
    i = i + 1
  }
  acc
}

/// The contributions each loaded plugin declares for point `pointId`, read
/// from the manifests without starting anything.
@experimental
pub func contributionsFor(host: in PluginHost, pointId: in String): List[PluginContributionJson] {
  val acc: List[PluginContributionJson] = newList()
  var i = 0
  while i < host.plugins.count {
    match host.plugins[i].host {
      case Some(st) -> if plImplements(st, pointId) {
        var p = 0
        while p < st.manifest.points.count {
          val decl = st.manifest.points[p]
          if decl.point == pointId {
            match decl.contributions {
              case Some(c) -> acc.add(PluginContributionJson(pluginId = st.manifest.id, value = c))
              case None -> ()
            }
          }
          p = p + 1
        }
      }
      case None -> ()
    }
    i = i + 1
  }
  acc
}

func plFindConnection(host: in PluginHost, id: in String): Option[PluginConnection] {
  var i = 0
  while i < host.plugins.count {
    if host.plugins[i].pluginId == id {
      return Some(value = host.plugins[i])
    }
    i = i + 1
  }
  None
}

// ── Host side: serving capability calls ────────────────────────────────────
// Answers the plugin's `cap/<Pkg>.<C>/<method>` requests with the granted
// value and the registered provider.
record PluginCapabilityServer {
  providers: List[CapabilityProvider]
  grants: List[GrantedCapability]
  revocations: PluginRevocations
}

func plServeCapability(
  caps: in PluginCapabilityServer, method: in String, params: in Option[JsonValue]
): Result[JsonValue, RpcError] {
  if not Str.startsWith(method, "cap/") {
    return Err(error = RpcError(code = rpcMethodNotFound, message = "method not found: " + method, data = None))
  }
  val rest = Str.substring(method, 4)
  val slash = match Str.lastIndexOf(rest, "/") { case Some(s) -> s; case None -> -1 }
  if slash <= 0 or slash == rest.length - 1 {
    return Err(error = RpcError(code = rpcMethodNotFound, message = "method not found: " + method, data = None))
  }
  val capability = Str.substring(rest, 0, slash)
  val name = Str.substring(rest, slash + 1)
  if plContainsString(caps.revocations.revoked, capability) {
    return Err(error = boundaryErrorToRpc(Revoked(capability = capability)))
  }
  val grant = match plFindGrant(caps.grants, capability) {
    case Some(gr) -> gr
    case None -> return Err(error = boundaryErrorToRpc(Denied(reason = "capability '" + capability + "' is not granted")))
  }
  val provider = match plFindProvider(caps.providers, capability) {
    case Some(pv) -> pv
    case None -> return Err(error = boundaryErrorToRpc(Denied(reason = "capability '" + capability + "' has no provider")))
  }
  val failed: Result[JsonValue, RpcError] = Err(
    error = RpcError(
      code = rpcInternalError,
      message = "Internal error",
      data = None
    )
  )
  val serveCall = ServeCall(provider = provider, method = name, params = params, grant = grant.grant, outcome = failed)
  if runCatchingBug(serveCall) {
    serveCall.outcome
  } else {
    failed
  }
}

func plDecodeId(v: in JsonValue): Option[RpcId] {
  match v {
    case JInt(n) -> Some(value = IntId(value = n))
    case JString(s) -> Some(value = StringId(value = s))
    case JNull -> Some(value = NullId)
    case _ -> None
  }
}

// If `line` is a request or notification from the plugin, answer it and
// return true; otherwise (a response, or something malformed) return false
// so the peer sees it.
func plServeInbound(caps: in PluginCapabilityServer, proc: in PipedProcess, line: in String): Bool {
  val v = match parseValue(line) { case Ok(parsed) -> parsed; case Err(_) -> return false }
  val methodValue = match v {
    case JObject(_) -> match getField(v, "method") { case Some(mv) -> mv; case None -> return false }
    case _ -> return false
  }
  val idValue = match getField(v, "id") {
    case Some(iv) -> iv
    // A notification ($/cancelRequest, a log line): nothing to answer.
    case None -> return true
  }
  val rid = match plDecodeId(idValue) { case Some(decoded) -> decoded; case None -> NullId }
  val response = match methodValue {
    case JString(method) -> {
      val params = getField(v, "params")
      match plServeCapability(caps, method, params) {
        case Ok(rv) -> RpcSuccess(id = rid, value = rv)
        case Err(e) -> RpcFailure(id = rid, error = e)
      }
    }
    case _ -> RpcFailure(
      id = rid,
      error = RpcError(
        code = rpcInvalidRequest,
        message = "Invalid Request: \"method\" must be a string",
        data = None
      )
    )
  }
  // A failed write means the plugin is gone; the next read reports it.
  val _ = pipedWriteLine(proc, writeValue(encodeResponse(response)))
  true
}

// Milliseconds left before `deadline` (a `monotonicNanos` instant), at least 0.
func plRemainingMs(deadline: in Long): Int {
  val left = deadline - monotonicNanos()
  if left <= 0i64 {
    0
  } else {
    ((left + 999999i64) / 1000000i64).toInt()
  }
}

// The host's transport to one plugin process: NDJSON over the child's piped
// stdin and stdout. Requests the plugin sends are answered here, inline,
// while the host waits for a response, so the peer only ever sees responses.
record PluginChildTransport {
  proc: PipedProcess
  caps: PluginCapabilityServer
}

impl RpcTransport for PluginChildTransport {
  func receive(): Result[Option[String], String] {
    var outcome: Result[Option[String], String] = Ok(value = None)
    var waiting = true
    while waiting {
      val read: Result[Option[String], String] = pipedReadLine(self.proc)
      match read {
        case Err(e) -> {
          outcome = Err(error = "plugin stdout: " + e)
          waiting = false
        }
        case Ok(opt) -> match opt {
          case None -> {
            outcome = Ok(value = None)
            waiting = false
          }
          case Some(line) -> match ndjsonAcceptLine(line) {
            case Err(e) -> {
              outcome = Err(error = e)
              waiting = false
            }
            case Ok(accepted) -> if not plServeInbound(self.caps, self.proc, accepted) {
              outcome = Ok(value = Some(value = accepted))
              waiting = false
            }
          }
        }
      }
    }
    outcome
  }

  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String] {
    val deadline = monotonicNanos() + timeoutMs.toLong() * 1000000i64
    var outcome: Result[ReceiveOutcome, String] = Ok(value = RpcTimedOut)
    var waiting = true
    while waiting {
      val read: Result[PipedReadOutcome, String] = pipedReadLineWithin(self.proc, plRemainingMs(deadline))
      match read {
        case Err(e) -> {
          outcome = Err(error = "plugin stdout: " + e)
          waiting = false
        }
        case Ok(o) -> match o {
          case PipedEndOfStream -> {
            outcome = Ok(value = RpcEndOfStream)
            waiting = false
          }
          case PipedTimedOut -> {
            outcome = Ok(value = RpcTimedOut)
            waiting = false
          }
          case PipedLine(line) -> match ndjsonAcceptLine(line) {
            case Err(e) -> {
              outcome = Err(error = e)
              waiting = false
            }
            case Ok(accepted) -> if not plServeInbound(self.caps, self.proc, accepted) {
              outcome = Ok(value = RpcMessage(text = accepted))
              waiting = false
            }
          }
        }
      }
    }
    outcome
  }

  func send(payload: in String): Result[Unit, String] {
    match pipedWriteLine(self.proc, payload) {
      case Ok(_) -> Ok(value = ())
      case Err(e) -> Err(error = "plugin stdin: " + e)
    }
  }

  // The process belongs to its PluginProcessState, which stops it.
  func close(): Unit {
  }
}

// The host's peer never dispatches: every request from the plugin is served
// by `PluginChildTransport`.
record PluginHostInbound {
}

impl RpcHandler for PluginHostInbound {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    Err(error = RpcError(code = rpcMethodNotFound, message = "method not found: " + method, data = None))
  }

  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
  }
}

// ── Host side: lifecycle ───────────────────────────────────────────────────
// Kill the plugin's process (if any) and forget it.
func plTeardown(st: inout PluginProcessState): Unit {
  match st.process {
    case Some(proc) -> {
      pipedKill(proc)
      val _ = pipedWaitExit(proc, 2000)
      pipedClose(proc)
    }
    case None -> ()
  }
  st.process = None
  st.peer = None
  st.methods = newList()
}

// Record a crash: stop what is left of the process, and give up for good
// once the plugin has crashed more than `maxRestarts` times.
func plNoteCrash(st: inout PluginProcessState, detail: in String): BoundaryError {
  plTeardown(st)
  st.crashes = st.crashes + 1
  st.lastCrashNanos = monotonicNanos()
  if st.crashes > st.config.maxRestarts {
    val fatal = Crashed(
      detail = "plugin '" + st.manifest.id + "' crashed " + st.crashes.toString() + " times, more than the " +
        st.config.maxRestarts.toString() +
        " restarts allowed; last: " +
        detail
    )
    st.fatal = Some(value = fatal)
  }
  Crashed(detail = detail)
}

// The wait before restart number `crashes`: restartBackoffMs doubled per
// earlier restart, capped at maxRestartBackoffMs.
func plBackoffMs(config: in PluginHostConfig, crashes: in Int): Int {
  var delay = config.restartBackoffMs
  var i = 1
  while i < crashes and delay < config.maxRestartBackoffMs {
    delay = delay * 2
    i = i + 1
  }
  if delay > config.maxRestartBackoffMs {
    config.maxRestartBackoffMs
  } else {
    delay
  }
}

func plHelloParams(st: in PluginProcessState): JsonValue {
  val points: List[JsonField] = newList()
  var i = 0
  while i < st.points.count {
    points.add(plField(st.points[i].id, JString(value = st.points[i].version)))
    i = i + 1
  }
  val grants: List[JsonValue] = newList()
  var g = 0
  while g < st.grants.count {
    val gr = st.grants[g]
    if not plContainsString(st.revocations.revoked, gr.capability) {
      val fields: List[JsonField] = newList()
      fields.add(plField("capability", JString(value = gr.capability)))
      fields.add(plField("grant", plOptJson(gr.grant)))
      grants.add(JObject(fields = fields))
    }
    g = g + 1
  }
  val fields: List[JsonField] = newList()
  fields.add(plField("protocol", JInt(value = pluginProtocolVersion.toLong())))
  fields.add(plField("points", JObject(fields = points)))
  fields.add(plField("grants", JArray(items = grants)))
  JObject(fields = fields)
}

// Read the plugin's `plugin/hello` answer: the methods it implements for
// each point the host offered.
func plParseHello(st: in PluginProcessState, v: in JsonValue): Result[List[PluginPointMethods], String] {
  match getInt(v, "protocol") {
    case Some(n) -> if n != pluginProtocolVersion.toLong() {
      return Err(error = "the plugin speaks protocol " + n.toString() + ", not 1")
    }
    case None -> return Err(error = "the plugin/hello answer has no integer \"protocol\"")
  }
  match getString(v, "id") {
    case Some(id) -> if id != st.manifest.id {
      return Err(error = "the plugin says it is '" + id + "', but its manifest says '" + st.manifest.id + "'")
    }
    case None -> return Err(error = "the plugin/hello answer has no \"id\"")
  }
  val points = match getField(v, "points") {
    case Some(p) -> match p {
      case JObject(_) -> p
      case _ -> return Err(error = "\"points\" in the plugin/hello answer must be an object")
    }
    case None -> return Err(error = "the plugin/hello answer has no \"points\"")
  }
  val acc: List[PluginPointMethods] = newList()
  var i = 0
  while i < st.points.count {
    val info = st.points[i]
    match getField(points, info.id) {
      case None -> ()
      case Some(pointEntry) -> {
        val version = match getString(pointEntry, "version") {
          case Some(s) -> s
          case None -> return Err(error = "point '" + info.id + "' in the plugin/hello answer has no \"version\"")
        }
        if not isPointVersion(version) or plMajor(version) != plMajor(info.version) {
          return Err(error = "the plugin implements " + info.id + " " + version + " but this host offers " + info.version)
        }
        val names: List[String] = newList()
        match getField(pointEntry, "methods") {
          case Some(ms) -> match ms {
            case JArray(items) -> {
              var k = 0
              while k < items.count {
                match items[k] {
                  case JString(s) -> names.add(s)
                  case _ -> return Err(error = "point '" + info.id + "': \"methods\" must be an array of strings")
                }
                k = k + 1
              }
            }
            case _ -> return Err(error = "point '" + info.id + "': \"methods\" must be an array of strings")
          }
          case None -> return Err(error = "point '" + info.id + "' in the plugin/hello answer has no \"methods\"")
        }
        acc.add(PluginPointMethods(point = info.id, version = version, methods = names))
      }
    }
    i = i + 1
  }
  Ok(value = acc)
}

// Start the plugin and complete the handshake.
func plStart(st: inout PluginProcessState): Result[RpcPeer, BoundaryError] {
  if st.crashes > 0 {
    val wait = plBackoffMs(st.config, st.crashes) - ((monotonicNanos() - st.lastCrashNanos) / 1000000i64).toInt()
    if wait > 0 {
      sleepMillis(wait)
    }
  }
  val argv = st.launch
  val args: List[String] = newList()
  var i = 1
  while i < argv.count {
    args.add(argv[i])
    i = i + 1
  }
  val proc = match spawnPiped(argv[0], args) {
    case Ok(pr) -> pr
    case Err(e) -> return Err(error = plNoteCrash(st, "could not start '" + argv[0] + "': " + IOError.message(e)))
  }
  val caps = PluginCapabilityServer(providers = st.config.providers, grants = st.grants, revocations = st.revocations)
  var peer = newPeerWithTimeout(
    PluginChildTransport(proc = proc, caps = caps),
    PluginHostInbound(),
    st.config.callTimeoutMs
  )
  st.process = Some(value = proc)
  st.peer = Some(value = peer)
  match callWithin(peer, "plugin/hello", Some(value = plHelloParams(st)), st.config.startTimeoutMs) {
    case Err(e) -> {
      if isLocalError(e) {
        Err(error = plNoteCrash(st, "plugin/hello failed: " + e.message))
      } else {
        val b = boundaryErrorFromRpc(e, "plugin/hello")
        val fatal = match b {
          case NotGranted(_) -> b
          case _ -> Protocol(detail = "the plugin refused plugin/hello: " + e.message)
        }
        plTeardown(st)
        st.fatal = Some(value = fatal)
        Err(error = fatal)
      }
    }
    case Ok(v) -> match plParseHello(st, v) {
      case Err(msg) -> {
        plTeardown(st)
        val fatal = Protocol(detail = msg)
        st.fatal = Some(value = fatal)
        Err(error = fatal)
      }
      case Ok(methods) -> {
        st.methods = methods
        Ok(value = peer)
      }
    }
  }
}

// The running plugin's peer, starting (or restarting) it when needed.
func plEnsureStarted(st: inout PluginProcessState): Result[RpcPeer, BoundaryError] {
  match st.fatal {
    case Some(b) -> return Err(error = b)
    case None -> ()
  }
  match st.peer {
    case Some(p) -> {
      val alive = match st.process { case Some(proc) -> pipedIsAlive(proc); case None -> false }
      if alive {
        return Ok(value = p)
      }
      val code = match st.process { case Some(proc) -> pipedExitCode(proc); case None -> -1 }
      val _ = plNoteCrash(st, "the plugin exited with code " + code.toString() + " between calls")
      match st.fatal {
        case Some(b) -> return Err(error = b)
        case None -> ()
      }
    }
    case None -> ()
  }
  plStart(st)
}

func plMethodsFor(st: in PluginProcessState, pointId: in String): Option[PluginPointMethods] {
  var i = 0
  while i < st.methods.count {
    if st.methods[i].point == pointId {
      return Some(value = st.methods[i])
    }
    i = i + 1
  }
  None
}

// Call params are an object keyed by parameter name (D207 Decision 3);
// `null` stands for a method without parameters.
func plCallParams(params: in JsonValue): Result[JsonValue, BoundaryError] {
  match params {
    case JObject(_) -> Ok(value = params)
    case JNull -> Ok(value = JObject(fields = newList()))
    case _ -> Err(error = Protocol(detail = "call params must be an object keyed by parameter name"))
  }
}

func plHostCall(st: inout PluginProcessState, method: in String, params: in JsonValue): Result[JsonValue, BoundaryError] {
  val slash = match Str.lastIndexOf(method, "/") { case Some(s) -> s; case None -> -1 }
  if slash <= 0 or slash == method.length - 1 {
    return Err(error = Unsupported(method = method))
  }
  val pointId = Str.substring(method, 0, slash)
  val name = Str.substring(method, slash + 1)
  val wireParams = match plCallParams(params) { case Ok(p) -> p; case Err(b) -> return Err(error = b) }
  if isNone(plFindPoint(st.points, pointId)) {
    return Err(error = Unsupported(method = method))
  }
  val started = match plEnsureStarted(st) { case Ok(p) -> p; case Err(b) -> return Err(error = b) }
  val implemented = match plMethodsFor(st, pointId) {
    case Some(pm) -> plContainsString(pm.methods, name)
    case None -> false
  }
  if not implemented {
    return Err(error = Unsupported(method = method))
  }
  var peer = started
  val requestId = peer.nextId
  val timeoutMs = st.config.callTimeoutMs
  val reply = callWithin(peer, method, Some(value = wireParams), timeoutMs)
  val _ = drainPendingQueue(peer)
  match reply {
    case Ok(v) -> Ok(value = v)
    case Err(e) -> {
      if isLocalError(e) {
        if e.code == rpcRequestTimedOut {
          val cancel: List[JsonField] = newList()
          cancel.add(plField("id", JInt(value = requestId)))
          val _ = notify(peer, "$/cancelRequest", Some(value = JObject(fields = cancel)))
          Err(error = Timeout(timeoutMs = timeoutMs))
        } else {
          Err(error = plNoteCrash(st, e.message))
        }
      } else {
        Err(error = boundaryErrorFromRpc(e, method))
      }
    }
  }
}

/// Call method `<Pkg>.<P>/<method>` of the plugin behind `conn` with
/// `params` (an object keyed by parameter name, or `null` for none), starting the plugin first if
/// it is not running. Returns the call's result object (`{"ok": ...}` or
/// `{"err": ...}`), or the `BoundaryError` that stopped it: `Unsupported` for
/// a point the plugin does not implement here or a method it did not list in
/// its handshake (the plugin is not asked), `Timeout` after the host's call
/// timeout (the plugin is sent `$/cancelRequest` and keeps running),
/// `Crashed` when the plugin exits or its pipes fail (it is restarted on the
/// next call), and the plugin's own boundary errors as
/// `boundaryErrorFromRpc` maps them. While waiting, the host serves the
/// plugin's capability calls.
@experimental
pub func callPlugin(
  conn: in PluginConnection, method: in String, params: in JsonValue
): Result[JsonValue, BoundaryError] {
  match conn.host {
    case None -> Err(
      error = Protocol(
        detail = "callPlugin needs a connection from connectionsFor; this one is the plugin side's link to its host"
      )
    )
    case Some(s) -> {
      var st = s
      plHostCall(st, method, params)
    }
  }
}

// Ask the plugin to stop, close its stdin, and kill it if it has not exited
// within the grace period.
func plShutdown(st: inout PluginProcessState): Unit {
  match st.peer {
    case Some(p) -> {
      var peer = p
      val _ = notify(peer, "plugin/shutdown", None)
    }
    case None -> ()
  }
  match st.process {
    case Some(proc) -> {
      pipedCloseStdin(proc)
      if not pipedWaitExit(proc, st.config.shutdownGraceMs) {
        pipedKill(proc)
        val _ = pipedWaitExit(proc, 2000)
      }
      pipedClose(proc)
    }
    case None -> ()
  }
  st.process = None
  st.peer = None
  st.methods = newList()
}

/// Stop plugin `id` if it is running (`plugin/shutdown`, then closing its
/// stdin, then killing it after `shutdownGraceMs`). It stays catalogued: the
/// next call starts it again.
@experimental
pub func stopPlugin(host: in PluginHost, id: in String): Unit {
  match plFindConnection(host, id) {
    case Some(conn) -> match conn.host { case Some(s) -> { var st = s; plShutdown(st) }; case None -> () }
    case None -> ()
  }
}

/// Stop every running plugin, as `stopPlugin` does.
@experimental
pub func stopAllPlugins(host: in PluginHost): Unit {
  var i = 0
  while i < host.plugins.count {
    stopPlugin(host, host.plugins[i].pluginId)
    i = i + 1
  }
}

/// Revoke capability `capability` from plugin `id`. Its later calls to that
/// capability fail with `Revoked`, and a restart of the plugin no longer
/// receives the grant.
@experimental
pub func revokeCapability(host: in PluginHost, id: in String, capability: in String): Unit {
  match plFindConnection(host, id) {
    case Some(conn) -> match conn.host {
      case Some(st) -> if not plContainsString(st.revocations.revoked, capability) {
        st.revocations.revoked.add(capability)
      }
      case None -> ()
    }
    case None -> ()
  }
}

/// Start plugin `pluginId` for protocol point `pointId` and hand its process
/// to the caller, who speaks the point's protocol (an LSP server, for
/// example) over its stdin and stdout and owns its lifetime. There is no
/// `plugin/hello` and no capability serving on this channel.
@experimental
pub func openProtocolPlugin(
  host: in PluginHost, pointId: in String, pluginId: in String
): Result[PipedProcess, BoundaryError] {
  val conn = match plFindConnection(host, pluginId) {
    case Some(c) -> c
    case None -> return Err(error = Unsupported(method = pointId))
  }
  val st = match conn.host { case Some(s) -> s; case None -> return Err(error = Unsupported(method = pointId)) }
  match plFindPoint(st.points, pointId) {
    case Some(info) -> if isNone(info.protocol) {
      return Err(error = Protocol(detail = "'" + pointId + "' is not a protocol point"))
    }
    case None -> return Err(error = Unsupported(method = pointId))
  }
  match st.fatal {
    case Some(b) -> return Err(error = b)
    case None -> ()
  }
  val args: List[String] = newList()
  var i = 1
  while i < st.launch.count {
    args.add(st.launch[i])
    i = i + 1
  }
  match spawnPiped(st.launch[0], args) {
    case Ok(proc) -> Ok(value = proc)
    case Err(e) -> Err(error = Crashed(detail = "could not start '" + st.launch[0] + "': " + IOError.message(e)))
  }
}

// ── Plugin side ────────────────────────────────────────────────────────────
/// The methods a plugin implements for one point, reported in its
/// `plugin/hello` answer.
@experimental
pub record PluginPointMethods {
  point: String
  version: String
  methods: List[String]
}

/// The plugin side of the protocol, implemented by the code
/// `Lyric.PluginExpand` generates for a `@plugin` record.
///
/// - `describe` returns the plugin's manifest (without payloads).
/// - `attach` receives the connection to the host and the granted capabilities
///   during `plugin/hello`; `Err(NotGranted(c))` when a required capability
///   is missing.
/// - `pointMethods` lists the methods implemented for each point.
/// - `dispatch` handles one point call `<Pkg>.<P>/<method>` and returns its
///   result object (`{"ok": ...}` or `{"err": ...}`).
@experimental
pub interface PluginServer {
  func describe(): JsonValue

  func attach(conn: in PluginConnection, grants: in List[GrantedCapability]): Result[Unit, BoundaryError]

  func pointMethods(): List[PluginPointMethods]

  func dispatch(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError]
}

func plProtocolError(message: in String): RpcError {
  boundaryErrorToRpc(Protocol(detail = message))
}

func plParseGrants(params: in Option[JsonValue]): Result[List[GrantedCapability], String] {
  val p = match params { case Some(v) -> v; case None -> return Err(error = "plugin/hello has no params") }
  match getInt(p, "protocol") {
    case Some(n) -> if n != pluginProtocolVersion.toLong() {
      return Err(error = "the host speaks protocol " + n.toString() + "; this plugin speaks 1")
    }
    case None -> return Err(error = "plugin/hello has no integer \"protocol\"")
  }
  val acc: List[GrantedCapability] = newList()
  match plNonNull(getField(p, "grants")) {
    case None -> ()
    case Some(gv) -> match gv {
      case JArray(items) -> {
        var i = 0
        while i < items.count {
          match getString(items[i], "capability") {
            case Some(c) -> acc.add(GrantedCapability(capability = c, grant = plNonNull(getField(items[i], "grant"))))
            case None -> return Err(error = "plugin/hello: each grant needs a \"capability\" string")
          }
          i = i + 1
        }
      }
      case _ -> return Err(error = "plugin/hello: \"grants\" must be an array")
    }
  }
  Ok(value = acc)
}

func plHelloAnswer(pluginId: in String, points: in List[PluginPointMethods]): JsonValue {
  val pf: List[JsonField] = newList()
  var i = 0
  while i < points.count {
    val pointEntry: List[JsonField] = newList()
    pointEntry.add(plField("version", JString(value = points[i].version)))
    pointEntry.add(plField("methods", plStringArray(points[i].methods)))
    pf.add(plField(points[i].point, JObject(fields = pointEntry)))
    i = i + 1
  }
  val fields: List[JsonField] = newList()
  fields.add(plField("protocol", JInt(value = pluginProtocolVersion.toLong())))
  fields.add(plField("id", JString(value = pluginId)))
  fields.add(plField("points", JObject(fields = pf)))
  JObject(fields = fields)
}

// The plugin process's handler: the handshake first, then point calls.
record PluginSideHandler {
  server: PluginServer
  conn: PluginConnection
  pluginId: String
  var greeted: Bool
}

impl RpcHandler for PluginSideHandler {
  func onRequest(method: in String, params: in Option[JsonValue]): Result[JsonValue, RpcError] {
    if method == "plugin/hello" {
      if self.greeted {
        return Err(error = plProtocolError("plugin/hello was already received"))
      }
      val grants = match plParseGrants(params) { case Ok(g) -> g; case Err(e) -> return Err(error = plProtocolError(e)) }
      match self.server.attach(self.conn, grants) {
        case Err(b) -> Err(error = boundaryErrorToRpc(b))
        case Ok(_) -> {
          self.greeted = true
          Ok(value = plHelloAnswer(self.pluginId, self.server.pointMethods()))
        }
      }
    } else if not self.greeted {
      Err(error = plProtocolError("the first request must be plugin/hello, not " + method))
    } else {
      self.server.dispatch(method, params)
    }
  }

  // `plugin/shutdown` needs no action: the host closes stdin next, and the
  // loop in `runPlugin` ends at end of input. `$/cancelRequest` arrives only
  // after the request it names has been answered, since requests are
  // handled one at a time.
  func onNotification(method: in String, params: in Option[JsonValue]): Unit {
  }
}

// The plugin's NDJSON transport over its own stdin and stdout. It is
// `Std.JsonRpc.Stdio.NdjsonTransport` rebuilt from that package's sans-IO
// framing functions, because the stage-0 seed that builds the compiler's
// stdlib bundle does not see another package's `impl` blocks (D204 item 5
// postdates it), so `NdjsonTransport` is no `RpcTransport` to it.
record PluginStdinSource {
  reader: StdinReader
}

impl ByteSource for PluginStdinSource {
  func read(): Result[Option[slice[Byte]], String] {
    match readStdin(self.reader) {
      case Ok(bytes) -> Ok(value = bytes)
      case Err(e) -> Err(error = IOError.message(e))
    }
  }

  func readWithin(timeoutMs: in Int): Result[ByteRead, String] {
    match readStdinWithin(self.reader, timeoutMs) {
      case Err(e) -> Err(error = IOError.message(e))
      case Ok(chunk) -> match chunk {
        case StdinBytes(bytes) -> Ok(value = BytesRead(bytes = bytes))
        case StdinEnd -> Ok(value = BytesEnd)
        case StdinTimedOut -> Ok(value = BytesTimedOut)
      }
    }
  }
}

record PluginStdioTransport {
  source: PluginStdinSource
  buffer: FrameBuffer
}

impl RpcTransport for PluginStdioTransport {
  func receive(): Result[Option[String], String] {
    ndjsonReceiveFrom(self.source, self.buffer)
  }

  func receiveWithin(timeoutMs: in Int): Result[ReceiveOutcome, String] {
    ndjsonReceiveWithinFrom(self.source, self.buffer, timeoutMs)
  }

  // `writeValue` output is compact, so a message is exactly one line.
  func send(payload: in String): Result[Unit, String] {
    Console.println(payload)
    Ok(value = ())
  }

  func close(): Unit {
  }
}

func plIsManifestProbe(argv: in slice[String]): Bool {
  for a in argv {
    if a == manifestProbeArgument {
      return true
    }
  }
  false
}

/// The entry point of a plugin executable. Run with `--lyric-plugin-manifest`
/// it prints `server.describe()` as one JSON document and returns 0 without
/// reading stdin. Otherwise it serves the plugin protocol over stdin and
/// stdout until the host closes stdin, and returns 0 (1 when the transport
/// fails). Stdout belongs to the protocol: a plugin logs to stderr.
@experimental
pub func runPlugin(server: in PluginServer): Int {
  val description = server.describe()
  if plIsManifestProbe(Env.args()) {
    Console.println(writeValue(description))
    return 0
  }
  val pluginId = unwrapOr(getString(description, "id"), "")
  var conn = PluginConnection(pluginId = pluginId, peer = None, host = None)
  val handler = PluginSideHandler(server = server, conn = conn, pluginId = pluginId, greeted = false)
  var peer = newPeer(
    PluginStdioTransport(source = PluginStdinSource(reader = openStdinReader()), buffer = newFrameBuffer()),
    handler
  )
  conn.peer = Some(value = peer)
  match runLoop(peer) {
    case Ok(_) -> 0
    case Err(e) -> {
      Console.error("plugin '" + pluginId + "': transport failed: " + e)
      1
    }
  }
}

/// Make a capability call from inside a point method: `method` is
/// `cap/<Pkg>.<C>/<method>` (a name without the `cap/` prefix gets it), and
/// `params` an object keyed by parameter name (or `null`). Returns the call's result
/// object (`{"ok": ...}` or `{"err": ...}`) or the `BoundaryError` the host
/// answered with (`Denied` when the capability is not granted, `Revoked`
/// after the host revoked it). `conn` is the connection `attach` received.
@experimental
pub func callHost(conn: in PluginConnection, method: in String, params: in JsonValue): Result[JsonValue, BoundaryError] {
  val wire = if Str.startsWith(method, "cap/") { method } else { "cap/" + method }
  val wireParams = match plCallParams(params) { case Ok(wp) -> wp; case Err(b) -> return Err(error = b) }
  match conn.peer {
    case None -> Err(error = Protocol(detail = "callHost needs the connection PluginServer.attach received"))
    case Some(p) -> {
      var peer = p
      val timeoutMs = peer.callTimeoutMs
      match callWithin(peer, wire, Some(value = wireParams), timeoutMs) {
        case Ok(v) -> Ok(value = v)
        case Err(e) -> if isLocalError(e) {
          if e.code == rpcRequestTimedOut {
            Err(error = Timeout(timeoutMs = timeoutMs))
          } else {
            Err(error = Crashed(detail = "the connection to the host failed: " + e.message))
          }
        } else {
          Err(error = boundaryErrorFromRpc(e, wire))
        }
      }
    }
  }
}
