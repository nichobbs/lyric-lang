// restored_packages_self_test.l — exercises the `Lyric.RestoredPackages`
// loader (#1229 Phase A.3.2).  Compiled and executed by
// SelfHostedRestoredPackagesTests.fs.  Exit 0 + "ok" in stdout means
// every assertion held.

package Lyric.RestoredPackages.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Lyric.ContractMeta as Meta
import Lyric.RestoredPackages

func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "self_hosted_restored_packages.dll")
}

// Happy path: the running test PE has an embedded `Lyric.Contract`
// (every Lyric-emitted assembly does), so the loader returns one
// artifact with a populated package name.
func testLoadRunningPe(): Unit {
  match loadRestoredPackage(selfDllPath()) {
    case Err(e) -> panic("load_running_pe: " + errorMessage(e))
    case Ok(artifacts) -> {
      assertTrue(artifacts.count >= 1,
        "load_running_pe: at least one artifact")
      val a = artifacts[0]
      assertTrue(Str.isNotEmpty(a.packageName),
        "load_running_pe: packageName non-empty")
      assertEqual(a.dllPath, selfDllPath(),
        "load_running_pe: dllPath round-trips")
      // contract.packageName is the source of truth for legacy-form
      // resources — confirm it lines up with the artifact's name.
      assertEqual(a.contract.packageName, a.packageName,
        "load_running_pe: artifact.packageName matches contract.packageName")
    }
  }
}

// Missing path → DllMissing error.
func testMissingFileError(): Unit {
  match loadRestoredPackage("/definitely/does/not/exist.dll") {
    case Ok(_) -> panic("missing_file: expected Err")
    case Err(e) -> {
      match e {
        case DllMissing(p) ->
          assertEqual(p, "/definitely/does/not/exist.dll",
            "missing_file: path round-trips")
        case _ -> panic("missing_file: expected DllMissing, got: " + errorMessage(e))
      }
    }
  }
}

// errorMessage produces a non-empty string for each variant — pinning
// the diagnostic surface.
func testErrorMessageVariants(): Unit {
  val m1 = errorMessage(DllMissing(path = "/x.dll"))
  assertTrue(Str.contains(m1, "/x.dll"),
    "error_message: DllMissing mentions path")
  val m2 = errorMessage(NoContractResource(path = "/y.dll"))
  assertTrue(Str.contains(m2, "/y.dll"),
    "error_message: NoContractResource mentions path")
  val m3 = errorMessage(MalformedContract(path = "/z.dll", pkgKey = "Foo"))
  assertTrue(Str.contains(m3, "/z.dll"),
    "error_message: MalformedContract mentions path")
  assertTrue(Str.contains(m3, "Foo"),
    "error_message: MalformedContract mentions pkgKey")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Source synthesis (#1229 Phase A.3.3.a)
// ─────────────────────────────────────────────────────────────────────────────

func emptyDecls(): List[Meta.ContractDecl] {
  newList()
}

func mkContract(name: in String, decls: in List[Meta.ContractDecl]): Meta.Contract {
  Meta.Contract(
    packageName   = name,
    version       = "1.0.0",
    level         = "runtime_checked",
    formatVersion = 2,
    decls         = decls)
}

func mkDecl(kind: in String, name: in String, repr: in String): Meta.ContractDecl {
  Meta.ContractDecl(
    kind            = kind,
    name            = name,
    repr            = repr,
    isPure          = false,
    stability       = "",
    requiresClauses = newList(),
    ensuresClauses  = newList(),
    body            = None,
    params          = newList())
}

// Empty contract produces a one-line `package X` header.
func testSynthesiseEmptyContract(): Unit {
  val c = mkContract("MyApp.Empty", emptyDecls())
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "package MyApp.Empty"),
    "synth_empty: emits package decl")
}

// Function decls round-trip from `Repr` verbatim, plus a trailing newline.
func testSynthesiseFunc(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "double", "pub func double(x: Int): Int = ()"))
  val c = mkContract("MyApp.Math", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "pub func double(x: Int): Int = ()"),
    "synth_func: repr appears in source")
  assertTrue(Str.contains(src, "package MyApp.Math"),
    "synth_func: package header present")
}

// Interface decls get an empty `{}` body appended (per F# parity).
func testSynthesiseInterfaceAppendsBraces(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("interface", "Drawable", "pub interface Drawable"))
  val c = mkContract("MyApp.Gfx", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "pub interface Drawable {}"),
    "synth_interface: empty `{}` body appended")
}

// Records / unions / enums / distincts pass through unchanged.
func testSynthesiseNonInterfaceKindsPassThrough(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("record", "Point", "pub record Point { x: Int, y: Int }"))
  decls.add(mkDecl("union", "Maybe", "pub union Maybe { case Some(v: Int), case None }"))
  decls.add(mkDecl("enum", "Color", "pub enum Color { Red, Green, Blue }"))
  val c = mkContract("MyApp.Types", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "pub record Point { x: Int, y: Int }"),
    "synth_pass_through: record verbatim")
  assertTrue(Str.contains(src, "pub union Maybe { case Some(v: Int), case None }"),
    "synth_pass_through: union verbatim")
  assertTrue(Str.contains(src, "pub enum Color { Red, Green, Blue }"),
    "synth_pass_through: enum verbatim")
}

// Preamble decls appear BEFORE the contract's own decls.
func testSynthesisePreambleOrdering(): Unit {
  val preamble: List[Meta.ContractDecl] = newList()
  preamble.add(mkDecl("extern_type", "Map", "extern type Map[K, V] = \"System.Collections.Generic.Dictionary`2\""))
  val ownDecls: List[Meta.ContractDecl] = newList()
  ownDecls.add(mkDecl("func", "size", "pub func size(m: Map[String, Int]): Int = ()"))
  val c = mkContract("MyApp.Coll", ownDecls)
  val src = synthesiseSource(c, preamble)
  val externIdx = src.indexOf("extern type Map")
  val funcIdx   = src.indexOf("pub func size")
  assertTrue(externIdx >= 0, "synth_preamble: extern present")
  assertTrue(funcIdx >= 0,   "synth_preamble: own func present")
  assertTrue(externIdx < funcIdx,
    "synth_preamble: extern appears BEFORE the contract's own func")
}

// Output ends in a newline — keeps the parser-friendly shape (trailing
// items always terminated by a newline).
func testSynthesiseTrailingNewline(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "noop", "pub func noop(): Unit = ()"))
  val src = synthesiseSource(mkContract("X", decls), emptyDecls())
  val last = src.substring(src.length - 1, 1)
  assertEqual(last, "\n", "synth_trailing_newline: ends with \\n")
}

// Non-Lyric DLL → NoContractResource error.  Uses System.Runtime.dll
// from the running .NET tfm — every .NET runtime ships it, and it has
// no embedded `Lyric.Contract*` resource by definition (#1256).
func testNoContractResourceError(): Unit {
  // AppContext.BaseDirectory points at the test PE's directory, where
  // the .NET shared framework copies dependent assemblies including
  // System.Runtime.dll.  Skip rather than fail when the framework
  // layout differs (e.g. trimmed / single-file deployment).
  val candidate = Path.join(Environment.appBaseDirectory(), "System.Runtime.dll")
  if not File.fileExists(candidate) {
    return ()
  }
  match loadRestoredPackage(candidate) {
    case Ok(_) -> panic("no_contract: expected Err for non-Lyric DLL")
    case Err(e) -> {
      match e {
        case NoContractResource(p) ->
          assertEqual(p, candidate, "no_contract: path round-trips")
        case _ -> panic("no_contract: expected NoContractResource, got: " + errorMessage(e))
      }
    }
  }
}

func main(): Int {
  testLoadRunningPe()
  testMissingFileError()
  testNoContractResourceError()
  testErrorMessageVariants()
  testSynthesiseEmptyContract()
  testSynthesiseFunc()
  testSynthesiseInterfaceAppendsBraces()
  testSynthesiseNonInterfaceKindsPassThrough()
  testSynthesisePreambleOrdering()
  testSynthesiseTrailingNewline()
  println("restored-packages self-test: ok")
  return 0
}
