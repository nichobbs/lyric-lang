//! restored_packages_self_test.l — exercises the `Lyric.RestoredPackages`
//! loader (#1229 Phase A.3.2).
//!
//! Run via `lyric test lyric-compiler/lyric/restored_packages_self_test.l`.
//! Replaces the F# SelfHostedRestoredPackagesTests.fs wrapper (#2580).
@test_module
package Lyric.RestoredPackages.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.ContractMeta as Meta
import Lyric.RestoredPackages
import Lyric.Parser
import Lyric.AliasRewriter

func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "restored_packages_self_test.dll")
}

// Happy path: the running test PE has an embedded `Lyric.Contract`
// (every Lyric-emitted assembly does), so the loader returns one
// artifact with a populated package name.
func testLoadRunningPe(): Unit {
  match loadRestoredPackage(selfDllPath()) {
    case Err(e) -> panic("load_running_pe: " + errorMessage(e))
    case Ok(artifacts) -> {
      assertTrue(artifacts.count >= 1, "load_running_pe: at least one artifact")
      val a = artifacts[0]
      assertTrue(Str.isNotEmpty(a.packageName), "load_running_pe: packageName non-empty")
      assertEqual(a.dllPath, selfDllPath(), "load_running_pe: dllPath round-trips")
      // contract.packageName is the source of truth for legacy-form
      // resources — confirm it lines up with the artifact's name.
      assertEqual(
        a.contract.packageName,
        a.packageName,
        "load_running_pe: artifact.packageName matches contract.packageName"
      )
    }
  }
}

// Missing path → DllMissing error.
func testMissingFileError(): Unit {
  match loadRestoredPackage("/definitely/does/not/exist.dll") {
    case Ok(_) -> panic("missing_file: expected Err")
    case Err(e) -> {
      match e {
        case DllMissing(p) -> assertEqual(p, "/definitely/does/not/exist.dll", "missing_file: path round-trips")
        case _ -> panic("missing_file: expected DllMissing, got: " + errorMessage(e))
      }
    }
  }
}

// errorMessage produces a non-empty string for each variant — pinning
// the diagnostic surface.
func testErrorMessageVariants(): Unit {
  val m1 = errorMessage(DllMissing(path = "/x.dll"))
  assertTrue(Str.contains(m1, "/x.dll"), "error_message: DllMissing mentions path")
  val m2 = errorMessage(NoContractResource(path = "/y.dll"))
  assertTrue(Str.contains(m2, "/y.dll"), "error_message: NoContractResource mentions path")
  val m3 = errorMessage(MalformedContract(path = "/z.dll", pkgKey = "Foo"))
  assertTrue(Str.contains(m3, "/z.dll"), "error_message: MalformedContract mentions path")
  assertTrue(Str.contains(m3, "Foo"), "error_message: MalformedContract mentions pkgKey")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Source synthesis (#1229 Phase A.3.3.a)
// ─────────────────────────────────────────────────────────────────────────────
func emptyDecls(): List[Meta.ContractDecl] {
  newList()
}

func mkContract(name: in String, decls: in List[Meta.ContractDecl]): Meta.Contract {
  Meta.Contract(
    packageName = name,
    version = "1.0.0",
    level = "runtime_checked",
    formatVersion = 2,
    decls = decls,
    dependencies = newList(),
    contractHash = ""
  )
}

func mkDecl(kind: in String, name: in String, repr: in String): Meta.ContractDecl {
  Meta.ContractDecl(
    kind = kind,
    name = name,
    repr = repr,
    visibility = "pub",
    isPure = false,
    stability = "",
    requiresClauses = newList(),
    ensuresClauses = newList(),
    body = None,
    params = newList(),
    bmode = false
  )
}

// Empty contract produces a one-line `package X` header.
func testSynthesiseEmptyContract(): Unit {
  val c = mkContract("MyApp.Empty", emptyDecls())
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "package MyApp.Empty"), "synth_empty: emits package decl")
}

// Function decls round-trip from `Repr` verbatim, plus a trailing newline.
func testSynthesiseFunc(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "double", "pub func double(x: Int): Int"))
  val c = mkContract("MyApp.Math", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "pub func double(x: Int): Int"), "synth_func: repr appears in source")
  assertTrue(Str.contains(src, "package MyApp.Math"), "synth_func: package header present")
}

// A HEAD-ONLY interface repr (the form the legacy F# contract writer
// `ContractMeta.fs` emits — `pub interface I` with no body) gets an empty
// `{}` body appended so the re-parse sees a complete item.
func testSynthesiseInterfaceAppendsBraces(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("interface", "Drawable", "pub interface Drawable"))
  val c = mkContract("MyApp.Gfx", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(
    Str.contains(src, "pub interface Drawable {}"),
    "synth_interface: empty `{}` body appended to head-only repr"
  )
}

// A FULL-BODY interface repr (the form the self-hosted contract writer
// `contract_meta.l::reprForInterface` emits) is passed through verbatim —
// appending `{}` would produce `... } {}`, a bare trailing block that fails
// to re-parse as an item declaration (#1596, the bug that broke every
// locally-built dep carrying an interface, e.g. `Cache.CacheStore`).
func testSynthesiseInterfaceFullBodyNoDoubleBrace(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(
    mkDecl(
      "interface",
      "CacheStore",
      "pub interface CacheStore { func get(key: in String): Option[String]; func clear(): Unit }"
    )
  )
  val c = mkContract("MyApp.Cache", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(
    Str.contains(src, "pub interface CacheStore { func get(key: in String): Option[String]; func clear(): Unit }"),
    "synth_interface_body: full-body repr emitted verbatim"
  )
  assertTrue(
    not Str.contains(src, "} {}"),
    "synth_interface_body: no double-brace `} {}` appended to a body-bearing repr"
  )
}

// Records / unions / enums / distincts / aliases / opaques pass through
// unchanged — `renderDecl` only special-cases interfaces (#1259).
func testSynthesiseNonInterfaceKindsPassThrough(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("record", "Point", "pub record Point { x: Int, y: Int }"))
  decls.add(mkDecl("union", "Maybe", "pub union Maybe { case Some(v: Int), case None }"))
  decls.add(mkDecl("enum", "Color", "pub enum Color { Red, Green, Blue }"))
  decls.add(mkDecl("distinct_type", "UserId", "pub type UserId = Int"))
  decls.add(mkDecl("type_alias", "Bytes", "pub alias Bytes = slice[Byte]"))
  decls.add(mkDecl("opaque", "OpaqueBox", "pub opaque type OpaqueBox { v: Int }"))
  val c = mkContract("MyApp.Types", decls)
  val src = synthesiseSource(c, emptyDecls())
  assertTrue(Str.contains(src, "pub record Point { x: Int, y: Int }"), "synth_pass_through: record verbatim")
  assertTrue(
    Str.contains(src, "pub union Maybe { case Some(v: Int), case None }"),
    "synth_pass_through: union verbatim"
  )
  assertTrue(Str.contains(src, "pub enum Color { Red, Green, Blue }"), "synth_pass_through: enum verbatim")
  assertTrue(Str.contains(src, "pub type UserId = Int"), "synth_pass_through: distinct type verbatim")
  assertTrue(Str.contains(src, "pub alias Bytes = slice[Byte]"), "synth_pass_through: type alias verbatim")
  assertTrue(Str.contains(src, "pub opaque type OpaqueBox { v: Int }"), "synth_pass_through: opaque type verbatim")
}

// Preamble decls appear BEFORE the contract's own decls.
func testSynthesisePreambleOrdering(): Unit {
  val preamble: List[Meta.ContractDecl] = newList()
  preamble.add(mkDecl("extern_type", "Map", "extern type Map[K, V] = \"System.Collections.Generic.Dictionary`2\""))
  val ownDecls: List[Meta.ContractDecl] = newList()
  ownDecls.add(mkDecl("func", "size", "pub func size(m: Map[String, Int]): Int"))
  val c = mkContract("MyApp.Coll", ownDecls)
  val src = synthesiseSource(c, preamble)
  val externIdx = src.indexOf("extern type Map")
  val funcIdx = src.indexOf("pub func size")
  assertTrue(externIdx >= 0, "synth_preamble: extern present")
  assertTrue(funcIdx >= 0, "synth_preamble: own func present")
  assertTrue(externIdx < funcIdx, "synth_preamble: extern appears BEFORE the contract's own func")
}

// A preamble enum is rendered WITHOUT its cases (`pub enum Name {}`) so a
// bare case name never lands as a package-level symbol that collides with
// an unrelated sibling type of the same name once flattened into one
// synthesised source (#2514).  The owning contract's own enum keeps its
// cases.
func testSynthesisePreambleEnumStripsCases(): Unit {
  val preamble: List[Meta.ContractDecl] = newList()
  preamble.add(
    mkDecl(
      "enum",
      "ParameterLocation",
      "pub enum ParameterLocation { case Path; case Query; case Header; case Cookie }"
    )
  )
  val ownDecls: List[Meta.ContractDecl] = newList()
  ownDecls.add(mkDecl("record", "Header", "pub record Header { name: String, value: String }"))
  val c = mkContract("MyApp.Web", ownDecls)
  val src = synthesiseSource(c, preamble)
  assertTrue(Str.contains(src, "pub enum ParameterLocation {}"), "synth_preamble_enum: enum anchor is caseless")
  assertTrue(
    not Str.contains(src, "case Header"),
    "synth_preamble_enum: no 'case Header' to collide with record Header"
  )
  assertTrue(Str.contains(src, "pub record Header"), "synth_preamble_enum: own record Header preserved")
}

// A preamble UNION is likewise rendered caseless, with its generic head
// preserved (`pub union Result[T, E] {}`).  This stops a stdlib case such
// as `Std.Core.Result.Ok` (a union case) from colliding with a restored
// package's enum case of the same name (`Grpc.Types.GrpcStatusCode.Ok`)
// when both are flattened into the validation source (#2514).
func testSynthesisePreambleUnionStripsCases(): Unit {
  val preamble: List[Meta.ContractDecl] = newList()
  preamble.add(mkDecl("union", "Result", "pub union Result[T, E] { case Ok(value: T), case Err(err: E) }"))
  val ownDecls: List[Meta.ContractDecl] = newList()
  ownDecls.add(mkDecl("enum", "GrpcStatusCode", "pub enum GrpcStatusCode { case Ok; case Cancelled }"))
  val c = mkContract("Grpc.Types", ownDecls)
  val src = synthesiseSource(c, preamble)
  assertTrue(
    Str.contains(src, "pub union Result[T, E] {}"),
    "synth_preamble_union: union anchor is caseless, generics kept"
  )
  assertTrue(not Str.contains(src, "case Ok(value"), "synth_preamble_union: no union 'case Ok' to collide")
  assertTrue(Str.contains(src, "case Ok; case Cancelled"), "synth_preamble_union: own enum keeps its cases")
}

// Output ends in a newline — keeps the parser-friendly shape (trailing
// items always terminated by a newline).
func testSynthesiseTrailingNewline(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "noop", "pub func noop(): Unit"))
  val src = synthesiseSource(mkContract("X", decls), emptyDecls())
  val last = src.substring(src.length - 1, 1)
  assertEqual(last, "\n", "synth_trailing_newline: ends with \\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. synthesiseArtifact: synthesise + re-parse + re-typecheck (#1229 Phase A.3.3.b)
// ─────────────────────────────────────────────────────────────────────────────
func mkArtifact(pkgName: in String, decls: in List[Meta.ContractDecl]): RestoredArtifact {
  RestoredArtifact(
    packageName = pkgName,
    version = "1.0.0",
    dllPath = "/tmp/" + pkgName + ".dll",
    contract = mkContract(pkgName, decls)
  )
}

// A contract with a single axiom-style `pub func` round-trips
// through `synthesiseArtifact` cleanly.  The returned `source` carries
// the synthesized SourceFile; `checkResult.diagnostics` should contain
// no real errors.
func testSynthesiseArtifactHappyPath(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "double", "pub func double(x: Int): Int"))
  val art = mkArtifact("MyApp.Math", decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Err(e) -> panic("synth_artifact_happy: unexpected error: " + errorMessage(e))
    case Ok(sa) -> {
      assertEqual(sa.packageName, "MyApp.Math", "synth_artifact_happy: packageName round-trips")
      assertEqual(sa.dllPath, "/tmp/MyApp.Math.dll", "synth_artifact_happy: dllPath round-trips")
      assertEqualInt(sa.source.items.count, 1, "synth_artifact_happy: one item parsed")
    }
  }
}

// A contract whose `repr` is genuinely malformed Lyric source bubbles
// up as `SynthesisDiagnostics`.
func testSynthesiseArtifactMalformedRepr(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "broken", "pub func @@@ malformed garbage tokens"))
  val art = mkArtifact("MyApp.Broken", decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Ok(_) -> panic("synth_artifact_malformed: expected SynthesisDiagnostics")
    case Err(e) -> {
      match e {
        case SynthesisDiagnostics(p, ds) -> {
          assertEqual(p, "/tmp/MyApp.Broken.dll", "synth_artifact_malformed: path round-trips")
          assertTrue(ds.count > 0, "synth_artifact_malformed: at least one diagnostic")
        }
        case _ -> panic("synth_artifact_malformed: wrong error variant")
      }
    }
  }
}

// T0010 about a whitelisted stdlib anchor (`Option`, `Result`, `List`,
// …) is filtered out — the synthesised standalone contract source
// can legitimately reference them without import.  A contract whose
// only "errors" are T0010s on whitelisted anchors should round-trip
// cleanly.
func testSynthesiseArtifactWhitelistedT0010Filtered(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "find", "pub func find(x: Int): Option[Int]"))
  val art = mkArtifact("MyApp.Search", decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Err(e) -> panic("synth_artifact_whitelisted: unexpected error (T0010 on Option should be filtered): " + errorMessage(e))
    case Ok(sa) -> {
      assertEqual(sa.packageName, "MyApp.Search", "synth_artifact_whitelisted: round-tripped")
    }
  }
}

// A signature that references a stdlib type by its FULL `Std.Module.Type`
// path — the shape any non-`Std.Core` stdlib type (e.g. lyric-web's
// `serveTls(tls: Std.Tls.TlsServerConfig)`) carries in its repr — produces a
// T0014 "unknown qualified type 'Std.X.Y'" in the standalone contract
// recheck (which loads no stdlib), NOT a bare-name T0010.  That T0014 must be
// filtered for `Std.*`-qualified names exactly as the T0010 bare-name anchors
// are, or the whole restored-DLL synthesis fails and every consumer of that
// library breaks (the regression this guards: `examples/rbac` restoring
// `Web.dll`).  Two references in one signature (param + return) exercise the
// multi-diagnostic path.
func testSynthesiseArtifactWhitelistedStdQualifiedFiltered(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "serveTls", "pub func serveTls(tls: Std.Tls.TlsServerConfig): Std.Tls.TlsVersion"))
  val art = mkArtifact("MyApp.WebTls", decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Err(e) -> panic("synth_artifact_std_qualified: unexpected error (T0014 on Std.Tls.* should be filtered): " + errorMessage(e))
    case Ok(sa) -> {
      assertEqual(sa.packageName, "MyApp.WebTls", "synth_artifact_std_qualified: round-tripped")
    }
  }
}

// #5844: a `pub` function whose signature reaches a cross-package type
// through an ALIASED import (`import Std.File as File`, body references
// `File.FileStat`) must round-trip through contract synthesis exactly like
// the bare-qualified case above.  Unlike
// `testSynthesiseArtifactWhitelistedStdQualifiedFiltered` (which hand-crafts
// the `Std.Tls.TlsServerConfig` repr string directly, never touching alias
// expansion), this test drives the REAL pipeline a compiler build uses:
// parse -> `Lyric.AliasRewriter.rewriteFile` (which expands the aliased
// `File.FileStat` reference to the fully-qualified `Std.File.FileStat`
// *before* contract synthesis ever sees it, per
// `Lyric.Pipeline.pipeExpandAndRewrite`'s pass order) ->
// `Lyric.ContractMeta.buildContractFromFile` -> `synthesiseArtifact`.  This
// is exactly the shape `Lyric.Cli.cli_shared.l`'s `anyLyricSourceNewerThan`
// hit when made `pub` (#5844's repro).  The `isWhitelistedStdQualified`
// guard added for the bare-qualified case is name-shape-based (any T0014
// whose joined qualified name starts with "Std."), so it already covers
// this alias-expanded shape too — this test pins that coverage against the
// real emission path instead of a hand-written repr.
func testSynthesiseArtifactAliasedStdQualifiedFiltered(): Unit {
  val src = "package MyApp.FileTools\n\nimport Std.File as File\n\npub func isNewer(dir: in String, ref: in File.FileStat): Bool {\n  false\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val contract = Meta.buildContractFromFile(rewritten, "1.0.0")
  assertEqualInt(contract.decls.count, 1, "alias_std_qualified: exactly one pub decl in the contract")
  val d = contract.decls[0]
  // Pin the alias-expansion behaviour itself: the repr must carry the
  // fully-qualified `Std.File.FileStat`, not the source-level alias
  // `File.FileStat` — confirms this test exercises the same shape #5844
  // reported, not a degenerate no-op rewrite.
  assertTrue(
    Str.contains(d.repr, "Std.File.FileStat"),
    "alias_std_qualified: repr carries the alias-expanded qualified type (got " + d.repr + ")"
  )
  val art = mkArtifact("MyApp.FileTools", contract.decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Err(e) -> panic("alias_std_qualified: unexpected error (aliased Std.File.FileStat should be filtered): " + errorMessage(e))
    case Ok(sa) -> {
      assertEqual(sa.packageName, "MyApp.FileTools", "alias_std_qualified: round-tripped")
    }
  }
}

// A qualified reference to a NON-stdlib package that is genuinely absent
// (no preamble, not `Std.*`) is still a real error — the `Std.` guard must
// not swallow every T0014.
func testSynthesiseArtifactNonStdQualifiedStillErrors(): Unit {
  val decls: List[Meta.ContractDecl] = newList()
  decls.add(mkDecl("func", "use", "pub func use(x: Other.Pkg.Widget): Int"))
  val art = mkArtifact("MyApp.NeedsOther", decls)
  match synthesiseArtifact(art, emptyDecls()) {
    case Ok(_) -> panic("synth_artifact_non_std_qualified: expected a real error for a missing non-stdlib qualified type")
    case Err(e) -> match e { case SynthesisDiagnostics(_, ds) -> assertTrue(ds.count > 0, "synth_artifact_non_std_qualified: at least one diagnostic"); case _ -> panic("synth_artifact_non_std_qualified: wrong error variant") }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Test items
// ─────────────────────────────────────────────────────────────────────────────
// Note: a warnings-only scenario (synthesiseArtifact succeeds when typecheck
// produces only DiagWarning, no DiagError) is covered implicitly: a valid func
// repr produces no errors and no warnings, so the predicate logic is exercised
// without constructing a dedicated warning-emitting source (no compiler path
// currently produces a DiagWarning in isolation from a DiagError for
// synthesised contract sources).
test "load running PE" {
  testLoadRunningPe()
}

test "missing file error" {
  testMissingFileError()
}

test "error message variants" {
  testErrorMessageVariants()
}

test "synthesise empty contract" {
  testSynthesiseEmptyContract()
}

test "synthesise func" {
  testSynthesiseFunc()
}

test "synthesise interface appends braces" {
  testSynthesiseInterfaceAppendsBraces()
}

test "synthesise interface full body no double brace" {
  testSynthesiseInterfaceFullBodyNoDoubleBrace()
}

test "synthesise non-interface kinds pass through" {
  testSynthesiseNonInterfaceKindsPassThrough()
}

test "synthesise preamble ordering" {
  testSynthesisePreambleOrdering()
}

test "synthesise preamble enum strips cases" {
  testSynthesisePreambleEnumStripsCases()
}

test "synthesise preamble union strips cases" {
  testSynthesisePreambleUnionStripsCases()
}

test "synthesise trailing newline" {
  testSynthesiseTrailingNewline()
}

test "synthesise artifact happy path" {
  testSynthesiseArtifactHappyPath()
}

test "synthesise artifact malformed repr" {
  testSynthesiseArtifactMalformedRepr()
}

test "synthesise artifact whitelisted T0010 filtered" {
  testSynthesiseArtifactWhitelistedT0010Filtered()
}

test "synthesise artifact whitelisted Std-qualified T0014 filtered" {
  testSynthesiseArtifactWhitelistedStdQualifiedFiltered()
}

test "synthesise artifact whitelisted aliased Std-qualified T0014 filtered (#5844)" {
  testSynthesiseArtifactAliasedStdQualifiedFiltered()
}

test "synthesise artifact non-Std qualified still errors" {
  testSynthesiseArtifactNonStdQualifiedStillErrors()
}
