//! jvm_cross_package_collision_self_test.l — end-to-end tests for the
//! self-hosted multi-package JVM bridge (`Jvm.Bridge.compileProjectToJarBundledWithFeatures`)
//! pinning bare-name cross-package collision fixes (#5455, #5976) and the
//! literal `Std.Regex`/`Std.RegexSafe` regression from #5976: a THIRD file
//! that aliases two same-simple-name colliding packages (own-type-shadowing
//! fix, plus the two new tests below covering the shape neither of those
//! fixes reaches — cross-import collision via alias, and a same-named
//! `extern type` only reachable through an intermediate package's
//! re-exported generic return).
//!
//! Each test bundles multiple Lyric packages into one runnable JAR via the
//! in-process self-hosted `Jvm.Bridge` pipeline, runs it via `java -jar`, and
//! asserts on stdout — the JVM analogue of `msil_project_bridge_self_test.l`.
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-stdlib/tests/`) so it can
//! import `Jvm.Bridge` without overflowing the F# bootstrap emitter's
//! transitive-closure limit (there is none any more — F# is gone — but the
//! self-hosted stage-1 bundle DLLs still resolve the compiler-package
//! imports the same way `msil_project_bridge_self_test.l` does, #2364).
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_cross_package_collision_self_test.l
@test_module
package Lyric.JvmCrossPackageCollisionSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Jvm.Bridge
import Lyric.Emitter as Emitter

// ─── Helpers ────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-xpkg-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// Compile `pkgSrcs` (one source string per package, the entry package being
// the one that declares `func main`) into a runnable JAR and execute it via
// `java -jar`.  Mirrors `msil_project_bridge_self_test.l`'s `compileAndRun`.
func compileAndRunJvm(label: in String, pkgSrcs: in List[String], entryPkgName: in String): Capture.CaptureResult {
  val noStdlib: List[String] = newList()
  compileAndRunJvmWithStdlib(label, pkgSrcs, entryPkgName, noStdlib)
}

// `compileAndRunJvm` with the standard library sources bundled, for packages
// that use `Std.Core`'s `Option`/`Result` (a distinct type's `from`).
func compileAndRunJvmWithStdlib(
  label: in String,
  pkgSrcs: in List[String],
  entryPkgName: in String,
  stdlibSources: in List[String],
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val noPaths: List[String] = newList()
  var pi = 0
  while pi < pkgSrcs.count {
    noPaths.add("")
    pi += 1
  }
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    entryPkgName,
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0",
    noPaths
  )
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToJarBundledWithFeatures returned false")
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  result
}

// ─── #5455: cross-package impl of a native interface with a third-package
// union parameter must not emit a wrong class reference ─────────────────────
// `ImplPkg` implements `IfacePkg.Handler` (declared in a THIRD package,
// `IfacePkg`) whose method parameter is `IfacePkg.Msg`, a union ALSO declared
// in `IfacePkg`.  Before the fix, `ImplPkg.main`'s bare package-qualified
// construction `IfacePkg.Text(value = ...)` resolved through the bundle-wide
// first-wins `ctors` bare-name entry instead of the full dotted path, so it
// could pick up an unrelated same-named case from any other bundled package
// (the live repro hit `Std.Xml.XmlNode$Text`) — `NoClassDefFoundError` at
// runtime with no compile error.
test "cross-package impl method with third-package union parameter dispatches correctly" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package IfacePkg\n" + "\n" + "pub union Msg {\n" + "  case Text(value: String)\n" + "  case Ping\n" + "}\n" + "\n" +
      "pub interface Handler {\n" +
      "  func onMessage(msg: in Msg): String\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package ImplPkg\n" + "\n" + "import IfacePkg\n" + "\n" + "pub record EchoHandler {\n" + "}\n" + "\n" +
      "impl IfacePkg.Handler for EchoHandler {\n" +
      "  func onMessage(msg: in IfacePkg.Msg): String {\n" +
      "    match msg {\n" +
      "      case IfacePkg.Text(v) -> \"text:\" + v\n" +
      "      case IfacePkg.Ping -> \"ping\"\n" +
      "    }\n" +
      "  }\n" +
      "}\n" +
      "\n" +
      "func main(): Int {\n" +
      "  val h = EchoHandler()\n" +
      "  println(h.onMessage(msg = IfacePkg.Text(value = \"hello\")))\n" +
      "  println(h.onMessage(msg = IfacePkg.Ping))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-impl-iface", pkgSrcs, "ImplPkg")
  assertEqualInt(result.exitCode, 0, "cross_package_impl_third_package_union: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "text:hello\nping",
    "cross_package_impl_third_package_union: onMessage dispatches to the real IfacePkg.Msg cases"
  )
}

// A package-qualified bare construction (`IfacePkg.Text(value = ...)`) must
// resolve through the full dotted path even with NO impl/interface involved
// — the minimal repro that isolated #5455 from the impl-method machinery.
test "package-qualified case construction resolves to the declaring package, not a same-named bundled case" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package QualCtorPkg\n" + "\n" + "pub union Msg {\n" + "  case Text(value: String)\n" + "}\n")
  pkgSrcs.add(
    "package QualCtorApp\n" + "\n" + "import QualCtorPkg\n" + "\n" + "func main(): Int {\n" +
      "  val m = QualCtorPkg.Text(value = \"hi\")\n" +
      "  match m {\n" +
      "    case QualCtorPkg.Text(v) -> println(v)\n" +
      "  }\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-qual-ctor", pkgSrcs, "QualCtorApp")
  assertEqualInt(result.exitCode, 0, "qualified_construction_resolves: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "hi",
    "qualified_construction_resolves: constructs and matches QualCtorPkg's own case"
  )
}

// ─── #5976: a file that both IMPORTS a package and declares its OWN type of
// the identical simple name must resolve its own bare references to its OWN
// declaration, not the import's ─────────────────────────────────────────────
// Mirrors the real-world `Std.RegexSafe` shape: `SafePkg` imports `BasePkg`
// (which declares its own `AppError` union) while ALSO declaring its own
// `AppError` union sharing a case name (`TimedOut`) with `BasePkg`'s.
// Before the fix, `SafePkg.errorMessage`'s OWN signature (`e: AppError`)
// resolved the bare `AppError` reference through the import's declared-type
// seed instead of `SafePkg`'s own declaration, so the emitted method
// descriptor named `BasePkg`'s class — a cross-package type mismatch
// surfacing as `ClassCastException`/`NoSuchMethodError` at runtime.
test "a file's own declared type is not shadowed by a same-named type it imports" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package BasePkg\n" + "\n" + "pub union AppError {\n" + "  case TimedOut(message: String)\n" +
      "  case BaseBug(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func baseErrorMessage(e: in AppError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"base-timeout: \" + m\n" +
      "    case BaseBug(m) -> \"base-bug: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package SafePkg\n" + "\n" + "import BasePkg\n" + "\n" + "pub union AppError {\n" +
      "  case TimedOut(message: String)\n" +
      "  case SafeBug(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func errorMessage(e: in AppError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"safe-timeout: \" + m\n" +
      "    case SafeBug(m) -> \"safe-bug: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package XPkgApp\n" + "\n" + "import SafePkg as Safe\n" + "\n" + "func main(): Int {\n" +
      "  println(Safe.errorMessage(Safe.TimedOut(message = \"x\")))\n" +
      "  println(Safe.errorMessage(Safe.SafeBug(message = \"y\")))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-own-shadow", pkgSrcs, "XPkgApp")
  assertEqualInt(result.exitCode, 0, "own_type_not_shadowed_by_import: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "safe-timeout: x\nsafe-bug: y",
    "own_type_not_shadowed_by_import: SafePkg.errorMessage resolves its OWN AppError, not BasePkg's"
  )
}

// ─── #5976 (literal repro shape): a THIRD file that imports (via alias) TWO
// SEPARATE packages, each declaring its own same-simple-name union AND a
// same-named free function, must resolve each aliased call against the
// package IT actually names — never a same-named case/function from the
// OTHER aliased package ────────────────────────────────────────────────────
// Mirrors the real-world `Std.Regex/Std.RegexSafe` shape from issue #5976:
// `lyric-stdlib/tests/regex_safe_tests.l` imports `Std.Regex as Re` and
// `Std.RegexSafe as Rx`, both exporting a `RegexError` union with same-named
// cases (`TimedOut`) and both exporting `errorMessage(e: in RegexError):
// String`. `Rx.errorMessage(RegexBug(...))` constructed
// `Std.RegexSafe.RegexError$RegexBug` but dispatched to whichever package's
// `errorMessage` the bundle-wide bare-name registry happened to register
// first — a `ClassCastException` at runtime with no compile error. Unlike
// the "own type not shadowed by import" test above, NEITHER package here is
// the consuming file's own declaration — the collision is entirely between
// two IMPORTED packages, reached only via their respective aliases.
test "aliased calls into two same-simple-name colliding packages each resolve to their own package" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package RegexLikePkg\n" + "\n" + "pub union XError {\n" + "  case TimedOut(message: String)\n" +
      "  case InvalidX(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func errorMessage(e: in XError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"regex-timeout: \" + m\n" +
      "    case InvalidX(m) -> \"regex-invalid: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package RegexSafeLikePkg\n" + "\n" + "pub union XError {\n" + "  case TimedOut(message: String)\n" +
      "  case XBug(message: String)\n" +
      "}\n" +
      "\n" +
      "pub func errorMessage(e: in XError): String {\n" +
      "  match e {\n" +
      "    case TimedOut(m) -> \"safe-timeout: \" + m\n" +
      "    case XBug(m) -> \"safe-bug: \" + m\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package AliasedConsumerApp\n" + "\n" + "import RegexLikePkg as Re\n" + "import RegexSafeLikePkg as Rx\n" + "\n" +
      "func main(): Int {\n" +
      "  println(Rx.errorMessage(Rx.TimedOut(message = \"a\")))\n" +
      "  println(Rx.errorMessage(Rx.XBug(message = \"b\")))\n" +
      "  println(Re.errorMessage(Re.TimedOut(message = \"c\")))\n" +
      "  println(Re.errorMessage(Re.InvalidX(message = \"d\")))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-aliased-collision", pkgSrcs, "AliasedConsumerApp")
  assertEqualInt(result.exitCode, 0, "aliased_cross_package_collision: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "safe-timeout: a\nsafe-bug: b\nregex-timeout: c\nregex-invalid: d",
    "aliased_cross_package_collision: each aliased call resolves its own package's XError/errorMessage"
  )
}

// ─── Transitive extern-type visibility: a generic-returning function whose
// payload type is an `extern type` declared in a package ONLY imported by an
// intermediate package (never by the consuming file) must still resolve at
// the match-bind site ───────────────────────────────────────────────────────
// Mirrors the OTHER half of the real-world `Std.RegexSafe` shape:
// `Std.RegexSafe.tryCompile(): Result[Std.RegexHost.Regex, RegexError]` —
// `Regex` is `extern type Regex = "java.util.regex.Pattern"`, declared in
// `Std.RegexHost`, which `Std.RegexSafe` imports directly but the CONSUMING
// file (`lyric-stdlib/tests/regex_safe_tests.l`) never does (it only imports
// `Std.RegexSafe`). Before the fix, `Jvm.Bridge.externSeedForFile` only
// seeded a package's extern-type map into a file's own `externTypes` when
// that file DIRECTLY imported the declaring package, so binding
// `case Full(b) -> ...` in the consuming file resolved `HostPkg3.Builder`'s
// erased payload as "a user type in my OWN package" (`NoClassDefFoundError`
// at class-load) instead of the real extern-mapped JVM class.
//
// Uses a hand-rolled generic union (`MyBox[T]`) rather than `Std.Core`'s
// `Result`/`Option` — `compileAndRunJvm` (unlike `compileAndRunWithStdlib`
// in the MSIL analogue, `msil_project_bridge_self_test.l`) passes no
// `stdlibSources`, so `Std.Core` itself is never bundled here. `MyBox[T]`
// exercises the identical `retGenericArgs`/match-bind machinery a real
// `Result[T, E]` would (a generic union's payload carrying a cross-package
// extern type) without needing that extra plumbing.
test "extern type reachable only via an intermediate package's re-exported function resolves at the bind site" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package HostPkg3\n" + "\n" + "extern type Builder = \"java.lang.StringBuilder\"\n" + "\n" +
      "pub func newBuilder(): Builder = Builder.new()\n" +
      "\n" +
      "pub func appendStr(b: in Builder, s: in String): Builder {\n" +
      "  b.append(s)\n" +
      "  b\n" +
      "}\n" +
      "\n" +
      "pub func builderToString(b: in Builder): String {\n" +
      "  b.toString()\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package MidPkg3\n" + "\n" + "import HostPkg3\n" + "\n" + "pub union MyBox[T] {\n" + "  case Full(value: T)\n" +
      "  case Empty\n" +
      "}\n" +
      "\n" +
      "pub func tryMake(s: in String): MyBox[HostPkg3.Builder] {\n" +
      "  Full(value = HostPkg3.appendStr(HostPkg3.newBuilder(), s))\n" +
      "}\n" +
      "\n" +
      "pub func show(b: in HostPkg3.Builder): String {\n" +
      "  HostPkg3.builderToString(b)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package ConsumerApp3\n" + "\n" + "import MidPkg3\n" + "\n" + "func main(): Int {\n" +
      "  match MidPkg3.tryMake(\"hello\") {\n" +
      "    case Full(b) -> println(MidPkg3.show(b))\n" +
      "    case Empty -> println(\"empty\")\n" +
      "  }\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-transitive-extern", pkgSrcs, "ConsumerApp3")
  assertEqualInt(result.exitCode, 0, "transitive_extern_type_resolves: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "hello",
    "transitive_extern_type_resolves: the Full(b) bind resolves HostPkg3.Builder to java.lang.StringBuilder"
  )
}

// ─── #6664: same-simple-name range subtype `from`/`tryFrom` collision — the
// range-subtype analog of the #5976 union-case collision above ─────────────
// `AgeLoPkg` and `AgeHiPkg` each declare their OWN `type Age = Int range …`
// with the SAME simple name (`Age`) but DISJOINT ranges, and each package's
// OWN `classify` function calls its OWN bare `Age.from(x)` — never
// qualifying the package, exactly the shape that used to collide.  Before
// the fix, `Jvm.Codegen.collectFileSigsSeeded` registered BOTH packages'
// `from`/`tryFrom` static factories under the identical bundle-global
// `"Age.from"`/`"Age.tryFrom"` key (first-registered-wins), so ONE of the
// two packages' `classify` calls silently validated against the OTHER
// package's range bounds instead of its own.  Because the two ranges are
// DISJOINT (`[0, 10]` vs. `[100, 200]`), a collision is directly observable:
// whichever package's registration lost would `panic` (`Age.from` throws
// `RuntimeException` on a range violation) validating a value that is
// genuinely in ITS OWN declared range but not in the OTHER package's —
// crashing the whole program with a non-zero exit instead of the expected
// "5\n150" output.  A minimal hand-rolled `Std.Core` package (`Result`/
// `Ok`/`Err` only) is included even though the test only calls `from` (never
// `tryFrom`): `Jvm.Lowering.lowerDistinctType` unconditionally emits BOTH
// `from` AND `tryFrom` on every distinct type, and the JVM verifies EVERY
// method's bytecode at class-LOAD time (not lazily per invocation) — so
// `Age`'s never-called `tryFrom` (which references `Std/Core/Result$Ok`/
// `Std/Core/Result$Err`) still needs those classes to exist in the bundle,
// or `AgeLoPkg`/`AgeHiPkg` fail to load at all (`NoClassDefFoundError:
// Std/Core/Result`) before `classify` ever runs.  `compileAndRunJvm` bundles
// no real stdlib sources, so this file supplies the minimal shape needed —
// its case-class names (`Std/Core/Result$Ok`/`$Err`) are exactly what the
// hardcoded `poolMethodref` references in `lowerDistinctTryFrom` expect,
// regardless of whether a real `Std.Core` is ever imported.
test "same-simple-name range subtype: each package's from() validates against its OWN range (#6664)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package Std.Core\n" + "\n" + "pub union Result[T, E] {\n" + "  case Ok(value: T)\n" + "  case Err(error: E)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package AgeLoPkg\n" + "\n" + "import Std.Core\n" + "\n" + "type Age = Int range 0 ..= 10\n" + "\n" +
      "pub func classify(x: Int): Int {\n" +
      "  Age.from(x).toInt()\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package AgeHiPkg\n" + "\n" + "import Std.Core\n" + "\n" + "type Age = Int range 100 ..= 200\n" + "\n" +
      "pub func classify(x: Int): Int {\n" +
      "  Age.from(x).toInt()\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package AgeCollisionApp\n" + "\n" + "import AgeLoPkg\n" + "import AgeHiPkg\n" + "\n" + "func main(): Int {\n" +
      "  println(AgeLoPkg.classify(5))\n" +
      "  println(AgeHiPkg.classify(150))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("xpkg-age-collision", pkgSrcs, "AgeCollisionApp")
  assertEqualInt(
    result.exitCode,
    0,
    "range_subtype_collision: exit 0 — a collision panics validating 5 or 150 against the WRONG package's range (stderr=" +
      result.stderr +
      ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "5\n150",
    "range_subtype_collision: AgeLoPkg.classify(5) and AgeHiPkg.classify(150) each validate against their OWN range"
  )
}

// ─── #6689 JVM parity: a record field's type must resolve under the
// DECLARING package's own scope, not the caller's ───────────────────────────
// The MSIL analogue of this fix (`msil_project_bridge_self_test.l`'s
// "qualified generic type argument in a record field resolves to the exact
// package named") closed two independent bugs: a type-checker
// `collectCtorFields` scope bug (shared — `Lyric.TypeChecker` is the single
// checker both backends call through) and an MSIL-only codegen bug in
// `typeExprToMsilCtx`. JVM codegen was already confirmed unaffected by the
// second bug (it resolves through the checker's own resolved `Type`, not by
// re-deriving FQNs from source text), but there was no dedicated end-to-end
// JVM test pinning the shared type-checker fix on this target — this closes
// that gap. `Pkg6689EJvm` declares `Item`; `Pkg6689FJvm` declares an
// unrelated same-named `Item`; `Wrapper.item: Item` (declared in
// `Pkg6689EJvm`) must resolve `Item` against `Pkg6689EJvm`'s own scope even
// when constructed from a caller that also imports the colliding package.
// (A generic field type such as `List[Item]`/`Box[Item]` would exercise the
// identical `collectCtorFields` code path — the field type is resolved the
// same way regardless of arity — but hits an unrelated, pre-existing JVM
// generics-erasure limitation on match-binding a hand-rolled generic
// union's payload field without a real `Std.Collections` bundle available
// to this file's `compileAndRunJvm`; a bare field keeps this test isolated
// to the #6689 fix.)
test "qualified record field type resolves to the exact package named (JVM parity, #6689)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package Pkg6689EJvm\n" + "\n" + "pub record Item {\n" + "  x: Int\n" + "}\n" + "\n" + "pub record Wrapper {\n" +
      "  item: Item\n" +
      "}\n" +
      "\n" +
      "pub func wrap(x: in Int): Wrapper {\n" +
      "  Wrapper(item = Item(x = x))\n" +
      "}\n" +
      "\n" +
      "pub func itemX(w: in Wrapper): Int {\n" +
      "  w.item.x\n" +
      "}\n"
  )
  pkgSrcs.add("package Pkg6689FJvm\n" + "\n" + "pub record Item {\n" + "  name: String\n" + "}\n")
  pkgSrcs.add(
    "package Main6689Jvm\n" + "\n" + "import Pkg6689FJvm\n" + "import Pkg6689EJvm\n" + "\n" + "func main(): Int {\n" +
      "  val w = Pkg6689EJvm.wrap(x = 7)\n" +
      "  println(Pkg6689EJvm.itemX(w))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("qualified-record-field-6689-jvm", pkgSrcs, "Main6689Jvm")
  assertEqualInt(result.exitCode, 0, "qualified_record_field_jvm: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "7",
    "qualified_record_field_jvm: record field Item resolved to Pkg6689EJvm's Item, not Pkg6689FJvm's"
  )
}

// ─── Regression: qualified record construction survives a local shadowing
// only the package's first segment — JVM parity (#6838) ────────────────────
// The MSIL analogue of this fix (`msil_project_bridge_self_test.l`'s
// "qualified record construction survives a local shadowing only the
// package's first segment") closed a gap in `lowerMethodCallMsil`. Since
// `Lyric.AliasRewriter` (whose shadow-defeat is the actual root cause — see
// D-progress-871) is shared between the MSIL and JVM pipelines, and JVM's
// own `lowerMethodCall` (`lyric-compiler/jvm/codegen/04_calls.l`) had the
// identical gap (a union-case construction fallback but none for a plain
// record), this pins the same fix on `--target jvm`: a local named
// `QualRecShadow` (the imported package's own first segment) sits in scope
// while the function still constructs `QualRecShadow.Sub.Rec(...)` by its
// full qualified path.
test "qualified record construction survives a local shadowing only the package's first segment (JVM parity, #6838)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package QualRecShadowJvm.Sub\n" + "\n" + "pub record Rec { message: String }\n")
  pkgSrcs.add(
    "package QualRecShadowJvm.App\n" + "\n" + "import QualRecShadowJvm.Sub\n" + "\n" + "func main(): Int {\n" +
      "  val QualRecShadowJvm = 0\n" +
      "  val e = QualRecShadowJvm.Sub.Rec(message = \"boom\")\n" +
      "  println(e.message)\n" +
      "  println(QualRecShadowJvm)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("qualrecshadow-jvm", pkgSrcs, "QualRecShadowJvm.App")
  assertEqualInt(
    result.exitCode,
    0,
    "qualified_record_construction_survives_shadowed_first_segment_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "boom\n0",
    "qualified_record_construction_survives_shadowed_first_segment_jvm: stdout matches expected"
  )
}

test "qualified function call survives a local shadowing only the package's first segment (JVM parity, D359)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package QualFnShadowJvm.Sub\n" + "\n" + "pub func answer(x: Int): Int {\n" + "  x + 40\n" + "}\n")
  pkgSrcs.add(
    "package QualFnShadowJvm.App\n" + "\n" + "import QualFnShadowJvm.Sub\n" + "\n" + "func main(): Int {\n" +
      "  val QualFnShadowJvm = 0\n" +
      "  println(QualFnShadowJvm.Sub.answer(2))\n" +
      "  println(QualFnShadowJvm)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("qualfnshadow-jvm", pkgSrcs, "QualFnShadowJvm.App")
  assertEqualInt(
    result.exitCode,
    0,
    "qualified_function_call_survives_shadowed_first_segment_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "42\n0",
    "qualified_function_call_survives_shadowed_first_segment_jvm: stdout matches expected"
  )
}

test "qualified function call survives a Unit local shadowing the package's first segment (JVM, D359)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package QualUnitShadowJvm.Sub\n" + "\n" + "pub func answer(x: Int): Int {\n" + "  x + 40\n" + "}\n")
  pkgSrcs.add(
    "package QualUnitShadowJvm.App\n" + "\n" + "import QualUnitShadowJvm.Sub\n" + "\n" + "func main(): Int {\n" +
      "  val QualUnitShadowJvm = ()\n" +
      "  println(QualUnitShadowJvm.Sub.answer(2))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("qualunitshadow-jvm", pkgSrcs, "QualUnitShadowJvm.App")
  assertEqualInt(
    result.exitCode,
    0,
    "qualified_function_call_survives_unit_shadow_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "42",
    "qualified_function_call_survives_unit_shadow_jvm: stdout matches expected"
  )
}

// ─── #6972 JVM parity: a union case's field type must resolve under the
// case's OWN declaring package, not the caller's ───────────────────────────
// The MSIL analogue of this fix (`msil_project_bridge_self_test.l`'s
// "union case field type resolves to the exact package named, not the
// caller's scope (#6972)") closed a gap in the shared `Lyric.TypeChecker`'s
// `unionCaseFieldTypes` — the same function both `Msil.Bridge` and
// `Jvm.Bridge` type-check through. JVM codegen was already confirmed to
// resolve a pattern-bound local's type through the checker's own resolved
// `Type` (not by re-deriving it independently, unlike MSIL for this
// construct), so this end-to-end JVM test pins the shared fix on this
// target too, matching this file's existing JVM-parity precedent for the
// sibling record-field fix above.
test "union case field type resolves to the exact package named, not the caller's scope (JVM parity, #6972)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package Pkg6972OwnerJvm\n" + "\n" + "pub record Item {\n" + "  x: Int\n" + "}\n" + "\n" + "pub union Box {\n" +
      "  case Full(tag: Item)\n" +
      "}\n" +
      "\n" +
      "pub func mk(x: in Int): Box {\n" +
      "  Full(tag = Item(x = x))\n" +
      "}\n" +
      "\n" +
      "pub func needsItem(i: in Item): Int {\n" +
      "  i.x\n" +
      "}\n"
  )
  pkgSrcs.add("package Pkg6972CollideJvm\n" + "\n" + "pub record Item {\n" + "  name: String\n" + "}\n")
  pkgSrcs.add(
    "package Main6972Jvm\n" + "\n" + "import Pkg6972OwnerJvm\n" + "import Pkg6972CollideJvm\n" + "\n" +
      "func main(): Int {\n" +
      "  val b = Pkg6972OwnerJvm.mk(x = 7)\n" +
      "  match b {\n" +
      "    case Pkg6972OwnerJvm.Full(tag) -> println(Pkg6972OwnerJvm.needsItem(tag))\n" +
      "  }\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("union-case-field-6972-jvm", pkgSrcs, "Main6972Jvm")
  assertEqualInt(result.exitCode, 0, "union_case_field_jvm_6972: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "7",
    "union_case_field_jvm_6972: tag binds to Pkg6972OwnerJvm's Item, not Pkg6972CollideJvm's (needsItem(tag) == 7)"
  )
}

// #6580: `pipeIsCrossPackageItem` (the shared cross-package item-visibility
// filter `Lyric.Pipeline` — and, before this fix, `Jvm.Bridge`/`Msil.Bridge`/
// `Lyric.LlvmBridge` — used for a project's OWN sibling packages) only ever
// admitted `pub` functions. `internal` is documented (docs/01 §3.1) as
// visible across every package WITHIN THE SAME PROJECT, but a qualified
// cross-package call to an `internal` function used to fail T0020 "unknown
// name" on all three backends because the callee's OWN package never
// contributed its `internal` items to a sibling's checked view at all.
test "qualified call to an internal cross-package function resolves (JVM, #6580)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package Pkg6580A\n" + "\n" + "pub record Handle {\n" + "  id: Int\n" + "}\n" + "\n" +
      "internal func wrapHandle(id: in Int): Handle {\n" +
      "  Handle(id = id)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package Pkg6580B\n" + "\n" + "import Pkg6580A\n" + "\n" + "func main(): Int {\n" +
      "  val h = Pkg6580A.wrapHandle(id = 7)\n" +
      "  println(h.id)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("internal-qualified-call-6580", pkgSrcs, "Pkg6580B")
  assertEqualInt(result.exitCode, 0, "internal_qualified_call_6580: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "7",
    "qualified call to an internal cross-package function returns the right value"
  )
}

// D336: a bare call binds to the function the checker resolved it to.
// `XJSite.Priv` is imported first and declares a package-private `pick` (not
// visible to `XJSite.App`) beside a `pub` caller of it; `XJSite.Pub` declares
// the `pub` `pick` the call means.
test "a bare call binds to the checker's callee, not a same-named private function (JVM, D336)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package XJSite.Priv\n" + "\n" + "func pick(x: in Int): Int { x + 100 }\n" + "\n" +
      "pub func other(x: in Int): Int { pick(x) }\n"
  )
  pkgSrcs.add("package XJSite.Pub\n" + "\n" + "pub func pick(x: in Int): Int { x + 1 }\n")
  pkgSrcs.add(
    "package XJSite.App\n" + "\n" + "import XJSite.Priv\n" + "import XJSite.Pub\n" + "\n" + "func main(): Int {\n" +
      "  println(pick(1))\n" +
      "  println(other(1))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("site-callee-jvm", pkgSrcs, "XJSite.App")
  assertEqualInt(result.exitCode, 0, "site_callee_jvm: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "2\n101",
    "site_callee_jvm: pick is the pub one, other reaches its own private pick"
  )
}

// Issue #6853: the bundle-wide bare-call fallback (`ctx.funcSigs`'s unscoped
// bare-name keys, consulted by `resolveGeneralFuncSig`, `04_calls.l`) must
// NEVER select a package-private function in an unrelated, unimported
// package — the same privacy gap MSIL closed for its own bundle-wide
// fallback in #6850/#6851. `XPriv.Priv` (registered FIRST, so it would win a
// visibility-blind first-wins race) declares a package-private `func helper`
// returning -999; `XPriv.Sub` declares the legitimate `pub func helper`
// returning its argument; the entry package imports only the facade that
// re-exports `Sub` (`pub use`, D311), and calls `helper` bare. The private declarer must be
// excluded from the bundle-wide bare keys at registration time, leaving
// `Sub.helper` the only candidate.
test "bundle-wide bare-call fallback never selects a package-private function (JVM, #6853)" {
  val pkgSrcs: List[String] = newList()
  // Registered FIRST so it would win a visibility-blind first-wins race.
  pkgSrcs.add("package XPriv.Priv\n" + "\n" + "func helper(x: in Int): Int {\n" + "  0 - 999\n" + "}\n")
  pkgSrcs.add("package XPriv.Sub\n" + "\n" + "pub func helper(x: in Int): Int {\n" + "  x\n" + "}\n")
  pkgSrcs.add(
    "package XPriv.Facade\n" + "\n" + "pub use XPriv.Sub\n" + "\n" + "pub func facadeFn(): Int {\n" +
      "  XPriv.Sub.helper(x = 0)\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package XPriv.App\n" + "\n" + "import XPriv.Facade\n" + "\n" + "func main(): Int {\n" +
      "  println(helper(x = 42))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("bare-call-skips-private-6853", pkgSrcs, "XPriv.App")
  assertEqualInt(result.exitCode, 0, "bare_call_skips_package_private: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "42",
    "bare_call_skips_package_private: resolves the pub target, never the private -999"
  )
}

// A same-package bare call to a package-private function must keep working
// after #6853's fix: package-private access is always legal from within its
// own declaring package, and the new package-scoped key
// (`owner::name`/`owner::name@arity`, `06_items.l`) covers that path since
// the function is no longer registered under the plain bundle-wide bare key.
test "same-package bare call to a package-private function still resolves (JVM, #6853)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package XPrivSame.App\n" + "\n" + "func helper(x: in Int): Int {\n" + "  x + 1\n" + "}\n" + "\n" +
      "func main(): Int {\n" +
      "  println(helper(x = 41))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("bare-call-same-package-private-6853", pkgSrcs, "XPrivSame.App")
  assertEqualInt(result.exitCode, 0, "bare_call_same_package_private: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "42",
    "bare_call_same_package_private: same-package bare call to a package-private function still resolves"
  )
}

// Issue #7206: a bare first-class reference to a function (`apply(helper, 41)`)
// resolves to the REFERENCING package's own function, never to an unrelated
// package's private one.  `XRef.Priv` (registered first) declares a
// package-private two-parameter `helper`; `XRef.App` declares its own
// one-parameter `helper` and passes it by name.  The "bareref:" registry key
// is bundle-wide and first-wins, but the forwarding closure re-resolves the
// call through the caller's own scope, so the private overload never leaks;
// this test pins that.
test "bare function reference resolves to the caller's own package, never another's private function (JVM, #7206)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package XRef.Priv\n" + "\n" + "func helper(a: in Int, b: in Int): Int {\n" + "  a - b\n" + "}\n")
  pkgSrcs.add(
    "package XRef.App\n" + "\n" + "func helper(x: in Int): Int {\n" + "  x + 1\n" + "}\n" + "\n" +
      "func apply(f: in (Int) -> Int, v: in Int): Int {\n" +
      "  f(v)\n" +
      "}\n" +
      "\n" +
      "func main(): Int {\n" +
      "  println(apply(helper, 41))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("bare-func-ref-private-7206", pkgSrcs, "XRef.App")
  assertEqualInt(result.exitCode, 0, "bare_func_ref_private: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "bare_func_ref_private: the caller's own one-parameter helper")
}

// Review follow-up (#7147): #6853's fix must never let the new package-scoped
// key hijack an explicitly-QUALIFIED call. `XScoped.App` both declares its
// OWN `helper` (returning -999) AND makes a fully-qualified call to
// `XScoped.Other.helper` (returning its argument). Before the fix, the
// unconditional scoped-key pre-check ran ahead of the qualified-path branch
// in `resolveGeneralFuncSig` (`04_calls.l`) and silently redirected the
// qualified call to the caller's own same-named local function.
test "qualified call to another package's function is not hijacked by the caller's own same-named local (JVM, #7147)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add("package XScoped.Other\n" + "\n" + "pub func helper(x: in Int): Int {\n" + "  x\n" + "}\n")
  pkgSrcs.add(
    "package XScoped.App\n" + "\n" + "import XScoped.Other\n" + "\n" + "func helper(x: in Int): Int {\n" + "  0 - 999\n" +
      "}\n" +
      "\n" +
      "func main(): Int {\n" +
      "  println(XScoped.Other.helper(x = 42))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("qualified-call-not-hijacked-7147", pkgSrcs, "XScoped.App")
  assertEqualInt(result.exitCode, 0, "qualified_call_not_hijacked: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "42",
    "qualified_call_not_hijacked: resolves the qualified XScoped.Other.helper, not the caller's own local -999"
  )
}

// #7811: a default declared in one package and used by a call or
// construction in another widens like the declaring package's own uses.  The
// entry package's code is generated before the declaring package's middle
// end runs, so its registered defaults must already carry the conversion.
test "another package's parameter and field defaults zero-extend a UInt (JVM, #7811)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package XDefault.Lib\n" + "\n" + "pub val gu: UInt = 4000000000u32\n" + "\n" + "pub record Cfg {\n" + "  n: Int\n" +
      "  u: ULong = gu\n" +
      "}\n" +
      "\n" +
      "pub func widened(x: in ULong = gu): ULong {\n" +
      "  x\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package XDefault.App\n" + "\n" + "import XDefault.Lib\n" + "\n" + "func main(): Int {\n" +
      "  println(toString(widened()))\n" +
      "  val c = Cfg(n = 1)\n" +
      "  println(toString(c.u))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("cross-package-default-widening-7811", pkgSrcs, "XDefault.App")
  assertEqualInt(result.exitCode, 0, "cross_package_default_widening: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "4000000000\n4000000000", "both defaults zero-extend")
}

// #7820: a call from another package that omits a method's defaulted
// argument splices the default the method declares, with its conversion.
test "another package's method defaults are spliced into a call (JVM, #7820)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package XMethodDefault.Lib\n" + "\n" + "pub val gu: UInt = 4000000000u32\n" + "\n" + "pub record Acc {\n" +
      "  n: Int\n" +
      "  func add(self: in Acc, x: in Int = 5): Int {\n" +
      "    self.n + x\n" +
      "  }\n" +
      "  func wide(self: in Acc, x: in ULong = gu): ULong {\n" +
      "    x\n" +
      "  }\n" +
      "}\n" +
      "\n" +
      "pub interface Shape {\n" +
      "  func area(self: in Self, scale: in Int = 2): Int\n" +
      "}\n" +
      "\n" +
      "pub record Sq {\n" +
      "  s: Int\n" +
      "}\n" +
      "\n" +
      "impl Shape for Sq {\n" +
      "  func area(self: in Sq, scale: in Int = 3): Int {\n" +
      "    self.s * scale\n" +
      "  }\n" +
      "}\n"
  )
  pkgSrcs.add(
    "package XMethodDefault.App\n" + "\n" + "import XMethodDefault.Lib\n" + "\n" + "func areaOf(sh: in Shape): Int {\n" +
      "  sh.area()\n" +
      "}\n" +
      "\n" +
      "func main(): Int {\n" +
      "  val a = Acc(n = 1)\n" +
      "  println(toString(a.add()))\n" +
      "  println(toString(a.wide()))\n" +
      "  println(toString(Sq(s = 4).area()))\n" +
      "  println(toString(areaOf(Sq(s = 4))))\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("cross-package-method-default-7820", pkgSrcs, "XMethodDefault.App")
  assertEqualInt(result.exitCode, 0, "cross_package_method_default: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "6\n4000000000\n12\n8", "each call takes the default it resolves through")
}

// #7777: an importer reads another package's unannotated `pub val` over a
// private helper at the type the declaring package checked, with no
// annotation on the val (the MSIL twin lives in
// `msil_project_bridge_self_test.l`).
test "an unannotated pub val over a private helper is readable from another package (JVM, #7777)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package XVal7777.Lib\n" + "\n" + "func helper(): Int {\n" + "  41\n" + "}\n" + "\n" + "func greeting(): String {\n" +
      "  \"hi\"\n" +
      "}\n" +
      "\n" +
      "pub val answer = helper() + 1\n" +
      "pub val hello = greeting() + \"!\"\n"
  )
  pkgSrcs.add(
    "package XVal7777.App\n" + "\n" + "import XVal7777.Lib\n" + "\n" + "func main(): Int {\n" +
      "  println(toString(answer))\n" +
      "  println(toString(answer + 1))\n" +
      "  println(hello)\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("cross-package-unannotated-val-7777", pkgSrcs, "XVal7777.App")
  assertEqualInt(result.exitCode, 0, "unannotated_pub_val: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42\n43\nhi!", "read at the declaring package's checked type")
}

// ─────────────────────────────────────────────────────────────────────────────
// Constructor and function names shared across packages by declarations of
// different kinds (#9130), the JVM analogue of the same section of
// `msil_project_bridge_self_test.l`.
//
// `Col.A` and `Col.Z` do not import each other and reuse each other's names
// for another kind of declaration (case/record, case/function, record/record
// with another layout, case/case of another union, generic case/record,
// generic record/case, function/case, enum case/enum case at another ordinal,
// distinct type/case).  A call is bound by the package it is written in: its
// own declaration of any kind, then an imported package's, and only then the
// bundle-wide name.  A bare name looked up bundle-wide first built another
// package's union case where the caller meant its own function (`Token(10)`),
// a `VerifyError`, or called the function where a case was meant, a
// `ClassCastException`.  Every package order is built: which declaration holds
// the bundle-wide name depends on it.
// ─────────────────────────────────────────────────────────────────────────────
// Package Col.A: a case, record, generic case, generic record, function, enum and
// distinct type whose names Col.Z declares as something else.
func collisionSrcA(): String {
  "package Col.A\n" + "\n" + "import Std.Core\n" + "\n" + "pub union Outcome {\n" + "  case Taken\n" +
    "  case Held(freed: Int)\n" +
    "  case Marker(tag: Int)\n" +
    "}\n" +
    "\n" +
    "pub record Widget {\n" +
    "  id: Int\n" +
    "}\n" +
    "\n" +
    "pub union Shape {\n" +
    "  case Circle(r: Int)\n" +
    "  case Square(side: Int)\n" +
    "}\n" +
    "\n" +
    "pub union Wrap[T] {\n" +
    "  case Full(v: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "pub record Pair[T] {\n" +
    "  left: T\n" +
    "  right: T\n" +
    "}\n" +
    "\n" +
    "pub func Token(n: in Int): Int {\n" +
    "  n * 2\n" +
    "}\n" +
    "\n" +
    "pub enum Color {\n" +
    "  case Red\n" +
    "  case Green\n" +
    "}\n" +
    "\n" +
    "type Meters = Int\n" +
    "\n" +
    "pub func runA(): Int {\n" +
    "  val o = Held(freed = 3)\n" +
    "  val held = match o {\n" +
    "    case Held(f) -> f\n" +
    "    case Taken -> 0\n" +
    "    case Marker(t) -> t\n" +
    "  }\n" +
    "  val m = match Marker(tag = 4) {\n" +
    "    case Marker(t) -> t\n" +
    "    case _ -> 0\n" +
    "  }\n" +
    "  val w = Widget(id = 5)\n" +
    "  val c = match Circle(r = 6) {\n" +
    "    case Circle(r) -> r\n" +
    "    case Square(s) -> s\n" +
    "  }\n" +
    "  val f = match Full(v = 7) {\n" +
    "    case Full(v) -> v\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "  val p = Pair(left = 8, right = 9)\n" +
    "  val t = Token(10)\n" +
    "  val col = match Green {\n" +
    "    case Red -> 100\n" +
    "    case Green -> 11\n" +
    "  }\n" +
    "  val d = Meters.from(12)\n" +
    "  held + m + w.id + c + f + p.left + p.right + t + col + d.value\n" +
    "}\n"
}

// Package Col.Z: the mirror image of Col.A.
func collisionSrcZ(): String {
  "package Col.Z\n" + "\n" + "import Std.Core\n" + "\n" + "pub ref record Held {\n" + "  var since: Long\n" + "}\n" +
    "\n" +
    "pub func Marker(n: in Int): Int {\n" +
    "  n + 100\n" +
    "}\n" +
    "\n" +
    "pub record Widget {\n" +
    "  id: Int\n" +
    "  weight: Int\n" +
    "}\n" +
    "\n" +
    "pub union Solid {\n" +
    "  case Circle(radius: Long, depth: Long)\n" +
    "  case Cube(edge: Long)\n" +
    "}\n" +
    "\n" +
    "pub record Full {\n" +
    "  amount: Int\n" +
    "}\n" +
    "\n" +
    "pub union Kind {\n" +
    "  case Pair(a: Int)\n" +
    "  case Single\n" +
    "}\n" +
    "\n" +
    "pub union Lex {\n" +
    "  case Token(text: String)\n" +
    "  case End\n" +
    "}\n" +
    "\n" +
    "pub enum Signal {\n" +
    "  case Green\n" +
    "  case Amber\n" +
    "  case Red\n" +
    "}\n" +
    "\n" +
    "pub union Unit2 {\n" +
    "  case Meters(n: Int)\n" +
    "}\n" +
    "\n" +
    "pub func runZ(): Int {\n" +
    "  val h = Held(since = 0i64)\n" +
    "  h.since = 1i64\n" +
    "  val m = Marker(2)\n" +
    "  val w = Widget(id = 3, weight = 4)\n" +
    "  val c = match Circle(radius = 5i64, depth = 6i64) {\n" +
    "    case Circle(r, d) -> (r + d).toInt()\n" +
    "    case Cube(e) -> e.toInt()\n" +
    "  }\n" +
    "  val f = Full(amount = 7)\n" +
    "  val p = match Pair(a = 8) {\n" +
    "    case Pair(a) -> a\n" +
    "    case Single -> 0\n" +
    "  }\n" +
    "  val t = match Token(text = \"nine\") {\n" +
    "    case Token(s) -> s.length\n" +
    "    case End -> 0\n" +
    "  }\n" +
    "  val col = match Green {\n" +
    "    case Green -> 10\n" +
    "    case Amber -> 200\n" +
    "    case Red -> 300\n" +
    "  }\n" +
    "  val u = match Meters(n = 11) {\n" +
    "    case Meters(n) -> n\n" +
    "  }\n" +
    "  h.since.toInt() + m + w.id + w.weight + c + f.amount + p + t + col + u\n" +
    "}\n"
}

// Calls both packages by qualified name only.
func collisionSrcMainQualified(): String {
  "package Col.Main\n" + "\n" + "import Std.Core\n" + "import Col.A\n" + "import Col.Z\n" + "\n" +
    "func main(): Int {\n" +
    "  println(Col.A.runA().toString())\n" +
    "  println(Col.Z.runZ().toString())\n" +
    "  0\n" +
    "}\n"
}

// Imports Col.A alone and uses its names bare, beside a union of its own whose
// case Widget is a record in both other packages.
func collisionSrcMainBare(): String {
  "package Col.Main\n" + "\n" + "import Std.Core\n" + "import Col.A\n" + "\n" + "union Local {\n" +
    "  case Widget(n: Int)\n" +
    "  case Nothing\n" +
    "}\n" +
    "\n" +
    "func main(): Int {\n" +
    "  println(Col.A.runA().toString())\n" +
    "  val o = Held(freed = 21)\n" +
    "  val held = match o {\n" +
    "    case Held(f) -> f\n" +
    "    case Taken -> 0\n" +
    "    case Marker(t) -> t\n" +
    "  }\n" +
    "  val mk = match Marker(tag = 22) {\n" +
    "    case Marker(t) -> t\n" +
    "    case _ -> 0\n" +
    "  }\n" +
    "  val w = match Widget(n = 23) {\n" +
    "    case Widget(n) -> n\n" +
    "    case Nothing -> 0\n" +
    "  }\n" +
    "  val full = match Full(v = 25) {\n" +
    "    case Full(v) -> v\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "  val p = Pair(left = 26, right = 27)\n" +
    "  val t = Token(28)\n" +
    "  val taken = match Taken {\n" +
    "    case Taken -> 29\n" +
    "    case _ -> 0\n" +
    "  }\n" +
    "  println((held + mk + w + full + p.left + p.right + t + taken).toString())\n" +
    "  0\n" +
    "}\n"
}

func collisionSources(order: in String, main: in String): List[String] {
  val srcs: List[String] = newList()
  for part in Str.split(order, " ") {
    if part == "A" {
      srcs.add(collisionSrcA())
    } else if part == "Z" {
      srcs.add(collisionSrcZ())
    } else {
      srcs.add(main)
    }
  }
  srcs
}

test "a union case is not built as an unrelated package's same-named record (#9130)" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(
    "package Cc.Lib\n" + "pub union TakeOutcome {\n  case Taken\n  case Held(freed: Int)\n}\n" +
      "pub func take(n: in Int): TakeOutcome {\n  if n == 0 {\n    Taken\n  } else {\n    Held(freed = n)\n  }\n}\n"
  )
  pkgSrcs.add(
    "package Cc.Main\n" + "ref record Held {\n  var since: Long\n}\n" + "func main(): Int {\n" +
      "  val h = Held(since = 0i64)\n" +
      "  h.since = 5i64\n" +
      "  println(h.since.toInt().toString())\n" +
      "  0\n" +
      "}\n"
  )
  val result = compileAndRunJvm("collision-9130-reported", pkgSrcs, "Cc.Main")
  assertEqualInt(result.exitCode, 0, "exit code (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "5", "Cc.Main.Held is the record; Cc.Lib's case Held(freed) is not in its scope")
}

test "same-named constructors and functions of different kinds resolve in their own package, in every package order (#9130)" {
  for order in ["A M Z", "Z M A", "M A Z", "M Z A", "A Z M", "Z A M"] {
    val result = compileAndRunJvmWithStdlib(
      "collision-9130-qualified",
      collisionSources(order, collisionSrcMainQualified()),
      "Col.Main",
      Emitter.findStdlibSourcesJvm()
    )
    assertEqualInt(result.exitCode, 0, "exit code, package order " + order + " (stderr=" + result.stderr + ")")
    assertEqual(Str.trim(result.stdout), "85\n161", "Col.A.runA() and Col.Z.runZ(), package order " + order)
  }
}

test "bare names of an imported package beat an unimported package's same-named declarations (#9130)" {
  for order in ["A M Z", "Z M A", "M Z A"] {
    val result = compileAndRunJvmWithStdlib(
      "collision-9130-bare",
      collisionSources(order, collisionSrcMainBare()),
      "Col.Main",
      Emitter.findStdlibSourcesJvm()
    )
    assertEqualInt(result.exitCode, 0, "exit code, package order " + order + " (stderr=" + result.stderr + ")")
    assertEqual(Str.trim(result.stdout), "85\n229", "Col.A's names used bare from Col.Main, package order " + order)
  }
}
