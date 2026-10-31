//! plugin_expand_self_test.l — exercises `Lyric.PluginExpand` (D207).
//!
//!   lyric test lyric-compiler/lyric/plugin_expand_self_test.l
//!
//! The compiler-package imports resolve by linking the stage-1 compiler DLLs
//! as restored dependencies, like `wire_expand_self_test.l`.
//!
//! Covers, at the AST level: every K0001-K0014 diagnostic on a minimal bad
//! input, a clean expansion of a representative API package and of a plugin
//! package that implements its point, the names and signatures of the
//! generated items, the moved `requires:` clause, the injected imports, and
//! (through `Msil.Bridge.checkProjectTypes`) that the expanded API and plugin
//! packages type-check.  The runtime encoding is covered by
//! `plugin_codec_self_test.l` on dotnet and the JVM; the component items
//! (`expandFileForComponent`) are checked here and built and run by
//! `llvm_wasm32_plugin_component_self_test.l`.
@test_module
package Lyric.PluginExpandSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.PluginExpand
import Lyric.Fmt as Fmt
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.RestoredPackages
import Lyric.Emitter as Emitter
import Msil.Bridge

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures.
// ─────────────────────────────────────────────────────────────────────────────
func apiSource(): String {
  "package Acme.Editor\n" + "\n" + "@plugin_handle\n" + "pub type DocId = Long\n" + "\n" + "pub enum Severity {\n" +
    "  case Info\n" +
    "  case Warning\n" +
    "}\n" +
    "\n" +
    "pub record Position {\n" +
    "  line: Int\n" +
    "  col: Int\n" +
    "}\n" +
    "\n" +
    "pub union Edit {\n" +
    "  case Insert(at: Position, text: String)\n" +
    "  case Delete(start: Position, stop: Position)\n" +
    "  case Clear\n" +
    "}\n" +
    "\n" +
    "pub record Note {\n" +
    "  doc: DocId\n" +
    "  severity: Severity\n" +
    "  tags: Map[String, Long]\n" +
    "  data: List[Byte]\n" +
    "  raw: slice[Byte]\n" +
    "  extra: Option[String]\n" +
    "  edits: List[Edit]\n" +
    "  pair: (Int, Bool)\n" +
    "  outcome: Result[Int, String]\n" +
    "  ratio: Double\n" +
    "  count: UInt\n" +
    "  big: ULong\n" +
    "  initial: Char\n" +
    "}\n" +
    "\n" +
    "pub exposed record WorkspaceReadGrant {\n" +
    "  roots: List[String]\n" +
    "}\n" +
    "\n" +
    "pub func underRoot(roots: in List[String], path: in String): Bool {\n" +
    "  for r in roots {\n" +
    "    if path.startsWith(r) {\n" +
    "      return true\n" +
    "    }\n" +
    "  }\n" +
    "  false\n" +
    "}\n" +
    "\n" +
    "@capability(grant = WorkspaceReadGrant)\n" +
    "pub interface WorkspaceRead {\n" +
    "  func readFile(path: in String): Result[String, String]\n" +
    "    requires: underRoot(grant.roots, path)\n" +
    "    requires: path.length > 0\n" +
    "}\n" +
    "\n" +
    "@capability\n" +
    "pub interface Notify {\n" +
    "  func notify(message: in String, severity: in Severity): Result[Unit, String]\n" +
    "}\n" +
    "\n" +
    "pub record EditorContributions {\n" +
    "  commands: List[String]\n" +
    "}\n" +
    "\n" +
    "@plugin_point(version = \"1.2\", contributions = EditorContributions, allows(WorkspaceRead, Notify))\n" +
    "pub interface EditorExtension {\n" +
    "  func onSave(doc: in DocId, text: in String): Result[List[Edit], String]\n" +
    "  func inspect(note: in Note): Result[Option[Note], Severity]\n" +
    "}\n"
}

func pluginSource(): String {
  "package Acme.GitTools\n" + "\n" + "import Acme.Editor\n" + "\n" +
    "@plugin(id = \"acme.git-tools\", version = \"0.4.1\", publisher = \"acme\", implements(EditorExtension))\n" +
    "pub record GitTools {\n" +
    "  workspace: WorkspaceReadClient\n" +
    "  notifier: Option[NotifyClient]\n" +
    "  var saves: Int = 0\n" +
    "}\n" +
    "\n" +
    "impl EditorExtension for GitTools {\n" +
    "  func onSave(doc: in DocId, text: in String): Result[List[Edit], String] {\n" +
    "    val edits: List[Edit] = newList()\n" +
    "    Ok(value = edits)\n" +
    "  }\n" +
    "\n" +
    "  func inspect(note: in Note): Result[Option[Note], Severity] {\n" +
    "    Ok(value = Some(value = note))\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "@plugin_contributions(EditorExtension)\n" +
    "func gitContributions(): EditorContributions {\n" +
    "  val cmds: List[String] = newList()\n" +
    "  cmds.add(\"git.blame\")\n" +
    "  EditorContributions(commands = cmds)\n" +
    "}\n" +
    "\n" +
    "@plugin_request(WorkspaceRead)\n" +
    "func workspaceRequest(): WorkspaceReadGrant {\n" +
    "  val roots: List[String] = newList()\n" +
    "  roots.add(\"\\\${workspace}\")\n" +
    "  WorkspaceReadGrant(roots = roots)\n" +
    "}\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func expandOne(src: in String): PluginExpandResult {
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "fixture parses")
  val pkgs: Map[String, PluginPackage] = newMap()
  collectPluginPackage(pr.file, pkgs)
  expandFile(pr.file, pkgs)
}

func expandSecond(first: in String, second: in String): PluginExpandResult {
  val a = parse(first)
  val b = parse(second)
  assertEqualInt(a.diagnostics.count + b.diagnostics.count, 0, "fixtures parse")
  val pkgs: Map[String, PluginPackage] = newMap()
  collectPluginPackage(a.file, pkgs)
  collectPluginPackage(b.file, pkgs)
  expandFile(b.file, pkgs)
}

func hasDiag(r: in PluginExpandResult, code: in String): Bool {
  for d in r.diagnostics {
    if d.code == code {
      return true
    }
  }
  false
}

func diagText(r: in PluginExpandResult): String {
  var s = ""
  for d in r.diagnostics {
    s = s + d.code + " " + d.message + "\n"
  }
  s
}

func expectDiag(src: in String, code: in String, label: in String): Unit {
  val r = expandOne(src)
  assertTrue(hasDiag(r, code), label + ": expected " + code + ", got:\n" + diagText(r))
}

func expectClean(r: in PluginExpandResult, label: in String): Unit {
  assertEqualInt(r.diagnostics.count, 0, label + ": unexpected diagnostics:\n" + diagText(r))
}

func funcNamed(r: in PluginExpandResult, name: in String): Option[FunctionDecl] {
  for it in r.file.items {
    match it.kind {
      case IFunc(fn) -> {
        if fn.name == name {
          return Some(value = fn)
        }
      }
      case _ -> ()
    }
  }
  None
}

func sigOf(fn: in FunctionDecl): String {
  var s = fn.name + "("
  var i = 0
  for p in fn.params {
    if i > 0 {
      s = s + ", "
    }
    s = s + p.name + ": " + Fmt.typeStr(p.ty)
    i = i + 1
  }
  s = s + ")"
  match fn.ret {
    case Some(t) -> s + ": " + Fmt.typeStr(t)
    case None -> s
  }
}

func expectFunc(r: in PluginExpandResult, name: in String, sig: in String): Unit {
  match funcNamed(r, name) {
    case Some(fn) -> assertEqual(sigOf(fn), sig, "signature of " + name)
    case None -> panic("no generated function " + name)
  }
}

func hasRecord(r: in PluginExpandResult, name: in String): Bool {
  for it in r.file.items {
    match it.kind {
      case IRecord(d) -> {
        if d.name == name {
          return true
        }
      }
      case _ -> ()
    }
  }
  false
}

func implMethods(r: in PluginExpandResult, iface: in String, target: in String): List[String] {
  val names: List[String] = newList()
  for it in r.file.items {
    match it.kind {
      case IImpl(d) -> {
        val tgt = match d.target.kind { case TRef(p) -> modulePathJoin(p.segments); case _ -> "" }
        if modulePathJoin(d.iface.head.segments) == iface and tgt == target {
          for m in d.members {
            match m {
              case IMplFunc(fn) -> names.add(fn.name)
              case _ -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  names
}

func hasImport(r: in PluginExpandResult, path: in String): Bool {
  for im in r.file.imports {
    if modulePathJoin(im.path.segments) == path {
      return true
    }
  }
  false
}

func anyAnnotationNamed(r: in PluginExpandResult, name: in String): Bool {
  for it in r.file.items {
    for a in it.annotations {
      if modulePathJoin(a.name.segments) == name {
        return true
      }
    }
  }
  false
}

// The smallest point and capability, for the diagnostic tests.
func head(): String {
  "package P\n\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// Clean expansion of the API package.
// ─────────────────────────────────────────────────────────────────────────────
test "an API package expands without diagnostics" {
  expectClean(expandOne(apiSource()), "api")
}

test "codecs for every reached boundary type" {
  val r = expandOne(apiSource())
  for t in ["DocId", "Severity", "Position", "Edit", "Note", "WorkspaceReadGrant", "EditorContributions"] {
    expectFunc(r, "pluginEncode" + t, "pluginEncode" + t + "(v: " + t + "): JsonValue")
    expectFunc(r, "pluginDecode" + t, "pluginDecode" + t + "(j: JsonValue): Result[" + t + ", String]")
  }
}

test "capability items" {
  val r = expandOne(apiSource())
  assertTrue(hasRecord(r, "WorkspaceReadClient"), "WorkspaceReadClient")
  assertTrue(hasRecord(r, "WorkspaceReadServer"), "WorkspaceReadServer")
  assertTrue(hasRecord(r, "NotifyClient"), "NotifyClient")
  expectFunc(
    r,
    "WorkspaceReadClient.readFile",
    "WorkspaceReadClient.readFile(__stub: WorkspaceReadClient, path: String): Result[String, CallError[String]]"
  )
  expectFunc(
    r,
    "NotifyClient.notify",
    "NotifyClient.notify(__stub: NotifyClient, message: String, severity: Severity): Result[Unit, CallError[String]]"
  )
  expectFunc(r, "workspaceReadProvider", "workspaceReadProvider(target: WorkspaceRead): CapabilityProvider")
  expectFunc(r, "workspaceReadCapabilityInfo", "workspaceReadCapabilityInfo(): CapabilityInfo")
  expectFunc(r, "notifyCapabilityInfo", "notifyCapabilityInfo(): CapabilityInfo")
  val served = implMethods(r, "CapabilityProvider", "WorkspaceReadServer")
  assertTrue(served.contains("info") and served.contains("serve"), "impl CapabilityProvider for WorkspaceReadServer")
  assertTrue(hasRecord(r, "WorkspaceReadAs"), "WorkspaceReadAs")
  expectFunc(
    r,
    "WorkspaceReadAs.readFile",
    "WorkspaceReadAs.readFile(__stub: WorkspaceReadAs, path: String): Result[String, CallError[String]]"
  )
}

test "point items" {
  val r = expandOne(apiSource())
  assertTrue(hasRecord(r, "EditorExtensionRemote"), "EditorExtensionRemote")
  assertTrue(hasRecord(r, "EditorExtensionContribution"), "EditorExtensionContribution")
  expectFunc(
    r,
    "EditorExtensionRemote.onSave",
    "EditorExtensionRemote.onSave(__stub: EditorExtensionRemote, doc: DocId, text: String): Result[List[Edit], CallError[String]]"
  )
  expectFunc(
    r,
    "EditorExtensionRemote.inspect",
    "EditorExtensionRemote.inspect(__stub: EditorExtensionRemote, note: Note): Result[Option[Note], CallError[Severity]]"
  )
  expectFunc(r, "editorExtensionRemotes", "editorExtensionRemotes(host: PluginHost): List[EditorExtensionRemote]")
  expectFunc(
    r,
    "editorExtensionContributions",
    "editorExtensionContributions(host: PluginHost): List[EditorExtensionContribution]"
  )
  expectFunc(
    r,
    "editorExtensionContributionIssues",
    "editorExtensionContributionIssues(host: PluginHost): List[PluginLoadIssue]"
  )
  expectFunc(r, "editorExtensionPointInfo", "editorExtensionPointInfo(): PluginPointInfo")
  expectFunc(
    r,
    "pluginDispatchEditorExtension",
    "pluginDispatchEditorExtension(target: EditorExtension, method: String, params: Option[JsonValue]): Result[JsonValue, RpcError]"
  )
}

test "a grant guard moves from the capability to its server" {
  val r = expandOne(apiSource())
  for it in r.file.items {
    match it.kind {
      case IInterface(d) -> {
        if d.name == "WorkspaceRead" {
          for m in d.members {
            match m {
              case IMSig(sig) -> {
                assertEqualInt(sig.contracts.count, 1, "only the clause without grant stays on readFile")
              }
              case _ -> ()
            }
          }
        }
      }
      case _ -> ()
    }
  }
  match funcNamed(r, "__pluginServe_WorkspaceRead_readFile") {
    case Some(fn) -> assertEqualInt(fn.params.count, 3, "the server helper takes the grant")
    case None -> panic("no server helper for readFile")
  }
}

test "plugin annotations are consumed and the imports injected" {
  val r = expandOne(apiSource())
  for a in ["plugin_handle", "capability", "plugin_point"] {
    assertFalse(anyAnnotationNamed(r, a), "@" + a + " is stripped")
  }
  for p in ["Std.Core", "Std.Collections", "Std.JsonValue", "Std.JsonRpc", "Std.Plugin", "Std.Encoding"] {
    assertTrue(hasImport(r, p), "import " + p)
  }
}

test "a file without plugin annotations is untouched" {
  val src = "package Q\n\npub record R {\n  x: Int\n}\n"
  val r = expandOne(src)
  expectClean(r, "plain")
  assertEqualInt(r.file.items.count, 1, "no generated items")
  assertEqualInt(r.file.imports.count, 0, "no injected imports")
}

// ─────────────────────────────────────────────────────────────────────────────
// Clean expansion of the plugin package.
// ─────────────────────────────────────────────────────────────────────────────
test "a plugin package expands without diagnostics" {
  expectClean(expandSecond(apiSource(), pluginSource()), "plugin")
}

test "plugin server items" {
  val r = expandSecond(apiSource(), pluginSource())
  assertTrue(hasRecord(r, "GitToolsServer"), "GitToolsServer")
  val ms = implMethods(r, "PluginServer", "GitToolsServer")
  for m in ["describe", "attach", "pointMethods", "dispatch"] {
    assertTrue(ms.contains(m), "PluginServer." + m)
  }
  expectFunc(r, "main", "main(): Int")
}

// ─────────────────────────────────────────────────────────────────────────────
// The expanded packages type-check.
// ─────────────────────────────────────────────────────────────────────────────
func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, sources = [source])
}

func errorsOf(located: in List[DiagUtil.LocatedDiagnostic]): String {
  var s = ""
  for d in located {
    if d.diagnostic.severity == DiagError {
      s = s + d.path + ": " + d.diagnostic.code + " " + d.diagnostic.message + "\n"
    }
  }
  s
}

test "the expanded API and plugin packages type-check" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(ProjectPackagePayload(name = "Acme.Editor", sources = [apiSource()], paths = ["editor.l"]))
  packages.add(ProjectPackagePayload(name = "Acme.GitTools", sources = [pluginSource()], paths = ["gittools.l"]))
  val none: List[String] = newList()
  val noArts: List[SynthesisedArtifact] = newList()
  val noDeps: List[ProjectPackagePayload] = newList()
  val located = checkProjectTypes(packages, Emitter.findStdlibSources(), none, none, noArts, "0.1.0", noDeps, none)
  assertEqual(errorsOf(located), "", "type errors in the expanded packages")
}

// ─────────────────────────────────────────────────────────────────────────────
// K0001-K0012.
// ─────────────────────────────────────────────────────────────────────────────
test "K0001: a function-typed parameter" {
  expectDiag(
    head() + "@capability\npub interface C {\n  func f(g: in (Int) -> Int): Result[Int, String]\n}\n",
    "K0001",
    "function type"
  )
}

test "K0001: Option of Option" {
  expectDiag(
    head() + "@capability\npub interface C {\n  func f(): Result[Option[Option[Int]], String]\n}\n",
    "K0001",
    "Option[Option]"
  )
}

test "K0001: a Map with non-String keys" {
  expectDiag(
    head() + "@capability\npub interface C {\n  func f(m: in Map[Int, String]): Result[Int, String]\n}\n",
    "K0001",
    "Map[Int, _]"
  )
}

test "K0001: a distinct type that is not a handle" {
  expectDiag(
    head() + "pub type Id = Long\n\n@capability\npub interface C {\n  func f(i: in Id): Result[Int, String]\n}\n",
    "K0001",
    "plain distinct type"
  )
}

test "K0001: a field of a reached record" {
  expectDiag(
    head() +
      "pub record R {\n  f: (Int) -> Int\n}\n\n@capability\npub interface C {\n  func f(r: in R): Result[Int, String]\n}\n",
    "K0001",
    "record field"
  )
}

test "K0001: a type another source package does not use at a boundary" {
  val lib = "package Lib\n\npub record Shape {\n  sides: Int\n}\n"
  val app = "package App\n\nimport Lib\n\n@capability\npub interface C {\n  func f(s: in Shape): Result[Int, String]\n}\n"
  val r = expandSecond(lib, app)
  assertTrue(hasDiag(r, "K0001"), "unreached foreign type: " + diagText(r))
}

test "a type another package uses at its own boundary crosses" {
  val lib = "package Lib\n\npub record Shape {\n  sides: Int\n}\n\n@capability\npub interface Shapes {\n  func get(): Result[Shape, String]\n}\n"
  val app = "package App\n\nimport Lib\n\n@capability\npub interface C {\n  func f(s: in Shape): Result[Int, String]\n}\n"
  val r = expandSecond(lib, app)
  expectClean(r, "reached foreign type")
  match funcNamed(r, "__pluginServe_C_f") {
    case Some(_) -> ()
    case None -> panic("no server helper")
  }
}

test "K0002: allows names an interface that is not a capability" {
  expectDiag(
    head() +
      "pub interface Plain {\n  func g(): Int\n}\n\n@plugin_point(version = \"1.0\", allows(Plain))\npub interface Pt {\n  func f(): Result[Int, String]\n}\n",
    "K0002",
    "non-capability"
  )
}

func k3Source(fieldTy: in String): String {
  head() + "@capability\npub interface Cap {\n  func c(): Result[Int, String]\n}\n\n" +
    "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n  cap: " +
    fieldTy +
    "\n}\n\n" +
    "impl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n"
}

test "K0003: a capability no implemented point allows" {
  expectDiag(k3Source("CapClient"), "K0003", "unallowed capability")
}

test "K0004: a method that does not return Result" {
  expectDiag(head() + "@capability\npub interface C {\n  func f(): Int\n}\n", "K0004", "non-Result")
}

test "K0004: a generic method" {
  expectDiag(
    head() + "@capability\npub interface C {\n  func f[T](x: in T): Result[Int, String]\n}\n",
    "K0004",
    "generic method"
  )
}

test "K0005: @capability on a record" {
  expectDiag(head() + "@capability\npub record C {\n  x: Int\n}\n", "K0005", "record")
}

test "K0005: @plugin_handle over Int" {
  expectDiag(head() + "@plugin_handle\npub type H = Int\n", "K0005", "handle over Int")
}

test "K0005: a private plugin point" {
  expectDiag(
    head() + "@plugin_point(version = \"1.0\")\ninterface Pt {\n  func f(): Result[Int, String]\n}\n",
    "K0005",
    "private"
  )
}

test "K0005: @plugin on an interface" {
  expectDiag(
    head() + "@plugin(id = \"a\", version = \"1.0\", implements(Pt))\npub interface Pt {\n}\n",
    "K0005",
    "plugin on interface"
  )
}

test "K0006: a point without a version" {
  expectDiag(
    head() + "@plugin_point\npub interface Pt {\n  func f(): Result[Int, String]\n}\n",
    "K0006",
    "missing version"
  )
}

test "K0006: a version that is not major.minor" {
  expectDiag(
    head() + "@plugin_point(version = \"1\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n",
    "K0006",
    "bad version"
  )
}

test "K0006: an unknown argument" {
  expectDiag(
    head() + "@capability(colour = Red)\npub interface C {\n  func f(): Result[Int, String]\n}\n",
    "K0006",
    "unknown argument"
  )
}

test "K0006: a plugin without an id" {
  expectDiag(
    head() +
      "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n@plugin(version = \"1.0.0\", implements(Pt))\npub record X {\n}\n\nimpl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n",
    "K0006",
    "missing id"
  )
}

test "K0006: a plugin version that is not major.minor.patch" {
  expectDiag(
    head() +
      "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n@plugin(id = \"a\", version = \"1.2\", publisher = \"p\", implements(Pt))\npub record X {\n}\n\nimpl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n",
    "K0006",
    "two-part plugin version"
  )
}

test "K0007: a guard naming a module value" {
  val src = head() + "val limit: Int = 3\n\npub exposed record G {\n  n: Int\n}\n\n" +
    "@capability(grant = G)\npub interface C {\n  func f(x: in Int): Result[Int, String]\n    requires: grant.n > limit\n}\n"
  expectDiag(src, "K0007", "module value in guard")
}

test "K0007: a guard naming grant without a grant type" {
  expectDiag(
    head() + "@capability\npub interface C {\n  func f(x: in Int): Result[Int, String]\n    requires: grant.n > x\n}\n",
    "K0007",
    "no grant type"
  )
}

test "K0008: implements without an impl" {
  expectDiag(
    head() +
      "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n}\n",
    "K0008",
    "no impl"
  )
}

test "K0008: an impl of a point that is not listed" {
  val src = head() + "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n" +
    "@plugin_point(version = \"1.0\")\npub interface Other {\n  func g(): Result[Int, String]\n}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n}\n\n" +
    "impl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n\n" +
    "impl Other for X {\n  func g(): Result[Int, String] {\n    Ok(value = 2)\n  }\n}\n"
  expectDiag(src, "K0008", "unlisted point")
}

func k9Source(fns: in String): String {
  head() + "pub record K {\n  n: Int\n}\n\n" +
    "@plugin_point(version = \"1.0\", contributions = K)\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n}\n\n" +
    "impl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n\n" +
    fns
}

test "K0009: a missing contributions function" {
  expectDiag(k9Source(""), "K0009", "missing")
}

test "K0009: a duplicated contributions function" {
  val f = "@plugin_contributions(Pt)\nfunc a(): K = K(n = 1)\n\n@plugin_contributions(Pt)\nfunc b(): K = K(n = 2)\n"
  expectDiag(k9Source(f), "K0009", "duplicated")
}

test "K0009: a wrongly typed contributions function" {
  expectDiag(k9Source("@plugin_contributions(Pt)\nfunc a(): Int = 1\n"), "K0009", "wrong type")
}

test "a single well-typed contributions function is clean" {
  expectClean(expandOne(k9Source("@plugin_contributions(Pt)\nfunc a(): K = K(n = 1)\n")), "contributions")
}

test "K0010: a plugin field that is neither a client nor defaulted" {
  expectDiag(k3Source("Int"), "K0010", "plain field")
}

test "K0011: a protocol point with members" {
  expectDiag(
    head() + "@protocol_point(protocol = \"lsp/3.17\")\npub interface L {\n  func f(): Result[Int, String]\n}\n",
    "K0011",
    "members"
  )
}

test "a protocol point without members is clean" {
  val r = expandOne(head() + "@protocol_point(protocol = \"lsp/3.17\")\npub interface L {\n}\n")
  expectClean(r, "protocol point")
  expectFunc(r, "lPointInfo", "lPointInfo(): PluginPointInfo")
  expectFunc(
    r,
    "openLSession",
    "openLSession(host: PluginHost, pluginId: String): Result[ProtocolSession, BoundaryError]"
  )
}

test "K0012: a plugin package that declares main" {
  val src = k9Source("@plugin_contributions(Pt)\nfunc a(): K = K(n = 1)\n") + "\nfunc main(): Int = 0\n"
  expectDiag(src, "K0012", "main")
}

test "K0012: two plugin records" {
  val src = head() + "@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(): Result[Int, String]\n}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n}\n\n" +
    "impl Pt for X {\n  func f(): Result[Int, String] {\n    Ok(value = 1)\n  }\n}\n\n" +
    "@plugin(id = \"p.y\", version = \"1.0.0\", implements(Pt))\npub record Y {\n}\n\n" +
    "impl Pt for Y {\n  func f(): Result[Int, String] {\n    Ok(value = 2)\n  }\n}\n"
  expectDiag(src, "K0012", "two plugins")
}

// ─────────────────────────────────────────────────────────────────────────────
// Component builds (docs/69 §9.3).
// ─────────────────────────────────────────────────────────────────────────────
func compApiSource(): String {
  "package Acme.Tools\n" + "\n" + "@plugin_handle\n" + "pub type DocId = Long\n" + "\n" + "pub enum Level {\n" +
    "  case Low\n" +
    "  case High\n" +
    "}\n" +
    "\n" +
    "pub record Item {\n" +
    "  doc: DocId\n" +
    "  tags: Map[String, Int]\n" +
    "  data: List[Byte]\n" +
    "  pinned: Option[Bool]\n" +
    "  pair: (Int, String)\n" +
    "}\n" +
    "\n" +
    "pub union Change {\n" +
    "  case Added(item: Item)\n" +
    "  case Removed(doc: DocId)\n" +
    "  case Cleared\n" +
    "}\n" +
    "\n" +
    "pub exposed record StoreGrant {\n" +
    "  prefixes: List[String]\n" +
    "}\n" +
    "\n" +
    "@capability(grant = StoreGrant)\n" +
    "pub interface Store {\n" +
    "  func load(doc: in DocId): Result[Item, String]\n" +
    "  func touch(doc: in DocId): Result[Unit, Level]\n" +
    "}\n" +
    "\n" +
    "@capability\n" +
    "pub interface Log {\n" +
    "  func write(level: in Level, line: in String): Result[Unit, String]\n" +
    "}\n" +
    "\n" +
    "pub record ToolContributions {\n" +
    "  commands: List[String]\n" +
    "}\n" +
    "\n" +
    "@plugin_point(version = \"1.0\", contributions = ToolContributions, allows(Store, Log))\n" +
    "pub interface ItemTool {\n" +
    "  func summarize(item: in Item): Result[String, Level]\n" +
    "  func fetch(doc: in DocId): Result[Change, String]\n" +
    "}\n"
}

func compPluginSource(): String {
  "package Acme.Summary\n" + "\n" + "import Acme.Tools\n" + "\n" +
    "@plugin(id = \"acme.summary\", version = \"1.0.0\", publisher = \"acme\", implements(ItemTool))\n" +
    "pub record Summary {\n" +
    "  store: StoreClient\n" +
    "  log: Option[LogClient]\n" +
    "  var calls: Int = 0\n" +
    "}\n" +
    "\n" +
    "impl ItemTool for Summary {\n" +
    "  func summarize(item: in Item): Result[String, Level] {\n" +
    "    Ok(value = item.tags.count.toString())\n" +
    "  }\n" +
    "\n" +
    "  func fetch(doc: in DocId): Result[Change, String] {\n" +
    "    match store.load(doc) {\n" +
    "      case Ok(i) -> Ok(value = Change.Added(item = i))\n" +
    "      case Err(_) -> Err(error = \"no\")\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "@plugin_contributions(ItemTool)\n" +
    "func toolContributions(): ToolContributions {\n" +
    "  val cmds: List[String] = newList()\n" +
    "  cmds.add(\"summary.run\")\n" +
    "  ToolContributions(commands = cmds)\n" +
    "}\n" +
    "\n" +
    "@plugin_request(Store)\n" +
    "func storeRequest(): StoreGrant {\n" +
    "  val prefixes: List[String] = newList()\n" +
    "  prefixes.add(\"items/\")\n" +
    "  StoreGrant(prefixes = prefixes)\n" +
    "}\n"
}

func expandComponentOne(src: in String): PluginExpandResult {
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "fixture parses")
  val pkgs: Map[String, PluginPackage] = newMap()
  collectPluginPackage(pr.file, pkgs)
  expandFileForComponent(pr.file, pkgs)
}

func expandComponentSecond(first: in String, second: in String): PluginExpandResult {
  val a = parse(first)
  val b = parse(second)
  assertEqualInt(a.diagnostics.count + b.diagnostics.count, 0, "fixtures parse")
  val pkgs: Map[String, PluginPackage] = newMap()
  collectPluginPackage(a.file, pkgs)
  collectPluginPackage(b.file, pkgs)
  expandFileForComponent(b.file, pkgs)
}

func expectComponentDiag(src: in String, code: in String, needle: in String, label: in String): Unit {
  val r = expandComponentOne(src)
  var found = false
  for d in r.diagnostics {
    if d.code == code and Str.contains(d.message, needle) {
      found = true
    }
  }
  assertTrue(found, label + ": expected " + code + " mentioning '" + needle + "', got:\n" + diagText(r))
}

func isInternal(fn: in FunctionDecl): Bool {
  match fn.visibility {
    case Some(VisInternal(_)) -> true
    case _ -> false
  }
}

func isPubFn(fn: in FunctionDecl): Bool {
  match fn.visibility {
    case Some(VisPub(_)) -> true
    case _ -> false
  }
}

func externNamed(r: in PluginExpandResult, name: in String): Option[Item] {
  for it in r.file.items {
    match it.kind {
      case IExternFunc(d) -> {
        if d.name == name {
          return Some(value = it)
        }
      }
      case _ -> ()
    }
  }
  None
}

func unionCases(r: in PluginExpandResult, name: in String): List[String] {
  val acc: List[String] = newList()
  for it in r.file.items {
    match it.kind {
      case IUnion(d) -> {
        if d.name == name {
          for c in d.cases {
            acc.add(c.name)
          }
        }
      }
      case _ -> ()
    }
  }
  acc
}

func hasInterface(r: in PluginExpandResult, name: in String): Bool {
  for it in r.file.items {
    match it.kind {
      case IInterface(d) -> {
        if d.name == name {
          return true
        }
      }
      case _ -> ()
    }
  }
  false
}

test "component: the API and plugin packages expand without diagnostics" {
  expectClean(expandComponentOne(compApiSource()), "component api")
  expectClean(expandComponentSecond(compApiSource(), compPluginSource()), "component plugin")
}

test "component: the API package's client calls an interface, and nothing host-side is generated" {
  val r = expandComponentOne(compApiSource())
  assertTrue(hasInterface(r, "__StoreCalls"), "__StoreCalls")
  assertTrue(hasInterface(r, "__LogCalls"), "__LogCalls")
  assertTrue(hasRecord(r, "StoreClient"), "StoreClient")
  expectFunc(
    r,
    "StoreClient.load",
    "StoreClient.load(__stub: StoreClient, doc: DocId): Result[Item, CallError[String]]"
  )
  for name in ["StoreClient.load", "pluginEncodeItem", "pluginDecodeItem", "storeCapabilityInfo", "itemToolPointInfo"] {
    match funcNamed(r, name) {
      case Some(fn) -> assertTrue(isInternal(fn), name + " is internal, so it is no component export")
      case None -> panic("no generated function " + name)
    }
  }
  for absent in ["StoreServer", "StoreAs", "ItemToolRemote", "ItemToolContribution"] {
    assertFalse(hasRecord(r, absent), absent + " is host-side and not generated")
  }
  for absent in ["storeProvider", "itemToolRemotes", "pluginDispatchItemTool", "itemToolContributions"] {
    assertTrue(isNone(funcNamed(r, absent)), absent + " is host-side and not generated")
  }
}

test "component: a handle is marked for the WIT u64" {
  val r = expandComponentOne(compApiSource())
  assertTrue(anyAnnotationNamed(r, "__componentHandle"), "the handle carries @__componentHandle")
  assertFalse(anyAnnotationNamed(r, "plugin_handle"), "@plugin_handle is stripped")
  assertFalse(anyAnnotationNamed(expandOne(compApiSource()), "__componentHandle"), "process mode does not mark it")
}

test "component: the plugin's exports" {
  val r = expandComponentSecond(compApiSource(), compPluginSource())
  expectFunc(r, "pluginDescribe", "pluginDescribe(): String")
  expectFunc(r, "pluginAttach", "pluginAttach(grants: String): Result[Unit, String]")
  expectFunc(r, "pluginMethods", "pluginMethods(): List[String]")
  expectFunc(r, "itemToolSummarize", "itemToolSummarize(item: Acme.Tools.Item): Result[String, Acme.Tools.Level]")
  expectFunc(r, "itemToolFetch", "itemToolFetch(doc: Acme.Tools.DocId): Result[Acme.Tools.Change, String]")
  for name in ["pluginDescribe", "pluginAttach", "pluginMethods", "itemToolSummarize", "itemToolFetch"] {
    match funcNamed(r, name) {
      case Some(fn) -> assertTrue(isPubFn(fn), name + " is pub, so it becomes an export")
      case None -> panic("no export " + name)
    }
  }
  assertTrue(isNone(funcNamed(r, "main")), "no main in a component")
  assertFalse(hasRecord(r, "SummaryServer"), "no JSON-RPC server in a component")
}

test "component: capability imports and their error variants" {
  val r = expandComponentSecond(compApiSource(), compPluginSource())
  match externNamed(r, "__pluginImport_Store_load") {
    case Some(it) -> {
      match findAnnotation(it.annotations, "wasmImport") {
        case Some(a) -> assertEqual(unwrapOr(annotationLeadingString(a), ""), "Acme.Tools.Store", "the import module")
        case None -> panic("no @wasmImport on the Store.load import")
      }
      match it.kind {
        case IExternFunc(d) -> {
          assertEqual(d.symbol, "load", "the import name")
          match d.ret {
            case Some(t) -> assertEqual(Fmt.typeStr(t), "Result[Acme.Tools.Item, StoreCallErrorWire]", "the import's result")
            case None -> panic("the import has no result")
          }
        }
        case _ -> ()
      }
    }
    case None -> panic("no import for Store.load")
  }
  assertTrue(isSome(externNamed(r, "__pluginImport_Log_write")), "the Log.write import (optional capability)")
  val expected: List[String] = newList()
  for c in ["App", "Denied", "NotGranted", "Revoked", "Unsupported", "ContractViolated", "Timeout", "Crashed", "Protocol", "Stale"] {
    expected.add(c)
  }
  assertEqual(Str.joinList(",", unionCases(r, "StoreCallErrorWire")), Str.joinList(",", expected), "the cases in order")
  assertEqual(
    Str.joinList(",", unionCases(r, "StoreTouchCallErrorWire")),
    Str.joinList(",", expected),
    "touch has another error type, so its own variant"
  )
  assertEqualInt(unionCases(r, "LogCallErrorWire").count, 10, "LogCallErrorWire")
  val calls = implMethods(r, "Acme.Tools.__StoreCalls", "__StoreComponentCalls")
  assertTrue(calls.contains("load") and calls.contains("touch"), "the plugin implements __StoreCalls over the imports")
}

// The string a generated function returns as its whole body.
func returnedString(r: in PluginExpandResult, name: in String): String {
  val fn = match funcNamed(r, name) { case Some(f) -> f; case None -> panic("no generated function " + name) }
  val e = match fn.body {
    case Some(FunctionBody.FBExpr(x)) -> x
    case Some(FunctionBody.FBBlock(b)) -> match b.statements[b.statements.count - 1].kind {
      case SExpr(x) -> x
      case _ -> panic(name + " does not end in an expression")
    }
    case None -> panic(name + " has no body")
  }
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LString(text) -> text
      case _ -> panic(name + " does not return a string literal")
    }
    case _ -> panic(name + " does not return a string literal")
  }
}

test "component: the type hints name what the WIT does not carry" {
  val r = expandComponentSecond(compApiSource(), compPluginSource())
  expectFunc(r, "pluginTypeHints", "pluginTypeHints(): String")
  match funcNamed(r, "pluginTypeHints") {
    case Some(fn) -> assertTrue(isPubFn(fn), "pluginTypeHints is pub, so it becomes an export")
    case None -> panic("no pluginTypeHints")
  }
  val h = returnedString(r, "pluginTypeHints")
  val item = "{\"record\": {\"tags\": {\"map\": null}}}"
  assertTrue(
    h.contains("\"item-tool-summarize\": {\"params\": [" + item + "], \"result\": null}"),
    "an export's Map field inside a record, nothing named in its result: " + h
  )
  assertTrue(
    h.contains(
      "\"item-tool-fetch\": {\"params\": [null], \"result\": {\"result\": {\"ok\": {\"variant\": {\"added\": {\"field\": \"item\", \"of\": " +
        item +
        "}, \"removed\": {\"field\": \"doc\", \"of\": null}}}, \"err\": null}}}"
    ),
    "a union result names each case's field; a handle and a nullary case need nothing: " + h
  )
  assertTrue(
    h.contains(
      "\"imports\": {\"acme-tools-store#load\": {\"params\": [null], \"result\": {\"result\": {\"ok\": " + item
    ),
    "an import keyed by its bare interface: " + h
  )
  assertTrue(
    h.contains("\"app\": {\"field\": \"error\", \"of\": null}, \"denied\": {\"field\": \"reason\", \"of\": null}"),
    "the wire variant's cases carry BoundaryError's field names: " + h
  )
  assertTrue(h.contains("\"timeout\": {\"field\": \"timeoutMs\", \"of\": null}"), "timeout: " + h)
  assertTrue(
    h.contains("\"acme-tools-log#write\": {\"params\": [null, null]"),
    "the optional capability's import: " + h
  )
}

test "component: an import with another error type has its own hint" {
  val r = expandComponentSecond(compApiSource(), compPluginSource())
  val h = returnedString(r, "pluginTypeHints")
  val at = match Str.indexOf(h, "\"acme-tools-store#touch\"") {
    case Some(i) -> i
    case None -> panic("no touch hint: " + h)
  }
  val touch = Str.substring(h, at)
  assertTrue(
    Str.startsWith(
      touch,
      "\"acme-tools-store#touch\": {\"params\": [null], \"result\": {\"result\": {\"ok\": null, \"err\": {\"variant\": {\"app\": {\"field\": \"error\", \"of\": null}, \"denied\""
    ),
    "touch's error is Level (an enum), so app carries it with no names below: " + touch
  )
}

test "component: process mode is unchanged by the component path" {
  val r = expandSecond(compApiSource(), compPluginSource())
  expectClean(r, "process plugin")
  assertTrue(hasRecord(r, "SummaryServer"), "SummaryServer")
  expectFunc(r, "main", "main(): Int")
  assertTrue(isNone(funcNamed(r, "pluginDescribe")), "no component exports in process mode")
}

// A package with declarations `decls`, a point with the one method `sig`, and
// a plugin implementing it by returning `Err(error = errValue)`.
func compPlugin(decls: in String, sig: in String, errValue: in String): String {
  head() + decls + "\n" + "@plugin_point(version = \"1.0\")\npub interface Pt {\n  " + sig + "\n}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Pt))\npub record X {\n}\n\n" +
    "impl Pt for X {\n  " +
    sig +
    " {\n    Err(error = " +
    errValue +
    ")\n  }\n}\n"
}

func compBadSource(recordBody: in String, method: in String): String {
  compPlugin("pub record R {\n" + recordBody + "}\n", Str.trim(method), "\"x\"")
}

test "K0013: a field whose name does not survive the WIT round trip" {
  val src = compBadSource("  customer_id: Int\n", "  func f(r: in R): Result[Int, String]")
  expectComponentDiag(src, "K0013", "customer_id", "snake-case field")
  expectClean(expandOne(src), "process mode accepts the same field")
}

test "K0013: a method with an acronym" {
  expectComponentDiag(
    compBadSource("  n: Int\n", "  func getURL(r: in R): Result[Int, String]"),
    "K0013",
    "getURL",
    "acronym method"
  )
}

test "K0013: a parameter and a type case" {
  expectComponentDiag(
    compBadSource("  n: Int\n", "  func f(r_x: in R): Result[Int, String]"),
    "K0013",
    "r_x",
    "parameter"
  )
  val src = compPlugin("pub enum E {\n  case HTTPError\n}\n", "func f(): Result[Int, E]", "E.HTTPError")
  expectComponentDiag(src, "K0013", "HTTPError", "enum case")
}

test "K0013: an export that collides with a type in the exported interface" {
  val src = compPlugin("pub record PtRun {\n  n: Int\n}\n", "func run(x: in PtRun): Result[Int, String]", "\"x\"")
  expectComponentDiag(src, "K0013", "pt-run", "export and type share a WIT name")
}

test "K0014: types a component cannot carry" {
  expectComponentDiag(compBadSource("  n: UInt\n", "  func f(r: in R): Result[Int, String]"), "K0014", "UInt", "UInt")
  expectComponentDiag(compBadSource("  c: Char\n", "  func f(r: in R): Result[Int, String]"), "K0014", "Char", "Char")
  expectComponentDiag(
    compBadSource("  n: Int\n", "  func f(b: in slice[Byte]): Result[Int, String]"),
    "K0014",
    "slice[Byte]",
    "slice"
  )
  expectComponentDiag(
    compBadSource("  n: Int\n", "  func f(j: in JsonValue): Result[Int, String]"),
    "K0014",
    "JsonValue",
    "JsonValue"
  )
  val multi = compPlugin(
    "pub union U {\n  case Two(a: Int, b: Int)\n}\n",
    "func f(u: in U): Result[Int, String]",
    "\"x\""
  )
  expectComponentDiag(multi, "K0014", "several fields", "a multi-field case")
  val recursive = compPlugin(
    "pub record Tree {\n  kids: List[Tree]\n}\n",
    "func f(t: in Tree): Result[Int, String]",
    "\"x\""
  )
  expectComponentDiag(recursive, "K0014", "recursive", "a recursive record")
}

test "K0014: a protocol point cannot be a component" {
  val src = head() + "@protocol_point(protocol = \"lsp/3.17\")\npub interface Ls {}\n\n" +
    "@plugin(id = \"p.x\", version = \"1.0.0\", implements(Ls))\npub record X {\n}\n\n" +
    "impl Ls for X {\n}\n"
  expectComponentDiag(src, "K0014", "protocol point", "protocol point")
}
