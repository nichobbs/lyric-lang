//! enum_case_collision_self_test.l — regression test for #5995: cross-package
//! enum case-name collision silently mis-dispatching bare (unqualified) enum
//! case construction and pattern matching on BOTH backends.
//!
//! Two independent fixture packages each declare their own enum with a case
//! literally named `Http11` — `EnumCollA.HttpVersion` (cases `Http10`,
//! `Http11`) and `EnumCollB.ConnState` (cases `Http11`, `Closed`), with
//! DIFFERENT ordinals for `Http11` in each (1 in `HttpVersion`, 0 in
//! `ConnState`) so a misrouted ordinal produces an observably WRONG label
//! rather than a coincidentally-correct one.  A third package (`EnumCollApp`)
//! imports both and exercises the two independently-triggerable halves of
//! the bug against each enum:
//!
//!   1. Bare CASE CONSTRUCTION as a call argument (the issue's literal repro
//!      shape, `serializeResponseHead(Http11, ...)`) — `EnumCollA.labelOf`'s
//!      own declared parameter type must select `HttpVersion`'s `Http11`,
//!      and `EnumCollB.labelOf`'s own declared parameter type must select
//!      `ConnState`'s `Http11`, never the other's.
//!   2. Bare PATTERN MATCH (`case Http11 -> ...`) against a locally-annotated
//!      variable, built via each package's OWN (collision-free) internal
//!      constructor so the match assertion isolates the pattern-test fix
//!      from the construction fix above.
//!
//! Before the fix, every bare `Http11` reference (construction OR pattern)
//! resolved through a single bundle-wide first-registered-wins table keyed
//! by the bare case name alone — MSIL's `enumCaseOrdinals` (an Int ordinal;
//! Lyric enums lower to a bare Int with no distinguishing CLR type) and
//! JVM's `enumcase:` `funcSigs` entries — so whichever enum registered
//! `Http11` first silently won every bare reference in the whole bundle,
//! with no compile error.
//!
//! Compiles each of the three packages above via the in-process self-hosted
//! project bridges (`Msil.Bridge.compileProjectToMsil` for `--target dotnet`,
//! `Jvm.Bridge.compileProjectToJarBundledWithFeatures` for `--target jvm`),
//! runs the produced binary, and asserts on stdout — mirroring
//! `msil_project_bridge_self_test.l` / `jvm_cross_package_collision_self_test.l`,
//! the precedent for genuine cross-package collision regression tests that
//! can't be reproduced within a single `@test_module` package (a source file
//! is one package's worth of declarations, so the colliding enums cannot
//! live in the test file itself).
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/enum_case_collision_self_test.l
@test_module
package Lyric.EnumCaseCollisionSelfTest

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
import Msil.Bridge
import Jvm.Bridge

// ─── Shared fixture sources ─────────────────────────────────────────────────
// `HttpVersion.Http11` is ordinal 1 (Http10 is 0); `ConnState.Http11` is
// ordinal 0 (Closed is 1) — deliberately different so a misrouted ordinal
// prints the WRONG label instead of coincidentally matching.
func pkgASource(): String {
  "package EnumCollA\n" + "\n" + "pub enum HttpVersion {\n" + "  case Http10\n" + "  case Http11\n" + "}\n" + "\n" +
    "pub func labelOf(v: in HttpVersion): String {\n" +
    "  match v {\n" +
    "    case Http10 -> \"A:Http10\"\n" +
    "    case Http11 -> \"A:Http11\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub func make11(): HttpVersion {\n" +
    "  Http11\n" +
    "}\n"
}

func pkgBSource(): String {
  "package EnumCollB\n" + "\n" + "pub enum ConnState {\n" + "  case Http11\n" + "  case Closed\n" + "}\n" + "\n" +
    "pub func labelOf(s: in ConnState): String {\n" +
    "  match s {\n" +
    "    case Http11 -> \"B:Http11\"\n" +
    "    case Closed -> \"B:Closed\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub func make11(): ConnState {\n" +
    "  Http11\n" +
    "}\n"
}

func appSource(): String {
  "package EnumCollApp\n" + "\n" + "import EnumCollA as A\n" + "import EnumCollB as B\n" + "\n" + "func main(): Int {\n" +
    "  // (1) Bare case CONSTRUCTION as a call argument: each callee's own\n" +
    "  // declared parameter type must select its OWN enum's Http11 case.\n" +
    "  println(A.labelOf(Http11))\n" +
    "  println(B.labelOf(Http11))\n" +
    "\n" +
    "  // (2) Bare PATTERN MATCH against a locally-annotated variable, built\n" +
    "  // via each package's own (collision-free) constructor.\n" +
    "  val a3: A.HttpVersion = A.make11()\n" +
    "  val b3: B.ConnState = B.make11()\n" +
    "  match a3 {\n" +
    "    case Http11 -> println(\"match-A:Http11\")\n" +
    "    case Http10 -> println(\"match-A:Http10\")\n" +
    "  }\n" +
    "  match b3 {\n" +
    "    case Http11 -> println(\"match-B:Http11\")\n" +
    "    case Closed -> println(\"match-B:Closed\")\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func expectedStdout(): String {
  "A:Http11\n" + "B:Http11\n" + "match-A:Http11\n" + "match-B:Http11"
}

// ─── Shared temp-dir helpers ─────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-enum-coll-" + label + "-" + uuidToString(newUuid()))
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

// ─── MSIL helpers (mirrors msil_project_bridge_self_test.l's compileAndRun) ──
func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) } else { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

func compileAndRunMsil(
  label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()
  val ok = compileProjectToMsil(packages, assemblyName, dllPath, stdlibSources)
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToMsil returned false")
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  result
}

// ─── JVM helper (mirrors jvm_cross_package_collision_self_test.l) ───────────
func compileAndRunJvm(label: in String, pkgSrcs: in List[String], entryPkgName: in String): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, label + ".jar")
  val stdlibSources: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    entryPkgName,
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    "0.1.0"
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

// ─── Tests ───────────────────────────────────────────────────────────────────
test "dotnet: bare enum-case construction and pattern match resolve against each enum's own package" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("EnumCollA", pkgASource()))
  packages.add(mkPkg("EnumCollB", pkgBSource()))
  packages.add(mkPkg("EnumCollApp", appSource()))
  val result = compileAndRunMsil("enumcoll-dotnet", packages, "EnumCollApp")
  assertEqualInt(result.exitCode, 0, "enum_case_collision dotnet: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedStdout(),
    "enum_case_collision dotnet: bare Http11 construction/match dispatch to the RIGHT enum in both packages"
  )
}

test "jvm: bare enum-case construction and pattern match resolve against each enum's own package" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(pkgASource())
  pkgSrcs.add(pkgBSource())
  pkgSrcs.add(appSource())
  val result = compileAndRunJvm("enumcoll-jvm", pkgSrcs, "EnumCollApp")
  assertEqualInt(result.exitCode, 0, "enum_case_collision jvm: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedStdout(),
    "enum_case_collision jvm: bare Http11 construction/match dispatch to the RIGHT enum in both packages"
  )
}
