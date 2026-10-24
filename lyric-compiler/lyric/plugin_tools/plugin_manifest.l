//! plugin_manifest.l - Lyric.PluginManifest: the compiler-side reader and
//! validator of plugin manifests (`plugin.json`, D207 Decision 5), shared by
//! `lyric plugin check` and `lyric plugin pack`.
//!
//! A manifest is checked in one of two modes.  `ArtifactCheck` validates a
//! plugin artifact directory: the schema, every required field, the version
//! spellings, the payload forms and that each payload file is present.
//! `ProbeCheck` validates the document a plugin prints for
//! `--lyric-plugin-manifest`, which has the same fields but no `payloads`
//! (pack adds those).
//!
//! The JSON text helpers here work on the text, not on a parsed value, so a
//! manifest's numbers are written back exactly as the plugin printed them.
package Lyric.PluginManifest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.JsonValue

/// One problem found in a manifest: `location` is a JSON path such as
/// `points[1].version` (empty for the document as a whole).
pub record ManifestProblem {
  location: String
  message: String
}

pub union CheckMode {
  /// A plugin artifact directory: payloads are required and must exist in `dir`.
  case ArtifactCheck(dir: String)
  /// The output of a `--lyric-plugin-manifest` probe: no payloads allowed.
  case ProbeCheck
}

/// The text of a problem as `lyric plugin check` prints it.
pub func problemText(p: in ManifestProblem): String {
  if p.location.length > 0 {
    p.location + ": " + p.message
  } else {
    p.message
  }
}

func problem(acc: in List[ManifestProblem], location: in String, message: in String): Unit {
  acc.add(ManifestProblem(location = location, message = message))
}

// ── Spellings ────────────────────────────────────────────────────────────────
func isDigitCode(c: in Int): Bool = c >= 48 and c <= 57

func isAlphaCode(c: in Int): Bool = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)

/// A decimal number without a leading zero ("0" itself is allowed).
func isPlainNumber(s: in String): Bool {
  if s.length == 0 or s.length > 9 {
    return false
  }
  var i = 0
  while i < s.length {
    if not isDigitCode(Str.codeUnitAt(s, i)) {
      return false
    }
    i = i + 1
  }
  not (s.length > 1 and Str.codeUnitAt(s, 0) == 48)
}

/// A plugin point or capability version: `major.minor` (D207 Decision 1).
pub func isMajorMinor(v: in String): Bool {
  val parts = Str.split(v, ".")
  parts.length == 2 and isPlainNumber(parts[0]) and isPlainNumber(parts[1])
}

func isPrereleaseText(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if not (isDigitCode(c) or isAlphaCode(c) or c == 45 or c == 46) {
      return false
    }
    i = i + 1
  }
  true
}

/// A plugin's own version: `major.minor.patch`, optionally
/// followed by a `-prerelease` and a `+build` suffix as in semantic versioning.
pub func isPluginVersion(v: in String): Bool {
  var core = v
  val plus = Str.indexOfRaw(core, "+")
  if plus >= 0 {
    if not isPrereleaseText(Str.substring(core, plus + 1)) {
      return false
    }
    core = Str.substring(core, 0, plus)
  }
  val dash = Str.indexOfRaw(core, "-")
  if dash >= 0 {
    if not isPrereleaseText(Str.substring(core, dash + 1)) {
      return false
    }
    core = Str.substring(core, 0, dash)
  }
  val parts = Str.split(core, ".")
  if parts.length != 3 {
    return false
  }
  var i = 0
  while i < parts.length {
    if not isPlainNumber(parts[i]) {
      return false
    }
    i = i + 1
  }
  true
}

/// A plugin id: dot-separated segments of letters, digits, `-` and `_`, none
/// empty, the rule `Std.Plugin.isPluginId` applies.  The id names the artifact
/// directory, so it cannot contain a path separator.
pub func isPluginId(id: in String): Bool {
  if id.length == 0 {
    return false
  }
  for seg in Str.split(id, ".") {
    if seg.length == 0 {
      return false
    }
    var i = 0
    while i < seg.length {
      val c = Str.codeUnitAt(seg, i)
      if not (isDigitCode(c) or isAlphaCode(c) or c == 45 or c == 95) {
        return false
      }
      i = i + 1
    }
  }
  true
}

func isIdentifier(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  val first = Str.codeUnitAt(s, 0)
  if not (isAlphaCode(first) or first == 95) {
    return false
  }
  var i = 1
  while i < s.length {
    val c = Str.codeUnitAt(s, i)
    if not (isAlphaCode(c) or isDigitCode(c) or c == 95) {
      return false
    }
    i = i + 1
  }
  true
}

/// A package-qualified interface name such as `Editor.Api.EditorExtension`.
pub func isQualifiedName(s: in String): Bool {
  val parts = Str.split(s, ".")
  if parts.length < 2 {
    return false
  }
  var i = 0
  while i < parts.length {
    if not isIdentifier(parts[i]) {
      return false
    }
    i = i + 1
  }
  true
}

/// A payload path: relative to the artifact directory, `/`-separated, and
/// never leaving it.
pub func isArtifactRelativePath(p: in String): Bool {
  if p.length == 0 or Str.startsWith(p, "/") or Str.contains(p, "\\") {
    return false
  }
  if Str.contains(p, ":") {
    return false
  }
  val segs = Str.split(p, "/")
  var i = 0
  while i < segs.length {
    if segs[i].length == 0 or segs[i] == "." or segs[i] == ".." {
      return false
    }
    i = i + 1
  }
  true
}

// ── JSON helpers ─────────────────────────────────────────────────────────────
func kindName(v: in JsonValue): String {
  match v {
    case JNull -> "null"
    case JBool(_) -> "a boolean"
    case JInt(_) -> "a number"
    case JFloat(_) -> "a number"
    case JString(_) -> "a string"
    case JArray(_) -> "an array"
    case JObject(_) -> "an object"
  }
}

func fieldPath(base: in String, name: in String): String = if base.length == 0 { name } else { base + "." + name }

func indexPath(base: in String, i: in Int): String = base + "[" + i.toString() + "]"

func hasKey(fields: in List[JsonField], name: in String): Bool {
  for f in fields {
    if f.name == name {
      return true
    }
  }
  false
}

func keyValue(fields: in List[JsonField], name: in String): Option[JsonValue] {
  var found: Option[JsonValue] = None
  for f in fields {
    if f.name == name {
      found = Some(value = f.value)
    }
  }
  found
}

/// The string member `name`, reporting a missing or wrongly typed member.
func requireString(
  fields: in List[JsonField], base: in String, name: in String, acc: in List[ManifestProblem]
): Option[String] {
  match keyValue(fields, name) {
    case None -> {
      problem(acc, base, "missing required field \"" + name + "\"")
      None
    }
    case Some(v) -> match v {
      case JString(s) -> Some(value = s)
      case _ -> {
        problem(acc, fieldPath(base, name), "expected a string, found " + kindName(v))
        None
      }
    }
  }
}

func checkPoint(v: in JsonValue, at: in String, seen: in List[String], acc: in List[ManifestProblem]): Unit {
  match v {
    case JObject(fields) -> {
      match requireString(fields, at, "point", acc) {
        case Some(name) -> {
          if not isQualifiedName(name) {
            problem(acc, fieldPath(at, "point"), "\"" + name + "\" is not a package-qualified interface name")
          } else if listContains(seen, name) {
            problem(acc, fieldPath(at, "point"), "point \"" + name + "\" is listed twice")
          } else {
            seen.add(name)
          }
        }
        case None -> ()
      }
      match requireString(fields, at, "version", acc) {
        case Some(ver) -> {
          if not isMajorMinor(ver) {
            problem(acc, fieldPath(at, "version"), "\"" + ver + "\" is not a major.minor version")
          }
        }
        case None -> ()
      }
    }
    case _ -> problem(acc, at, "expected an object, found " + kindName(v))
  }
}

func checkCapabilityList(
  fields: in List[JsonField],
  base: in String,
  listName: in String,
  seen: in List[String],
  acc: in List[ManifestProblem],
): Unit {
  match keyValue(fields, listName) {
    case None -> ()
    case Some(lv) -> match lv {
      case JArray(items) -> {
        var i = 0
        while i < items.count {
          val at = indexPath(fieldPath(base, listName), i)
          match items[i] {
            case JObject(entryFields) -> {
              match requireString(entryFields, at, "name", acc) {
                case Some(name) -> {
                  if not isQualifiedName(name) {
                    problem(acc, fieldPath(at, "name"), "\"" + name + "\" is not a package-qualified interface name")
                  } else if listContains(seen, name) {
                    problem(acc, fieldPath(at, "name"), "capability \"" + name + "\" is requested twice")
                  } else {
                    seen.add(name)
                  }
                }
                case None -> ()
              }
            }
            case _ -> problem(acc, at, "expected an object, found " + kindName(items[i]))
          }
          i = i + 1
        }
      }
      case JNull -> ()
      case _ -> problem(acc, fieldPath(base, listName), "expected an array, found " + kindName(lv))
    }
  }
}

func checkCapabilities(fields: in List[JsonField], acc: in List[ManifestProblem]): Unit {
  match keyValue(fields, "capabilities") {
    case None -> ()
    case Some(cv) -> match cv {
      case JObject(capFields) -> {
        val seen: List[String] = newList()
        checkCapabilityList(capFields, "capabilities", "required", seen, acc)
        checkCapabilityList(capFields, "capabilities", "optional", seen, acc)
      }
      // Absent or null means no capabilities, as `Std.Plugin` reads it.
      case JNull -> ()
      case _ -> problem(acc, "capabilities", "expected an object, found " + kindName(cv))
    }
  }
}

func checkPayloadFile(dir: in String, rel: in String, at: in String, acc: in List[ManifestProblem]): Unit {
  if not isArtifactRelativePath(rel) {
    problem(acc, at, "\"" + rel + "\" must be a relative path inside the plugin directory, written with '/'")
  } else if not File.fileExists(Path.join(dir, rel)) {
    problem(acc, at, "file \"" + rel + "\" does not exist in the plugin directory")
  }
}

/// The `command` array of a process payload as strings, or None after
/// reporting what is wrong with it.
func commandOf(fields: in List[JsonField], at: in String, acc: in List[ManifestProblem]): Option[List[String]] {
  match keyValue(fields, "command") {
    case None -> {
      problem(acc, at, "missing required field \"command\"")
      None
    }
    case Some(cv) -> match cv {
      case JArray(items) -> {
        if items.count == 0 {
          problem(acc, fieldPath(at, "command"), "the command must not be empty")
          return None
        }
        val parts: List[String] = newList()
        var ok = true
        var i = 0
        while i < items.count {
          match items[i] {
            case JString(s) -> {
              if s.length == 0 {
                problem(acc, indexPath(fieldPath(at, "command"), i), "a command element must not be empty")
                ok = false
              }
              parts.add(s)
            }
            case _ -> {
              problem(acc, indexPath(fieldPath(at, "command"), i), "expected a string, found " + kindName(items[i]))
              ok = false
            }
          }
          i = i + 1
        }
        if ok {
          Some(value = parts)
        } else {
          None
        }
      }
      case _ -> {
        problem(acc, fieldPath(at, "command"), "expected an array, found " + kindName(cv))
        None
      }
    }
  }
}

func checkRuntimeCommand(
  dir: in String,
  runtime: in String,
  cmd: in List[String],
  at: in String,
  acc: in List[ManifestProblem],
): Unit {
  val launcher = if runtime == "dotnet" { "dotnet" } else { "java" }
  val verb = if runtime == "dotnet" { "exec" } else { "-jar" }
  val ext = if runtime == "dotnet" { ".dll" } else { ".jar" }
  if cmd.count < 3 or cmd[0] != launcher or cmd[1] != verb {
    problem(
      acc,
      fieldPath(at, "command"),
      "a " + runtime + " payload's command must start with [\"" + launcher + "\", \"" + verb + "\", \"<file" + ext +
        ">\"]"
    )
    return
  }
  if not Str.endsWith(cmd[2], ext) {
    problem(acc, indexPath(fieldPath(at, "command"), 2), "expected a " + ext + " file, found \"" + cmd[2] + "\"")
    return
  }
  checkPayloadFile(dir, cmd[2], indexPath(fieldPath(at, "command"), 2), acc)
}

/// The file suffix of a trusted library: `.dll` for dotnet, `.jar` for the
/// JVM, and the operating system's shared-library suffix for a native one.
pub func trustedLibrarySuffix(runtimeOrOs: in String): String {
  if runtimeOrOs == "dotnet" or runtimeOrOs == "windows" {
    ".dll"
  } else if runtimeOrOs == "jvm" {
    ".jar"
  } else if runtimeOrOs == "macos" {
    ".dylib"
  } else {
    ".so"
  }
}

/// Checks a trusted payload (docs/69 §10): a `library` file, with a
/// `runtime` (`dotnet`, `jvm`) or an `os` and `arch` (a native shared
/// library).  Returns its kind key, "" when it is malformed.
func checkTrustedPayload(
  dir: in String, fields: in List[JsonField], at: in String, acc: in List[ManifestProblem]
): String {
  val library = match requireString(fields, at, "library", acc) { case Some(l) -> l; case None -> return "" }
  if hasKey(fields, "command") or hasKey(fields, "module") {
    problem(acc, at, "a trusted payload names a \"library\", not a \"command\" or \"module\"")
    return ""
  }
  if hasKey(fields, "runtime") {
    if hasKey(fields, "os") or hasKey(fields, "arch") {
      problem(acc, at, "a payload names either a \"runtime\" or an \"os\" and \"arch\", not both")
      return ""
    }
    val runtime = match requireString(fields, at, "runtime", acc) { case Some(r) -> r; case None -> return "" }
    if runtime != "dotnet" and runtime != "jvm" {
      problem(acc, fieldPath(at, "runtime"), "unknown runtime \"" + runtime + "\" (expected \"dotnet\" or \"jvm\")")
      return ""
    }
    val ext = trustedLibrarySuffix(runtime)
    if not Str.endsWith(library, ext) {
      problem(acc, fieldPath(at, "library"), "expected a " + ext + " file, found \"" + library + "\"")
      return ""
    }
    checkPayloadFile(dir, library, fieldPath(at, "library"), acc)
    return "trusted " + runtime
  }
  val os = match requireString(fields, at, "os", acc) { case Some(o) -> o; case None -> return "" }
  val arch = match requireString(fields, at, "arch", acc) { case Some(a) -> a; case None -> return "" }
  if os != "linux" and os != "macos" and os != "windows" {
    problem(acc, fieldPath(at, "os"), "unknown os \"" + os + "\" (expected \"linux\", \"macos\" or \"windows\")")
    return ""
  }
  if arch != "x86_64" and arch != "aarch64" {
    problem(acc, fieldPath(at, "arch"), "unknown arch \"" + arch + "\" (expected \"x86_64\" or \"aarch64\")")
    return ""
  }
  val ext = trustedLibrarySuffix(os)
  if not Str.endsWith(library, ext) {
    problem(acc, fieldPath(at, "library"), "a " + os + " library is a " + ext + " file, found \"" + library + "\"")
    return ""
  }
  checkPayloadFile(dir, library, fieldPath(at, "library"), acc)
  "trusted native:" + os + "/" + arch
}

/// Checks one payload and returns the key that identifies its kind
/// (`dotnet`, `jvm`, `native:<os>/<arch>`, `wasm`, `trusted dotnet`,
/// `trusted jvm` or `trusted native:<os>/<arch>`), "" when it is malformed.
func checkPayload(dir: in String, v: in JsonValue, at: in String, acc: in List[ManifestProblem]): String {
  val fields = match v {
    case JObject(fs) -> fs
    case _ -> {
      problem(acc, at, "expected an object, found " + kindName(v))
      return ""
    }
  }
  val mode = match requireString(fields, at, "mode", acc) { case Some(m) -> m; case None -> return "" }
  if mode == "wasm" {
    match requireString(fields, at, "module", acc) {
      case Some(m) -> {
        if not Str.endsWith(m, ".wasm") {
          problem(acc, fieldPath(at, "module"), "expected a .wasm file, found \"" + m + "\"")
          return ""
        }
        checkPayloadFile(dir, m, fieldPath(at, "module"), acc)
        return "wasm"
      }
      case None -> return ""
    }
  }
  if mode == "trusted" {
    return checkTrustedPayload(dir, fields, at, acc)
  }
  if mode != "process" {
    problem(
      acc,
      fieldPath(at, "mode"),
      "unknown payload mode \"" + mode + "\" (expected \"process\", \"wasm\" or \"trusted\")"
    )
    return ""
  }
  val cmd = match commandOf(fields, at, acc) { case Some(c) -> c; case None -> return "" }
  if hasKey(fields, "runtime") {
    if hasKey(fields, "os") or hasKey(fields, "arch") {
      problem(acc, at, "a payload names either a \"runtime\" or an \"os\" and \"arch\", not both")
      return ""
    }
    val runtime = match requireString(fields, at, "runtime", acc) { case Some(r) -> r; case None -> return "" }
    if runtime != "dotnet" and runtime != "jvm" {
      problem(acc, fieldPath(at, "runtime"), "unknown runtime \"" + runtime + "\" (expected \"dotnet\" or \"jvm\")")
      return ""
    }
    checkRuntimeCommand(dir, runtime, cmd, at, acc)
    return runtime
  }
  val os = match requireString(fields, at, "os", acc) { case Some(o) -> o; case None -> return "" }
  val arch = match requireString(fields, at, "arch", acc) { case Some(a) -> a; case None -> return "" }
  if os != "linux" and os != "macos" and os != "windows" {
    problem(acc, fieldPath(at, "os"), "unknown os \"" + os + "\" (expected \"linux\", \"macos\" or \"windows\")")
    return ""
  }
  if arch != "x86_64" and arch != "aarch64" {
    problem(acc, fieldPath(at, "arch"), "unknown arch \"" + arch + "\" (expected \"x86_64\" or \"aarch64\")")
    return ""
  }
  checkPayloadFile(dir, cmd[0], indexPath(fieldPath(at, "command"), 0), acc)
  "native:" + os + "/" + arch
}

func checkPayloads(dir: in String, fields: in List[JsonField], acc: in List[ManifestProblem]): Unit {
  match keyValue(fields, "payloads") {
    case None -> problem(acc, "", "missing required field \"payloads\"")
    case Some(pv) -> match pv {
      case JArray(items) -> {
        if items.count == 0 {
          problem(acc, "payloads", "a plugin needs at least one payload")
        }
        val kinds: List[String] = newList()
        var i = 0
        while i < items.count {
          val at = indexPath("payloads", i)
          val kind = checkPayload(dir, items[i], at, acc)
          if kind.length > 0 {
            if listContains(kinds, kind) {
              problem(acc, at, "a second " + kind + " payload; each runtime, os/arch pair and wasm appears once in each mode")
            } else {
              kinds.add(kind)
            }
          }
          i = i + 1
        }
      }
      case _ -> problem(acc, "payloads", "expected an array, found " + kindName(pv))
    }
  }
}

func trimTrailingSeparators(dir: in String): String {
  var d = dir
  while d.length > 1 and (Str.endsWith(d, "/") or Str.endsWith(d, "\\")) {
    d = Str.substring(d, 0, d.length - 1)
  }
  d
}

/// Validates a manifest document.  An empty list means it is valid.
pub func checkManifestText(text: in String, mode: in CheckMode): List[ManifestProblem] {
  val acc: List[ManifestProblem] = newList()
  val doc = match parseValue(text) {
    case Ok(v) -> v
    case Err(e) -> {
      problem(acc, "", "not valid JSON: " + JsonParseError.message(e))
      return acc
    }
  }
  val fields = match doc {
    case JObject(fs) -> fs
    case _ -> {
      problem(acc, "", "expected a JSON object, found " + kindName(doc))
      return acc
    }
  }
  match keyValue(fields, "schema") {
    case None -> problem(acc, "", "missing required field \"schema\"")
    case Some(sv) -> match sv {
      case JInt(n) -> {
        if n != 1 {
          problem(acc, "schema", "unsupported schema " + n.toString() + " (this lyric reads schema 1)")
        }
      }
      case _ -> problem(acc, "schema", "expected the number 1, found " + kindName(sv))
    }
  }
  val id = match requireString(fields, "", "id", acc) {
    case Some(s) -> {
      if not isPluginId(s) {
        problem(
          acc,
          "id",
          "\"" + s + "\" is not a plugin id (letters, digits, '.', '-' and '_', starting with a letter or digit)"
        )
      }
      s
    }
    case None -> ""
  }
  val version = match requireString(fields, "", "version", acc) {
    case Some(s) -> {
      if not isPluginVersion(s) {
        problem(acc, "version", "\"" + s + "\" is not a version (major.minor.patch)")
      }
      s
    }
    case None -> ""
  }
  match requireString(fields, "", "publisher", acc) {
    case Some(s) -> {
      if Str.trim(s).length == 0 {
        problem(acc, "publisher", "the publisher must not be empty")
      }
    }
    case None -> ()
  }
  match keyValue(fields, "points") {
    case None -> problem(acc, "", "missing required field \"points\"")
    case Some(pv) -> match pv {
      case JArray(items) -> {
        if items.count == 0 {
          problem(acc, "points", "a plugin implements at least one point")
        }
        val seen: List[String] = newList()
        var i = 0
        while i < items.count {
          checkPoint(items[i], indexPath("points", i), seen, acc)
          i = i + 1
        }
      }
      case _ -> problem(acc, "points", "expected an array, found " + kindName(pv))
    }
  }
  checkCapabilities(fields, acc)
  match mode {
    case ProbeCheck -> {
      if hasKey(fields, "payloads") {
        problem(acc, "payloads", "a manifest probe must not list payloads; lyric plugin pack adds them")
      }
    }
    case ArtifactCheck(dir) -> {
      checkPayloads(dir, fields, acc)
      if id.length > 0 and version.length > 0 {
        val expected = id + "-" + version
        val actual = Path.basename(trimTrailingSeparators(dir))
        if actual != expected {
          problem(
            acc,
            "",
            "the plugin directory is named \"" + actual + "\"; an artifact directory is named <id>-<version>, \"" + expected +
              "\""
          )
        }
      }
    }
  }
  acc
}

/// Validates the artifact directory `dir` (its `plugin.json` and payloads).
pub func checkArtifactDir(dir: in String): List[ManifestProblem] {
  if not File.dirExists(dir) {
    val acc: List[ManifestProblem] = newList()
    problem(acc, "", "not a directory")
    return acc
  }
  val manifestPath = Path.join(dir, "plugin.json")
  match File.readText(manifestPath) {
    case Ok(text) -> checkManifestText(text, ArtifactCheck(dir = dir))
    case Err(_) -> {
      val acc: List[ManifestProblem] = newList()
      problem(acc, "", "no plugin.json found")
      acc
    }
  }
}

/// The string member `name` of a manifest that has passed
/// `checkManifestText` ("" when it is absent).
pub func manifestString(text: in String, name: in String): String {
  match parseValue(text) {
    case Ok(doc) -> match getString(doc, name) { case Some(s) -> s; case None -> "" }
    case Err(_) -> ""
  }
}

// ── Payloads ─────────────────────────────────────────────────────────────────
func strArray(parts: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for p in parts {
    items.add(JString(value = p))
  }
  JArray(items = items)
}

func member(name: in String, value: in JsonValue): JsonField = JsonField(name = name, value = value)

/// `{"mode": "process", "runtime": "dotnet", "command": ["dotnet", "exec", dll]}`.
pub func dotnetPayload(dll: in String): String {
  val cmd: List[String] = newList()
  cmd.add("dotnet")
  cmd.add("exec")
  cmd.add(dll)
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "process")))
  fields.add(member("runtime", JString(value = "dotnet")))
  fields.add(member("command", strArray(cmd)))
  writeValue(JObject(fields = fields))
}

/// `{"mode": "process", "runtime": "jvm", "command": ["java", "-jar", jar]}`.
pub func jvmPayload(jar: in String): String {
  val cmd: List[String] = newList()
  cmd.add("java")
  cmd.add("-jar")
  cmd.add(jar)
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "process")))
  fields.add(member("runtime", JString(value = "jvm")))
  fields.add(member("command", strArray(cmd)))
  writeValue(JObject(fields = fields))
}

/// `{"mode": "process", "os": os, "arch": arch, "command": [exe]}`.
pub func nativePayload(os: in String, arch: in String, exe: in String): String {
  val cmd: List[String] = newList()
  cmd.add(exe)
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "process")))
  fields.add(member("os", JString(value = os)))
  fields.add(member("arch", JString(value = arch)))
  fields.add(member("command", strArray(cmd)))
  writeValue(JObject(fields = fields))
}

/// `{"mode": "wasm", "module": wasmFile}`.
pub func wasmPayload(wasmFile: in String): String {
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "wasm")))
  fields.add(member("module", JString(value = wasmFile)))
  writeValue(JObject(fields = fields))
}

/// `{"mode": "trusted", "runtime": runtime, "library": file}`: the dotnet
/// assembly or JVM jar a host of that runtime may load into its own process.
pub func trustedManagedPayload(runtime: in String, file: in String): String {
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "trusted")))
  fields.add(member("runtime", JString(value = runtime)))
  fields.add(member("library", JString(value = file)))
  writeValue(JObject(fields = fields))
}

/// `{"mode": "trusted", "os": os, "arch": arch, "library": file}`: a
/// `--shape plugin` shared library.
pub func trustedNativePayload(os: in String, arch: in String, file: in String): String {
  val fields: List[JsonField] = newList()
  fields.add(member("mode", JString(value = "trusted")))
  fields.add(member("os", JString(value = os)))
  fields.add(member("arch", JString(value = arch)))
  fields.add(member("library", JString(value = file)))
  writeValue(JObject(fields = fields))
}

/// A native payload's `os` and `arch` spellings.
pub record OsArch {
  os: String
  arch: String
}

/// The manifest `os` and `arch` of an LLVM target triple, or an error naming
/// the triple when the manifest format has no spelling for it.
pub func osArchOfTriple(triple: in String): Result[OsArch, String] {
  val parts = Str.split(triple, "-")
  if parts.length < 2 {
    return Err(error = "cannot read the target triple \"" + triple + "\"")
  }
  val cpu = parts[0]
  val arch = if cpu == "x86_64" or cpu == "amd64" {
    "x86_64"
  } else if cpu == "aarch64" or cpu == "arm64" {
    "aarch64"
  } else {
    ""
  }
  if arch.length == 0 {
    return Err(error = "plugin payloads support x86_64 and aarch64; the target triple \"" + triple + "\" is neither")
  }
  val os = if Str.contains(triple, "linux") {
    "linux"
  } else if Str.contains(triple, "apple") or Str.contains(triple, "darwin") or Str.contains(triple, "macos") {
    "macos"
  } else if Str.contains(triple, "windows") or Str.contains(triple, "win32") {
    "windows"
  } else {
    ""
  }
  if os.length == 0 {
    return Err(
      error = "plugin payloads support linux, macos and windows; the target triple \"" + triple +
        "\" is none of them"
    )
  }
  Ok(value = OsArch(os = os, arch = arch))
}

// ── JSON text ────────────────────────────────────────────────────────────────
/// `manifest` (a JSON object without `payloads`) with a `payloads` member
/// whose elements are the JSON texts in `payloads`, appended last.  The
/// manifest's own text is kept byte for byte.
pub func withPayloads(manifest: in String, payloads: in List[String]): String {
  val trimmed = Str.trim(manifest)
  val body = Str.trim(Str.substring(trimmed, 0, trimmed.length - 1))
  val sep = if Str.endsWith(body, "{") { "" } else { "," }
  body + sep + "\"payloads\":[" + Str.joinList(",", payloads) + "]}"
}

func spaces(n: in Int): String = Str.repeat(" ", n)

/// Re-indents JSON text: one member or element per line, two spaces per
/// level, `": "` after names.  Works on the text, so numbers and strings are
/// copied exactly; whitespace outside strings is replaced.
pub func prettyJson(text: in String): String {
  val sb: List[String] = newList()
  var depth = 0
  var inString = false
  var escaped = false
  var i = 0
  while i < text.length {
    val ch = Str.substring(text, i, 1)
    val c = Str.codeUnitAt(text, i)
    i = i + 1
    if inString {
      sb.add(ch)
      if escaped {
        escaped = false
      } else if c == 92 {
        escaped = true
      } else if c == 34 {
        inString = false
      }
      continue
    }
    if c == 32 or c == 9 or c == 10 or c == 13 {
      continue
    }
    if c == 34 {
      inString = true
      sb.add(ch)
    } else if c == 123 or c == 91 {
      // An empty container stays on one line.
      var j = i
      while j < text.length and (Str.codeUnitAt(text, j) == 32 or Str.codeUnitAt(text, j) == 9 or Str.codeUnitAt(text, j) == 10 or Str.codeUnitAt(text, j) == 13) {
        j = j + 1
      }
      val closer = if c == 123 { 125 } else { 93 }
      if j < text.length and Str.codeUnitAt(text, j) == closer {
        sb.add(ch)
        sb.add(Str.substring(text, j, 1))
        i = j + 1
      } else {
        depth = depth + 1
        sb.add(ch)
        sb.add("\n")
        sb.add(spaces(depth * 2))
      }
    } else if c == 125 or c == 93 {
      depth = depth - 1
      sb.add("\n")
      sb.add(spaces(depth * 2))
      sb.add(ch)
    } else if c == 44 {
      sb.add(",\n")
      sb.add(spaces(depth * 2))
    } else if c == 58 {
      sb.add(": ")
    } else {
      sb.add(ch)
    }
  }
  Str.joinList("", sb) + "\n"
}
