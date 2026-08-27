//! enum_case_collision_self_test.l — regression test for #5995: cross-package
//! enum case-name collision silently mis-dispatching enum case construction
//! and pattern matching on BOTH backends. Also covers two MSIL-only findings
//! from the #6595/#6607 review pass, in `registerEnumDeclMsil`'s
//! surrounding code:
//!   - #6638: `registerEnumDeclMsil`'s `enumCaseOrdinalsByPkgType.add` was
//!     unguarded, so a package registered twice (e.g. a restored artifact
//!     resolved twice into `cctx.restoredArtifacts`) crashed the compiler
//!     with a raw `ArgumentException` instead of no-oping the identical
//!     re-registration.
//!   - #6639: the package-qualified pattern-match branch
//!     (`case Pkg.Case ->`) resolved through a bare `pkgName + "." +
//!     caseName` key with no enum TYPE name, so two DIFFERENT enums
//!     declared in the SAME package sharing a case name collided —
//!     first-registered-wins — even though the scrutinee's own declared
//!     type (`scrutEnumHint`) was available to disambiguate, exactly like
//!     it already does for the type-qualified and bare-pattern forms.
//!
//! Three independent fixture packages declare enums that collide two
//! different ways:
//!   - `EnumCollA.HttpVersion` (cases `Http10`, `Http11`) and
//!     `EnumCollB.ConnState` (cases `Http11`, `Closed`) collide on CASE name
//!     only (`Http11` in both, DIFFERENT ordinals — 1 vs 0 — so a misrouted
//!     ordinal produces an observably WRONG label rather than a
//!     coincidentally-correct one).
//!   - `EnumCollC.HttpVersion` (cases `Http11`, `Closed`) collides with
//!     `EnumCollA.HttpVersion` on the bare TYPE name itself (`HttpVersion` in
//!     both, different declaring packages, and — again — a different
//!     `Http11` ordinal: 0 in C's `HttpVersion` vs 1 in A's) — the
//!     second-layer defect this test was added (#6607) to actually exercise:
//!     the type-scoped `<EnumType>.<Case>` codegen key
//!     (`resolveEnumCaseOrdinalByScope`) is itself keyed by the enum's bare
//!     simple TYPE name, so two different packages' same-named types
//!     collided on THAT key even after the case-name-only collision (#5995)
//!     was fixed. `EnumCollA` vs `EnumCollB` alone never exercises this path
//!     — `HttpVersion` and `ConnState` are distinct type names, so the
//!     type-scoped key never collides between them.
//!
//! A fourth package (`EnumCollApp`) imports all three and exercises the
//! independently-triggerable halves of the bug against each enum:
//!
//!   1. Cross-package-QUALIFIED case CONSTRUCTION as a call argument
//!      (`EnumCollA.Http11`/`EnumCollB.Http11`) — `EnumCollA.labelOf`'s own
//!      declared parameter type must select `HttpVersion`'s `Http11`, and
//!      `EnumCollB.labelOf`'s own declared parameter type must select
//!      `ConnState`'s `Http11`, never the other's. A genuinely BARE
//!      `Http11` here (both packages imported unqualified) is now a
//!      compile-time T0123 ambiguity error (#6287) rather than a silent
//!      mis-dispatch — the class of bug this test guards is unreachable for
//!      that shape; qualification is what a caller is now required to (and
//!      correctly can) do, and the remaining live risk this test targets is
//!      whether a QUALIFIED reference resolves to the RIGHT package's
//!      ordinal at the CODEGEN level (it did not, pre-fix: the type-scoped
//!      `<EnumType>.<Case>` key `registerEnumDeclMsil` maintains is itself
//!      keyed by the enum's bare simple TYPE name, so two same-named types
//!      — or, in the wild, a user enum sharing a name with a stdlib one
//!      such as `Std.Http.HttpVersion`, always linked into every build
//!      regardless of import — collided on THAT key too).
//!   2. PATTERN MATCH against a locally-annotated variable, built via each
//!      package's OWN (collision-free) internal constructor. A's and B's
//!      declared types are unambiguous at the type-checker level (distinct
//!      simple type names, no cross-import name lookup involved), so a bare
//!      arm pattern (`case Http11 -> ...`) is legal and exercises the codegen
//!      scrutinee-hint path (#5995) directly, isolated from the construction
//!      fix above.
//!
//! `EnumCollC.HttpVersion`, sharing its bare type name with
//! `EnumCollA.HttpVersion`, is exercised the same way for construction (1)
//! from `EnumCollApp`, so a revert of the package-scoping fix this test
//! guards — either the `resolveEnumCaseOrdinalByScope`/
//! `enumTypeCaseDeclarers` mechanism, or its `EPath` qualifier-preference
//! companion fix in `lowerExprMsil` (#6607: a package-qualified reference
//! reaches codegen as a flattened multi-segment `EPath`, not `EMember` —
//! `Lyric.AliasRewriter` collapses every `Pkg.member` chain, aliased or
//! bare, so the qualifier segment was being discarded in favour of the
//! ambiguous construction-context `enumHint`) — fails this test instead of
//! shipping silently.
//!
//! C's PATTERN-MATCH half (2) is exercised from a SEPARATE, fifth package
//! (`EnumCollAppC`) that imports ONLY `EnumCollC` — not from `EnumCollApp`
//! alongside A and B.  A bare arm's scrutinee hint is only the simple type
//! name (`HttpVersion`), and `resolveEnumCaseOrdinalByScope` disambiguates a
//! same-named-type collision by asking "which of this bare hint's several
//! declaring packages does the CURRENT FUNCTION'S OWN package import" — a
//! per-FUNCTION, not per-variable, resolution.  From `EnumCollApp` (which
//! imports both A's and C's same-named `HttpVersion`) that question is
//! ambiguous for a locally-bound `HttpVersion` var regardless of which one
//! it actually holds — a separate, narrower, pre-existing gap in the
//! scrutinee-hint mechanism (not the type-scoped-key defect this test
//! targets) that this test does not attempt to close.  From `EnumCollAppC`
//! (importing only C) the same bare arm is unambiguous — `HttpVersion` has
//! exactly one reachable declarer — so it still exercises the identical
//! #6607 type-name-collision-vs-case-name-collision class the construction
//! half establishes, just from a consumer whose own import list already
//! disambiguates it.
//!
//! Before the fix, every one of these references (construction OR pattern)
//! resolved through a single bundle-wide first-registered-wins table keyed
//! by the bare case name (or, for a qualified reference, the enum's bare
//! simple TYPE name) alone — MSIL's `enumCaseOrdinals` (an Int ordinal;
//! Lyric enums lower to a bare Int with no distinguishing CLR type) and
//! JVM's `enumcase:` `funcSigs` entries — so whichever enum registered
//! `Http11` first silently won every reference in the whole bundle, with no
//! compile error.
//!
//! Compiles two separate projects per target — `[A, B, C, App]` and
//! `[C, AppC]` — via the in-process self-hosted project bridges
//! (`Msil.Bridge.compileProjectToMsil` for `--target dotnet`,
//! `Jvm.Bridge.compileProjectToJarBundledWithFeatures` for `--target jvm`),
//! runs each produced binary, and asserts on stdout — mirroring
//! `msil_project_bridge_self_test.l` / `jvm_cross_package_collision_self_test.l`,
//! the precedent for genuine cross-package collision regression tests that
//! can't be reproduced within a single `@test_module` package (a source file
//! is one package's worth of declarations, so the colliding enums cannot
//! live in the test file itself).
//!
//! A fourth fixture package (`EnumCollD`, JVM-only) covers a distinct
//! collision shape #6607's fix left unguarded (#6640): two DIFFERENT enums
//! declared in the SAME package sharing a case name (`Status.Ok` /
//! `Health.Ok`, unlike A/B's cross-package case-name collision or C's
//! cross-package type-name collision). On the JVM, `enumCaseClassForExpecting`
//! (bare case CONSTRUCTION) and `enumPatternClass` (bare PATTERN-MATCH arm
//! resolution) both consulted `enumVariantClassByPkg`, whose
//! `"enum:" + dottedPkg + "." + case` key is scoped by (package, case) only —
//! omitting the enum's own TYPE name — so `Status.Ok` and `Health.Ok`
//! collided on it: whichever enum registered first silently won every bare
//! reference in the package, including inside the OTHER enum's own
//! construction/match sites. `Status.Ok` is ordinal 0 and `Health.Ok` is
//! ordinal 1 (`Bad` is 0), so a misrouted reference prints the WRONG label
//! or fails an identity-based pattern test at runtime rather than
//! coincidentally matching. `EnumCollD` is self-contained (the collision is
//! intra-package, unlike A/B/C) and JVM-only per the issue: MSIL enums erase
//! to a bare Int ordinal and resolve bare references through the differently-
//! shaped `varEnumTypes`/`enumHint` mechanism (#5995/#6595), not touched here.
//!
//! A fifth fixture package (`EnumCollReal`, MSIL-only) covers issue #6650's
//! review finding: every collision case above uses SYNTHETIC fixture
//! packages on both sides.  The bug report's own confirmed live repro (see
//! `docs/03-decision-log.md`'s #5995 entry) was a user package's own
//! `HttpVersion` enum colliding with `Std.Http.HttpVersion` -- a REAL
//! stdlib enum that is compiled into `Lyric.Stdlib.dll` and linked into
//! every build that reaches it, not a hand-written fixture string.
//! `EnumCollReal.HttpVersion` (cases `Http10`, `Http11`) collides with
//! `Std.Http.HttpVersion` (cases `Http11`, `Http2`, `Http3`) on BOTH the
//! bare case name (`Http11`, ordinal 1 here vs. 0 in `Std.Http`) and the
//! bare type name (`HttpVersion`), exercising the same two-layer defect
//! class as `EnumCollC` above, but against the actual compiled stdlib
//! bundle via `Emitter.findStdlibSources()` / `Emitter.copyStdlibDllsBeside`
//! (mirroring `msil_project_bridge_self_test.l`'s `compileAndRunWithStdlib`)
//! instead of an empty `stdlibSources` list.  Only CONSTRUCTION (1) is
//! exercised from the ambiguous scope (a package importing both `Std.Http`
//! and `EnumCollReal`); the match/label step for each side is delegated to
//! a single-declarer package, the same "isolate the match" split `EnumCollC`
//! needs `EnumCollAppC` for (see `stdLabelSource`'s doc comment) -- a bare
//! match against a locally-typed var when a package imports BOTH same-named
//! declarers together is the separate, pre-existing scrutinee-hint gap this
//! test class does not attempt to close, not the #5995/#6607 defect this
//! case targets.  MSIL-only: `Std.Http` is
//! non-functional on the JVM backend today (docs/59 phantom `_kernel_jvm`
//! gap), so a JVM run of this case would test nothing real.
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
import Jvm.Codegen
import Lyric.Parser
import Lyric.RestoredPackages
import Lyric.ContractMeta as Meta
import Lyric.Emitter as Emitter

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

// #6607: a SECOND enum also named `HttpVersion`, declared in a different
// package (`EnumCollC`), with a DIFFERENT `Http11` ordinal (0 here; 1 in
// `EnumCollA.HttpVersion`) so a type-name collision on the codegen-level
// type-scoped key produces an observably WRONG label rather than a
// coincidentally-correct one.
func pkgCSource(): String {
  "package EnumCollC\n" + "\n" + "pub enum HttpVersion {\n" + "  case Http11\n" + "  case Closed\n" + "}\n" + "\n" +
    "pub func labelOf(v: in HttpVersion): String {\n" +
    "  match v {\n" +
    "    case Http11 -> \"C:Http11\"\n" +
    "    case Closed -> \"C:Closed\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub func make11(): HttpVersion {\n" +
    "  Http11\n" +
    "}\n"
}

func appSource(): String {
  "package EnumCollApp\n" + "\n" + "import EnumCollA as A\n" + "import EnumCollB as B\n" + "import EnumCollC as C\n" +
    "\n" +
    "func main(): Int {\n" +
    "  // (1) Cross-package-QUALIFIED case CONSTRUCTION as a call argument:\n" +
    "  // each callee's own declared parameter type must select its OWN\n" +
    "  // enum's Http11 case. Both packages are imported unqualified here, so\n" +
    "  // (per #6287's T0123) a genuinely bare `Http11` is a compile-time\n" +
    "  // ambiguity error requiring qualification -- exactly the outcome that\n" +
    "  // makes the silent-mis-dispatch class this test guards against\n" +
    "  // unreachable for two SIMULTANEOUSLY-imported same-case-name enums.\n" +
    "  // The remaining, still-live risk this test targets is the codegen-level\n" +
    "  // one: does the QUALIFIED reference resolve to the RIGHT enum's ordinal?\n" +
    "  // #6607: EnumCollC.HttpVersion shares its bare TYPE name with\n" +
    "  // EnumCollA.HttpVersion (a different declaring package, different\n" +
    "  // ordinal for Http11) -- this is the type-name-collision half of the\n" +
    "  // codegen-level risk, distinct from A vs B's case-name-only collision.\n" +
    "  println(A.labelOf(EnumCollA.Http11))\n" +
    "  println(B.labelOf(EnumCollB.Http11))\n" +
    "  println(C.labelOf(EnumCollC.Http11))\n" +
    "\n" +
    "  // (2) PATTERN MATCH against a locally-annotated variable, built via\n" +
    "  // each package's own (collision-free) constructor. A and B's declared\n" +
    "  // types are unambiguous (distinct type names), so a bare arm pattern\n" +
    "  // is legal here and exercises the codegen scrutinee-hint path (#5995)\n" +
    "  // directly. C's own bare-match exercise lives in the separate\n" +
    "  // EnumCollAppC package below (see the module doc comment for why).\n" +
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
  "A:Http11\n" + "B:Http11\n" + "C:Http11\n" + "match-A:Http11\n" + "match-B:Http11"
}

// A fifth package, consuming ONLY `EnumCollC` (see module doc comment for
// why this is separate from `EnumCollApp`): exercises C's bare-arm PATTERN
// MATCH (the case-2 exercise A and B get inside `appSource` above) from a
// consumer whose own import list unambiguously resolves `HttpVersion` to
// `EnumCollC` alone.
func appCSource(): String {
  "package EnumCollAppC\n" + "\n" + "import EnumCollC as C\n" + "\n" + "func main(): Int {\n" +
    "  val c3: C.HttpVersion = C.make11()\n" +
    "  match c3 {\n" +
    "    case Http11 -> println(\"match-C:Http11\")\n" +
    "    case Closed -> println(\"match-C:Closed\")\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func expectedAppCStdout(): String {
  "match-C:Http11"
}

// #6640: two DIFFERENT enums declared in the SAME package sharing a case
// name (`Ok` in both `Status` and `Health`) — the intra-package collision
// shape distinct from A/B's cross-package case-name collision and C's
// cross-package type-name collision.  `Status.Ok` is ordinal 0; `Health.Ok`
// is ordinal 1 (`Bad` is 0) — deliberately different so a misrouted
// reference prints the WRONG label instead of coincidentally matching.
// `statusLabel(Ok)`/`healthLabel(Ok)` exercise bare-case CONSTRUCTION as a
// call argument (`enumCaseClassForExpecting`'s expected-type-scoped tier
// must select the callee's OWN parameter type, not whichever of the two
// same-package enums registered `Ok` first); the two annotated locals plus
// their bare-arm `match` exercise PATTERN MATCH (`enumPatternClass`'s
// scrutinee-type-scoped tier).
func pkgDSource(): String {
  "package EnumCollD\n" + "\n" + "pub enum Status {\n" + "  case Ok\n" + "  case Fail\n" + "}\n" + "\n" +
    "pub enum Health {\n" +
    "  case Bad\n" +
    "  case Ok\n" +
    "}\n" +
    "\n" +
    "pub func statusLabel(v: in Status): String {\n" +
    "  match v {\n" +
    "    case Ok -> \"D:Status:Ok\"\n" +
    "    case Fail -> \"D:Status:Fail\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub func healthLabel(h: in Health): String {\n" +
    "  match h {\n" +
    "    case Bad -> \"D:Health:Bad\"\n" +
    "    case Ok -> \"D:Health:Ok\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Int {\n" +
    "  println(statusLabel(Ok))\n" +
    "  println(healthLabel(Ok))\n" +
    "  val s: Status = Ok\n" +
    "  val h: Health = Ok\n" +
    "  match s {\n" +
    "    case Ok -> println(\"match-D:Status:Ok\")\n" +
    "    case Fail -> println(\"match-D:Status:Fail\")\n" +
    "  }\n" +
    "  match h {\n" +
    "    case Bad -> println(\"match-D:Health:Bad\")\n" +
    "    case Ok -> println(\"match-D:Health:Ok\")\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func expectedDStdout(): String {
  "D:Status:Ok\n" + "D:Health:Ok\n" + "match-D:Status:Ok\n" + "match-D:Health:Ok"
}

// #6650: a user package's own enum colliding with a REAL stdlib enum
// (`Std.Http.HttpVersion`), the exact shape the #5995 bug report's live
// repro described. `HttpVersion.Http11` is ordinal 1 here (Http10 is 0);
// `Std.Http.HttpVersion.Http11` is ordinal 0 (Http2 is 1, Http3 is 2) --
// deliberately different so a misrouted ordinal prints the WRONG label
// instead of coincidentally matching.
func pkgRealSource(): String {
  "package EnumCollReal\n" + "\n" + "pub enum HttpVersion {\n" + "  case Http10\n" + "  case Http11\n" + "}\n" + "\n" +
    "pub func labelOf(v: in HttpVersion): String {\n" +
    "  match v {\n" +
    "    case Http10 -> \"Real:Http10\"\n" +
    "    case Http11 -> \"Real:Http11\"\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "pub func make11(): HttpVersion {\n" +
    "  Http11\n" +
    "}\n"
}

// `label`'s bare-arm match resolves against `Std.Http`'s own `HttpVersion`
// unambiguously because THIS package imports only `Std.Http` -- the same
// "isolate the match, not the construction" split `EnumCollAppC` uses below
// for `EnumCollC`, applied here because the OTHER declarer of the colliding
// bare `HttpVersion` name (`EnumCollReal`) is a project package, not a
// synthetic sibling that can simply be left out of the bundle: a package
// whose own import list names only ONE of the two colliding declarers keeps
// the bare-arm scrutinee hint unambiguous regardless of what else the wider
// bundle links in.
func stdLabelSource(): String {
  "package EnumCollRealStdLabel\n" + "\n" + "import Std.Http\n" + "\n" + "pub func label(v: in HttpVersion): String {\n" +
    "  match v {\n" +
    "    case Http11 -> \"Std:Http11\"\n" +
    "    case Http2 -> \"Std:Http2\"\n" +
    "    case Http3 -> \"Std:Http3\"\n" +
    "  }\n" +
    "}\n"
}

// Imports `Std.Http` (always reachable in a real build, per the #5995 bug
// report), `EnumCollReal`, and `EnumCollRealStdLabel` together -- the actual
// collision scope, since `Std.Http.HttpVersion` and `EnumCollReal.HttpVersion`
// share both their bare CASE name (`Http11`) and their bare TYPE name
// (`HttpVersion`) and are both live in this one build. Deliberately CALLS
// INTO single-declarer packages for the match/label step (see
// `stdLabelSource`'s doc comment and `EnumCollAppC` below) rather than
// pattern-matching here directly: only cross-package-QUALIFIED case
// CONSTRUCTION as a call argument is exercised in this ambiguous scope --
// exactly the #5995/#6607 defect class (does a qualified reference resolve
// to the RIGHT declaring package's ordinal, not whichever registered
// first?), without also depending on the separate, pre-existing
// scrutinee-hint gap `EnumCollC`'s doc comment describes (a bare match
// against a locally-typed var is ambiguous when a package imports BOTH
// same-named declarers together -- not the defect this test targets).
func realAppSource(): String {
  "package EnumCollRealApp\n" + "\n" + "import Std.Http\n" + "import EnumCollReal\n" + "import EnumCollRealStdLabel\n" +
    "\n" +
    "func main(): Int {\n" +
    "  println(EnumCollRealStdLabel.label(Std.Http.Http11))\n" +
    "  println(EnumCollReal.labelOf(EnumCollReal.Http11))\n" +
    "  0\n" +
    "}\n"
}

func expectedRealStdout(): String {
  "Std:Http11\n" + "Real:Http11"
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

// Like `compileAndRunMsil` but populates the REAL stdlib sources
// (`Emitter.findStdlibSources()`) so user packages may reference stdlib
// types by name -- #6650's requirement that the collision be exercised
// against `Std.Http.HttpVersion` as compiled, not a synthetic stand-in.
// Mirrors `msil_project_bridge_self_test.l`'s `compileAndRunWithStdlib`:
// copies the compiled stdlib DLLs beside the output so `dotnet exec`
// resolves the cross-assembly references `registerStdlibArtifactTokens`
// emits.
func compileAndRunMsilWithStdlib(
  label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources = Emitter.findStdlibSources()
  val ok = compileProjectToMsil(packages, assemblyName, dllPath, stdlibSources)
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToMsil (with stdlib) returned false")
  }
  val libDir = Emitter.findCompiledStdlibDir()
  Emitter.copyStdlibDllsBeside(dllPath, libDir)
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
  val noPaths: List[String] = newList()
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

// ─── Tests ───────────────────────────────────────────────────────────────────
test "dotnet: bare enum-case construction and pattern match resolve against each enum's own package" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("EnumCollA", pkgASource()))
  packages.add(mkPkg("EnumCollB", pkgBSource()))
  packages.add(mkPkg("EnumCollC", pkgCSource()))
  packages.add(mkPkg("EnumCollApp", appSource()))
  val result = compileAndRunMsil("enumcoll-dotnet", packages, "EnumCollApp")
  assertEqualInt(result.exitCode, 0, "enum_case_collision dotnet: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedStdout(),
    "enum_case_collision dotnet: bare Http11 construction/match dispatch to the RIGHT enum in every package"
  )

  val packagesC: List[ProjectPackagePayload] = newList()
  packagesC.add(mkPkg("EnumCollC", pkgCSource()))
  packagesC.add(mkPkg("EnumCollAppC", appCSource()))
  val resultC = compileAndRunMsil("enumcoll-dotnet-appc", packagesC, "EnumCollAppC")
  assertEqualInt(
    resultC.exitCode,
    0,
    "enum_case_collision dotnet (AppC): exit 0 expected (stderr=" + resultC.stderr + ")"
  )
  assertEqual(
    Str.trim(resultC.stdout),
    expectedAppCStdout(),
    "enum_case_collision dotnet (AppC): bare pattern match against C's own type-name-colliding HttpVersion"
  )
}

test "jvm: bare enum-case construction and pattern match resolve against each enum's own package" {
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(pkgASource())
  pkgSrcs.add(pkgBSource())
  pkgSrcs.add(pkgCSource())
  pkgSrcs.add(appSource())
  val result = compileAndRunJvm("enumcoll-jvm", pkgSrcs, "EnumCollApp")
  assertEqualInt(result.exitCode, 0, "enum_case_collision jvm: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedStdout(),
    "enum_case_collision jvm: bare Http11 construction/match dispatch to the RIGHT enum in every package"
  )

  val pkgSrcsC: List[String] = newList()
  pkgSrcsC.add(pkgCSource())
  pkgSrcsC.add(appCSource())
  val resultC = compileAndRunJvm("enumcoll-jvm-appc", pkgSrcsC, "EnumCollAppC")
  assertEqualInt(resultC.exitCode, 0, "enum_case_collision jvm (AppC): exit 0 expected (stderr=" + resultC.stderr + ")")
  assertEqual(
    Str.trim(resultC.stdout),
    expectedAppCStdout(),
    "enum_case_collision jvm (AppC): bare pattern match against C's own type-name-colliding HttpVersion"
  )
}

// ─── #6638: registerEnumDeclMsil unguarded Map.add duplicate-key crash ─────
// `Msil.Codegen.registerRestoredArtifactTokens`/`registerRestoredMembers`
// iterate `cctx.restoredArtifacts` with no dedup by package name — a diamond
// `[dependencies] path` graph the resolver doesn't collapse (two of a
// project's own packages each independently resolving the SAME shared
// library) feeds the identical `SynthesisedArtifact` into that list twice.
// Reproduced directly here by pushing one artifact into the restored list
// twice, which is exactly the shape `compileProjectToMsilWithRestored`
// receives regardless of how the duplicate upstream path arose. Before the
// fix, `registerEnumDeclMsil`'s `cctx.enumCaseOrdinalsByPkgType.add(...)`
// call was unguarded: the SECOND registration threw a raw
// `System.ArgumentException` ("An item with the same key has already been
// added") straight out of the compiler — an unhandled crash, not a graceful
// build failure — even though the re-visit computes the identical ordinal
// and should be a pure no-op.
func dupEnumLibSource(): String {
  "package DupEnumLib\n" + "\n" + "pub enum Shade {\n" + "  case Light\n" + "  case Dark\n" + "}\n" + "\n" +
    "pub func labelOf(s: in Shade): String {\n" +
    "  match s {\n" +
    "    case Light -> \"Light\"\n" +
    "    case Dark -> \"Dark\"\n" +
    "  }\n" +
    "}\n"
}

func dupEnumAppSource(): String {
  "package DupEnumApp\n" + "\n" + "import DupEnumLib\n" + "\n" + "func main(): Int {\n" +
    "  println(DupEnumLib.labelOf(DupEnumLib.Dark))\n" +
    "  0\n" +
    "}\n"
}

// Compile `source` to a standalone producer DLL and reload it through the
// exact `Lyric.RestoredPackages` round-trip the CLI's `[dependencies] path`
// restore uses (mirrors `msil_restored_bridge_self_test.l`'s
// `buildRestoredArtifact`). The caller owns cleaning up `art.dllPath`'s
// directory.
func buildDupRestoredArtifact(label: in String, source: in String, dllName: in String): SynthesisedArtifact {
  val libDir = freshTempDir(label + "-lib")
  val libDllPath = Path.join(libDir, dllName + ".dll")
  val noStdlib: List[String] = newList()
  val ok = compileToMsil(source, libDllPath, noStdlib)
  if not ok {
    cleanup(libDir)
    panic(label + ": compileToMsil (producer) returned false")
  }
  match loadRestoredPackage(libDllPath) {
    case Err(e) -> {
      cleanup(libDir)
      panic(label + ": loadRestoredPackage failed: " + errorMessage(e))
    }
    case Ok(artifacts) -> {
      if artifacts.count != 1 {
        cleanup(libDir)
        panic(label + ": expected exactly 1 restored artifact, got " + artifacts.count.toString())
      }
      val noPreamble: List[Meta.ContractDecl] = newList()
      match synthesiseArtifact(artifacts[0], noPreamble) {
        case Err(e) -> {
          cleanup(libDir)
          panic(label + ": synthesiseArtifact failed: " + errorMessage(e))
        }
        case Ok(art) -> art
      }
    }
  }
}

test "dotnet: a restored artifact registered twice does not crash enum registration (#6638)" {
  val art = buildDupRestoredArtifact("dupenum", dupEnumLibSource(), "DupEnumLib")
  val appDir = freshTempDir("dupenum-app")
  val appDllPath = Path.join(appDir, "DupEnumApp.dll")
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("DupEnumApp", dupEnumAppSource()))
  val noStdlib: List[String] = newList()
  val noFeatures: List[String] = newList()
  val artifacts: List[SynthesisedArtifact] = newList()
  artifacts.add(art)
  artifacts.add(art) // the same artifact registered twice -- the crash trigger
  val ok = compileProjectToMsilWithRestored(
    packages,
    "DupEnumApp",
    appDllPath,
    noStdlib,
    noFeatures,
    noFeatures,
    artifacts
  )
  val libDir = Path.dirname(art.dllPath)
  if not ok {
    cleanup(appDir)
    cleanup(libDir)
    panic("dupenum: compileProjectToMsilWithRestored (consumer) returned false")
  }
  copyFileDup(art.dllPath, Path.join(appDir, Path.basename(art.dllPath)))
  writeRuntimeConfig(appDllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(appDllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(appDir)
  cleanup(libDir)
  assertEqualInt(result.exitCode, 0, "dupenum: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "Dark", "dupenum: duplicate-registered enum still resolves the right ordinal")
}

func copyFileDup(src: in String, dest: in String): Unit {
  match File.readBytes(src) {
    case Ok(bs) -> {
      val _ = File.writeBytes(dest, bs)
    }
    case Err(_) -> ()
  }
}

// ─── #6639: sibling same-package enums colliding on a package-qualified case ─
// `Beam` and `Ray`, both declared in package `SiblingEnums`, both declare a
// case named `On` with DIFFERENT ordinals (`Beam.On` is 1, `Ray.On` is 0) so
// a misrouted ordinal produces an observably WRONG label instead of a
// coincidentally-correct one. Each is constructed via its own internal
// factory function (collision-free), then pattern-matched via the
// package-qualified `case SiblingEnums.On ->` form — the CONVENTIONAL way
// Lyric references an enum case (see `registerEnumDeclMsil`'s `qn` comment)
// — for BOTH cases of BOTH enums, so a misrouted ordinal routes to the WRONG
// arm within an otherwise-exhaustive match rather than falling off the end.
// Before the fix, the package-qualified pattern branch resolved through a
// single package-scoped bare key (`pkgName + "." + caseName`, no type name),
// so whichever enum registered `On` FIRST silently won every
// package-qualified pattern test against EITHER enum.
func siblingEnumsSource(): String {
  "package SiblingEnums\n" + "\n" + "pub enum Beam {\n" + "  case Off\n" + "  case On\n" + "}\n" + "\n" +
    "pub enum Ray {\n" +
    "  case On\n" +
    "  case Idle\n" +
    "}\n" +
    "\n" +
    "pub func makeBeamOn(): Beam {\n" +
    "  On\n" +
    "}\n" +
    "\n" +
    "pub func makeRayOn(): Ray {\n" +
    "  On\n" +
    "}\n"
}

func siblingEnumsAppSource(): String {
  "package SiblingEnumsApp\n" + "\n" + "import SiblingEnums\n" + "\n" + "func main(): Int {\n" +
    "  val beam: SiblingEnums.Beam = SiblingEnums.makeBeamOn()\n" +
    "  val ray: SiblingEnums.Ray = SiblingEnums.makeRayOn()\n" +
    "  match beam {\n" +
    "    case SiblingEnums.On -> println(\"beam-on\")\n" +
    "    case SiblingEnums.Off -> println(\"beam-off\")\n" +
    "  }\n" +
    "  match ray {\n" +
    "    case SiblingEnums.On -> println(\"ray-on\")\n" +
    "    case SiblingEnums.Idle -> println(\"ray-idle\")\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func expectedSiblingEnumsStdout(): String {
  "beam-on\nray-on"
}

test "dotnet: package-qualified pattern match resolves the right ordinal for sibling same-package enums (#6639)" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("SiblingEnums", siblingEnumsSource()))
  packages.add(mkPkg("SiblingEnumsApp", siblingEnumsAppSource()))
  val result = compileAndRunMsil("siblingenums-dotnet", packages, "SiblingEnumsApp")
  assertEqualInt(result.exitCode, 0, "sibling_enums dotnet: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedSiblingEnumsStdout(),
    "sibling_enums dotnet: package-qualified `On` resolves to each enum's OWN ordinal, not whichever registered first"
  )
}

// ─── #6639 (residual): package-qualified case CONSTRUCTION (EPath value
// position), not just pattern match ────────────────────────────────────────
// The earlier #6639 fix only touched `lowerPatternTestMsil` (the `case
// Pkg.Case ->` pattern-test arm). `lowerExprMsil`'s `EPath` arm — reached by
// a package-qualified case reference used as a VALUE (`val x: T =
// SiblingEnums.On`), not as a pattern — has the identical bug: its
// `qualifiedOrdHit` lookup (`enumCaseOrdinals["<pkg>.<case>"]`, no enum TYPE
// name) was given priority over the type-scoped `hintedOrd` a `val`
// annotation pushes, so it silently resolved `SiblingEnums.On` to whichever
// of `Beam`/`Ray` registered `On` first regardless of the annotated target
// type. Reuses the `SiblingEnums` fixture (`Beam.On` = 1, `Ray.On` = 0) so a
// misrouted construction produces an observably WRONG match arm.
func siblingEnumsValueAppSource(): String {
  "package SiblingEnumsValueApp\n" + "\n" + "import SiblingEnums\n" + "\n" + "func main(): Int {\n" +
    "  val beam: SiblingEnums.Beam = SiblingEnums.On\n" +
    "  val ray: SiblingEnums.Ray = SiblingEnums.On\n" +
    "  match beam {\n" +
    "    case SiblingEnums.On -> println(\"vbeam-on\")\n" +
    "    case SiblingEnums.Off -> println(\"vbeam-off\")\n" +
    "  }\n" +
    "  match ray {\n" +
    "    case SiblingEnums.On -> println(\"vray-on\")\n" +
    "    case SiblingEnums.Idle -> println(\"vray-idle\")\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

func expectedSiblingEnumsValueStdout(): String {
  "vbeam-on\nvray-on"
}

test "dotnet: package-qualified case CONSTRUCTION (value position) resolves the right ordinal for sibling same-package enums (#6639 residual)" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("SiblingEnums", siblingEnumsSource()))
  packages.add(mkPkg("SiblingEnumsValueApp", siblingEnumsValueAppSource()))
  val result = compileAndRunMsil("siblingenums-value-dotnet", packages, "SiblingEnumsValueApp")
  assertEqualInt(result.exitCode, 0, "sibling_enums_value dotnet: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    expectedSiblingEnumsValueStdout(),
    "sibling_enums_value dotnet: package-qualified `On` CONSTRUCTION (EPath value position) resolves to the " +
      "annotated target's OWN ordinal, not whichever enum registered `On` first"
  )
}

// ─── #6688: call-argument enum hint resolves against the CALLEE's declaring
// package, not the CALLER's ─────────────────────────────────────────────────
// The #5995 call-argument enum-hint mechanism threaded only the callee's
// parameter type's BARE enum name, discarding which package declared it, so
// the consumer resolved that bare name preferring the CALLER's own package
// over the CALLEE's. `CrossHintB.Level` (`Info`, `Debug` — `Debug` is
// ordinal 1) is the callee's parameter type; `CrossHintA` declares its OWN,
// differently-ordered `Level` (`Debug`, `Info` — `Debug` is ordinal 0) and
// calls `B.log(Debug)` with a BARE case argument. Before the fix, the hint
// carried only "Level", and `resolveEnumCaseOrdinalByScope` preferred
// `CrossHintA` (the caller, in scope) over `CrossHintB` (the callee, the
// actually-correct answer) purely because the caller happens to also declare
// a same-named enum type — silently passing ordinal 0 (A's `Debug`) where
// B's `log` expects ordinal 1, so `log` reads it back as its OWN ordinal-0
// case (`Info`) and returns the wrong label.
func crossHintBSource(): String {
  "package CrossHintB\n" + "\n" + "pub enum Level {\n" + "  case Info\n" + "  case Debug\n" + "}\n" + "\n" +
    "pub func log(v: in Level): String {\n" +
    "  match v {\n" +
    "    case Info -> \"B:Info\"\n" +
    "    case Debug -> \"B:Debug\"\n" +
    "  }\n" +
    "}\n"
}

func crossHintASource(): String {
  "package CrossHintA\n" + "\n" + "import CrossHintB as B\n" + "\n" + "pub enum Level {\n" + "  case Debug\n" +
    "  case Info\n" +
    "}\n" +
    "\n" +
    "func main(): Int {\n" +
    "  println(B.log(Debug))\n" +
    "  0\n" +
    "}\n"
}

test "dotnet: call-argument enum hint resolves the bare case against the CALLEE's declaring package (#6688)" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("CrossHintB", crossHintBSource()))
  packages.add(mkPkg("CrossHintA", crossHintASource()))
  val result = compileAndRunMsil("crosshint-dotnet", packages, "CrossHintA")
  assertEqualInt(result.exitCode, 0, "cross_hint dotnet: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "B:Debug",
    "cross_hint dotnet: a bare call-argument `Debug` resolves against CALLEE CrossHintB's Level " +
      "(ordinal 1), not CALLER CrossHintA's own same-named, differently-ordered Level (ordinal 0)"
  )
}

// #6640: JVM-only — see `pkgDSource`'s doc comment. Single-package (the
// collision is intra-package), so no separate consumer package is needed.
test "jvm: same-package two-enum case-name collision resolves bare construction and pattern match (#6640)" {
  val pkgSrcsD: List[String] = newList()
  pkgSrcsD.add(pkgDSource())
  val resultD = compileAndRunJvm("enumcoll-jvm-d", pkgSrcsD, "EnumCollD")
  assertEqualInt(resultD.exitCode, 0, "enum_case_collision jvm (D): exit 0 expected (stderr=" + resultD.stderr + ")")
  assertEqual(
    Str.trim(resultD.stdout),
    expectedDStdout(),
    "enum_case_collision jvm (D): bare Ok construction/match resolves against the RIGHT same-package enum"
  )
}

// #6650: the real-stdlib-collision case the review finding asked for --
// a user package's own `HttpVersion` enum linked against the actual
// compiled `Std.Http.HttpVersion`, not a synthetic fixture on both sides.
// MSIL-only: see `pkgRealSource`'s doc comment above for why.
test "dotnet: a user enum colliding with a real stdlib enum (Std.Http.HttpVersion) resolves the right one (#6650)" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("EnumCollReal", pkgRealSource()))
  packages.add(mkPkg("EnumCollRealStdLabel", stdLabelSource()))
  packages.add(mkPkg("EnumCollRealApp", realAppSource()))
  val result = compileAndRunMsilWithStdlib("enumcoll-real-dotnet", packages, "EnumCollRealApp")
  assertEqualInt(
    result.exitCode,
    0,
    "enum_case_collision (real stdlib) dotnet: exit 0 expected (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    expectedRealStdout(),
    "enum_case_collision (real stdlib) dotnet: Std.Http.HttpVersion.Http11 and EnumCollReal.HttpVersion.Http11 " +
      "each resolve qualified construction to their OWN enum's ordinal, not whichever registered first"
  )
}

// ─── #6683: JVM enum key tiers (type/package/package+type) shared one flat
// "enum:" namespace and could alias across UNRELATED packages ──────────────
// `06_items.l`'s three registration tiers — `enumty:<Enum>.<Case>` (type
// only), `enumfull:<pkg>.<Enum>.<Case>` (package + type), `enumpkg:<pkg>.
// <Case>` (package only) — used to share one bare `"enum:" + ...` prefix.
// A package literally named `EnumTierX.Y` declaring `enum Status { case
// Bad; case Ok }` and a SEPARATE, unrelated package `EnumTierX` declaring
// `enum Y { case Other; case Ok }` are the exact shape the issue cites
// (`EnumTierX.Y`'s (package, case) key for its own `Status.Ok` — old key
// `"enum:EnumTierX.Y.Ok"` — collides with `EnumTierX`'s (package, TYPE,
// case) key for its own `Y.Ok` — old key `"enum:EnumTierX.Y.Ok"` too).
// That EXACT shape cannot be exercised as a runnable end-to-end JVM
// program, though: a package literally named `<P>.<T>` and a SEPARATE
// package `<P>` declaring a type literally named `<T>` is precisely the
// combination the JVM classloader itself can never load simultaneously —
// `<P>/<T>` would have to be BOTH a class (`<P>`'s `<T>` enum) and a
// package directory (housing `<P>.<T>`'s own classes), a conflict with no
// resolution regardless of this fix (confirmed empirically: even valid,
// non-colliding constructions in either package throw `NoSuchFieldError`
// once both packages are bundled into one JAR together, independent of
// which package registers first). So this test instead verifies the fix at
// the level the issue's own fix instruction targets — the registration
// MAP itself — by calling `Jvm.Codegen.collectFileSigs` directly (the same
// entry point `Jvm.Bridge` drives per-file during a real compile) and
// inspecting the resulting `Map[String, JvmFuncSig]`, instead of running a
// compiled JAR. `EnumTierX.Y` is registered FIRST here so its (package,
// case) key claims the shared old-format string ahead of `EnumTierX`'s
// (package, TYPE, case) registration for the SAME string; `EnumTierX`'s
// tier — unlike the (package, case) tier, which self-poisons on a
// same-TIER conflict (#6640) — has NO cross-tier guard at all, so it used
// to be silently dropped with no diagnostic (the exact defect the issue
// cites). Post-fix, both entries must exist under their own distinct
// prefixes, each resolving to its OWN correct declaring class, and neither
// registration should trip the same-tier ambiguity poison (`enumpkgambig:`)
// meant for a DIFFERENT collision class (#6640) entirely.
func enumTierXYSource(): String {
  "package EnumTierX.Y\n" + "\n" + "pub enum Status {\n" + "  case Bad\n" + "  case Ok\n" + "}\n"
}

func enumTierXSource(): String {
  "package EnumTierX\n" + "\n" + "pub enum Y {\n" + "  case Other\n" + "  case Ok\n" + "}\n"
}

test "jvm: distinct key-tier prefixes prevent a package name from aliasing another package's enum-type key (#6683)" {
  val into: Map[String, JvmFuncSig] = newMap()
  val fileXY = Parser.parse(enumTierXYSource()).file
  val fileX = Parser.parse(enumTierXSource()).file
  // `EnumTierX.Y` FIRST so its (package, case) registration claims the
  // shared old-format string ahead of `EnumTierX`'s (package, TYPE, case)
  // registration for the SAME string — see the comment above.
  collectFileSigs(fileXY, into)
  collectFileSigs(fileX, into)

  match mapGet(into, "enumfull:EnumTierX.Y.Ok") {
    case Some(sig) -> assertEqual(
      sig.owner,
      "EnumTierX/Y",
      "enum_case_collision jvm (tier): EnumTierX's own (package, TYPE, case) registration for Y.Ok must resolve " +
        "to EnumTierX's own class, not EnumTierX.Y's unrelated Status"
    )
    case None -> panic(
      "enum_case_collision jvm (tier): EnumTierX's (package, TYPE, case) key for Y.Ok is MISSING entirely -- " +
        "silently dropped by EnumTierX.Y's (package, case) registration for the identical old-format string"
    )
  }
  match mapGet(into, "enumpkg:EnumTierX.Y.Ok") {
    case Some(sig) -> assertEqual(
      sig.owner,
      "EnumTierX/Y/Status",
      "enum_case_collision jvm (tier): EnumTierX.Y's own (package, case) registration for Status.Ok must resolve " +
        "to EnumTierX.Y's own class"
    )
    case None -> panic("enum_case_collision jvm (tier): EnumTierX.Y's (package, case) key for Status.Ok is MISSING")
  }
  assertFalse(
    into.containsKey("enumpkgambig:EnumTierX.Y.Ok"),
    "enum_case_collision jvm (tier): the (package, case)-tier same-TIER ambiguity poison (#6640) must not fire " +
      "for a CROSS-tier collision -- EnumTierX and EnumTierX.Y never register the SAME tier twice"
  )
}
