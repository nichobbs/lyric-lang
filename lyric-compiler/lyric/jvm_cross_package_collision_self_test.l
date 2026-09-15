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
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val stdlibSources: List[String] = newList()
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
      "  println(Safe.errorMessage(TimedOut(message = \"x\")))\n" +
      "  println(Safe.errorMessage(SafeBug(message = \"y\")))\n" +
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
      "  println(Rx.errorMessage(TimedOut(message = \"a\")))\n" +
      "  println(Rx.errorMessage(XBug(message = \"b\")))\n" +
      "  println(Re.errorMessage(TimedOut(message = \"c\")))\n" +
      "  println(Re.errorMessage(InvalidX(message = \"d\")))\n" +
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
