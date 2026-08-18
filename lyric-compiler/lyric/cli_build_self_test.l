//! cli_build_self_test.l — exercises pure helpers and the stdlib-colocation
//! behavior in `Lyric.Cli` (cli/cli_build.l):
//!   - `validatePackageVersionArg` (#4426, #4727) — no I/O.
//!   - `filterExtraRefs` / `releaseFromDllIgnoredArgsWarning` (#4282) —
//!     pure logic pulled out of `cmdBuild`'s `--release-from-dll` branch so
//!     it's testable without invoking the native AOT release path.
//!   - `buildOneNative` (#4127) — end-to-end: compiles a temp source file
//!     and asserts `Lyric.Stdlib.dll` is colocated beside the output DLL
//!     for a runnable program (declares `func main()`) and is NOT for a
//!     library (no `main`).
//!   - `hasContribution`'s `nativeAssetPaths` branch and
//!     `copyNugetNativeAssetsBeside` wiring (#5744) — a manifest whose only
//!     contribution is a NuGet-resolved native runtime asset.
//!   - `buildProject`'s `preResolvedDeps` seam (#5786, regression test
//!     #5819) — a sentinel resolution proves the passed-in value is
//!     actually read rather than silently re-resolved internally.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_build_self_test.l
@test_module
package Lyric.CliBuildSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Uuid
import Std.Testing
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

test "validatePackageVersionArg: empty string is rejected" {
  match Cli.validatePackageVersionArg("") {
    case None -> assertTrue(false, "empty string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "empty-string message mentions non-empty")
  }
}

test "validatePackageVersionArg: whitespace-only string is rejected" {
  match Cli.validatePackageVersionArg("   ") {
    case None -> assertTrue(false, "whitespace-only string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "whitespace-only message mentions non-empty")
  }
}

test "validatePackageVersionArg: lowercase v-prefix is rejected" {
  match Cli.validatePackageVersionArg("v1.0.0") {
    case None -> assertTrue(false, "'v1.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "1.0.0"), "v-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: uppercase V-prefix is rejected" {
  match Cli.validatePackageVersionArg("V2.0.0") {
    case None -> assertTrue(false, "'V2.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "2.0.0"), "V-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: plain semver is accepted" {
  match Cli.validatePackageVersionArg("1.0.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'1.0.0' should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: bare 'v' (length 1, no digit to check) is accepted" {
  match Cli.validatePackageVersionArg("v") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'v' alone should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: 'v' followed by a non-digit is accepted" {
  // Guards against false positives on words that merely start with 'v' —
  // only a v/V immediately followed by an ASCII digit is a git-tag prefix.
  match Cli.validatePackageVersionArg("vendor1.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'vendor1.0' should be accepted, got: " + msg)
  }
}

// ─── releaseFromDllIgnoredArgsWarning (#4282) ───────────────────────────
test "releaseFromDllIgnoredArgsWarning: single positional arg" {
  val positional: List[String] = newList()
  positional.add("foo.l")
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(
    Str.contains(msg, "--release-from-dll") and Str.contains(msg, "foo.l"),
    "warning mentions the flag and the ignored filename, got: " + msg
  )
}

test "releaseFromDllIgnoredArgsWarning: multiple positional args are comma-joined" {
  val positional: List[String] = newList()
  positional.add("foo.l")
  positional.add("bar.l")
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(Str.contains(msg, "foo.l, bar.l"), "multiple filenames are comma-joined, got: " + msg)
}

test "releaseFromDllIgnoredArgsWarning: empty list yields a warning with no filenames" {
  val positional: List[String] = newList()
  val msg = Cli.releaseFromDllIgnoredArgsWarning(positional)
  assertTrue(
    Str.contains(msg, "--release-from-dll"),
    "warning still names the flag with no positional args, got: " + msg
  )
}

// ─── defineBuildGateError accept/reject matrix (#5852 / #6139 / #6140) ────
// docs/63 band B0 re-keyed both gates from the `--release` flag to the shape
// axis: it is the packaging path that threads no defines, not the optimization
// profile.
test "defineBuildGateError: no defines is always allowed" {
  match Cli.defineBuildGateError(false, false, true, Cli.SAot, Emitter.Dotnet, "lyric.toml") {
    case None -> assertTrue(true, "no defines -> allowed regardless of other flags")
    case Some(msg) -> assertTrue(false, "no defines should be allowed, got: " + msg)
  }
}

test "defineBuildGateError: consumable portable project build is allowed" {
  match Cli.defineBuildGateError(true, true, false, Cli.SPortable, Emitter.Dotnet, "lyric.toml") {
    case None -> assertTrue(true, "consumable target, no watch, portable shape -> allowed")
    case Some(msg) -> assertTrue(false, "plain consumable project build should be allowed, got: " + msg)
  }
}

test "defineBuildGateError: --watch is rejected" {
  match Cli.defineBuildGateError(true, true, true, Cli.SPortable, Emitter.Dotnet, "") {
    case None -> assertTrue(false, "--watch should reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "--watch"), "watch rejection names the flag, got: " + msg)
  }
}

test "defineBuildGateError: --shape aot is rejected and names the shape" {
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "") {
    case None -> assertTrue(false, "--shape aot should reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "--shape aot"), "aot rejection names the shape, got: " + msg)
  }
}

test "defineBuildGateError: --shape standalone is rejected" {
  match Cli.defineBuildGateError(true, true, false, Cli.SStandalone, Emitter.Dotnet, "") {
    case None -> assertTrue(false, "--shape standalone should reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "--shape standalone"), "standalone rejection names the shape, got: " + msg)
  }
}

test "defineBuildGateError: manifest-configured aot shape names the manifest path" {
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "/proj/lyric.toml") {
    case None -> assertTrue(false, "manifest shape = aot should reject --define (#6139)")
    case Some(msg) -> assertTrue(Str.contains(msg, "--shape aot") and Str.contains(msg, "/proj/lyric.toml"), "aot rejection names the shape and the manifest path, got: " + msg)
  }
}

// The headline docs/63 §5.3 regression: `--release` alone no longer rejects
// `--define`. Before band B0 this combination was refused for a reason that
// applied to the AOT path, not to the release profile.
test "defineBuildGateError: release profile with a portable shape allows defines (docs/63 §5.3)" {
  match Cli.defineBuildGateError(true, true, false, Cli.SPortable, Emitter.Dotnet, "lyric.toml") {
    case None -> assertTrue(true, "--release --shape portable --define is allowed after the re-scope")
    case Some(msg) -> assertTrue(false, "release+portable must not reject --define, got: " + msg)
  }
}

// ─── manifestDefineGateError accept/reject matrix (#6188) ─────────────────
test "manifestDefineGateError: no manifest defines is always allowed" {
  match Cli.manifestDefineGateError(false, Cli.SAot, Emitter.Dotnet, "/p/lyric.toml") {
    case None -> assertTrue(true, "no manifest defines -> allowed regardless of shape")
    case Some(msg) -> assertTrue(false, "no manifest defines should be allowed, got: " + msg)
  }
}

test "manifestDefineGateError: portable project build is allowed" {
  // native consumes manifest defines (#5977), like dotnet/jvm.
  match Cli.manifestDefineGateError(true, Cli.SPortable, Emitter.Dotnet, "/p/lyric.toml") {
    case None -> assertTrue(true, "portable project build (incl. native) -> allowed")
    case Some(msg) -> assertTrue(false, "plain project build should be allowed, got: " + msg)
  }
}

test "manifestDefineGateError: aot shape is rejected" {
  match Cli.manifestDefineGateError(true, Cli.SAot, Emitter.Dotnet, "/p/lyric.toml") {
    case None -> assertTrue(false, "aot shape should reject manifest [build.define]")
    case Some(msg) -> assertTrue(Str.contains(msg, "aot"), "aot rejection names the shape, got: " + msg)
  }
}

test "manifestDefineGateError: standalone shape is rejected" {
  match Cli.manifestDefineGateError(true, Cli.SStandalone, Emitter.Dotnet, "/p/lyric.toml") {
    case None -> assertTrue(false, "standalone shape should reject manifest [build.define]")
    case Some(msg) -> assertTrue(Str.contains(msg, "standalone"), "standalone rejection names the shape, got: " + msg)
  }
}

// ─── profile / shape flag matrix (docs/63 §4, F0040/F0041/F0043/F0044) ────
test "profileFlagConflictError: --debug and --release together is F0040" {
  match Cli.profileFlagConflictError(true, true) {
    case None -> assertTrue(false, "--debug --release should conflict")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0040"), "conflict names F0040, got: " + msg)
  }
}

test "profileFlagConflictError: either flag alone, or neither, is accepted" {
  match Cli.profileFlagConflictError(true, false) {
    case None -> assertTrue(true, "--debug alone is fine")
    case Some(msg) -> assertTrue(false, "--debug alone should be accepted, got: " + msg)
  }
  match Cli.profileFlagConflictError(false, true) {
    case None -> assertTrue(true, "--release alone is fine")
    case Some(msg) -> assertTrue(false, "--release alone should be accepted, got: " + msg)
  }
  match Cli.profileFlagConflictError(false, false) {
    case None -> assertTrue(true, "neither flag is fine (defaults to debug)")
    case Some(msg) -> assertTrue(false, "no profile flag should be accepted, got: " + msg)
  }
}

test "shapeFlagConflictError: --aot with --standalone is F0041" {
  match Cli.shapeFlagConflictError("", true, true) {
    case None -> assertTrue(false, "--aot --standalone should conflict")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0041"), "conflict names F0041, got: " + msg)
  }
}

test "shapeFlagConflictError: sugar disagreeing with --shape is F0041" {
  match Cli.shapeFlagConflictError("portable", true, false) {
    case None -> assertTrue(false, "--aot --shape portable should conflict")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0041") and Str.contains(msg, "portable"), "conflict names F0041 and the shape, got: " + msg)
  }
  match Cli.shapeFlagConflictError("aot", false, true) {
    case None -> assertTrue(false, "--standalone --shape aot should conflict")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0041"), "conflict names F0041, got: " + msg)
  }
}

test "shapeFlagConflictError: sugar agreeing with --shape is accepted" {
  match Cli.shapeFlagConflictError("aot", true, false) {
    case None -> assertTrue(true, "--aot --shape aot agree, so no conflict")
    case Some(msg) -> assertTrue(false, "agreeing spellings should be accepted, got: " + msg)
  }
  match Cli.shapeFlagConflictError("", false, false) {
    case None -> assertTrue(true, "no shape flags at all is fine")
    case Some(msg) -> assertTrue(false, "no shape flags should be accepted, got: " + msg)
  }
}

test "shapeTargetError: --target native rejects portable and standalone (F0043)" {
  match Cli.shapeTargetError(Cli.SPortable, Emitter.Native) {
    case None -> assertTrue(false, "native + portable should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0043"), "native/portable names F0043, got: " + msg)
  }
  match Cli.shapeTargetError(Cli.SStandalone, Emitter.Native) {
    case None -> assertTrue(false, "native + standalone should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0043"), "native/standalone names F0043, got: " + msg)
  }
}

test "shapeTargetError: native accepts aot; managed targets accept every shape" {
  match Cli.shapeTargetError(Cli.SAot, Emitter.Native) {
    case None -> assertTrue(true, "native + aot is the only valid native pairing")
    case Some(msg) -> assertTrue(false, "native + aot should be accepted, got: " + msg)
  }
  match Cli.shapeTargetError(Cli.SPortable, Emitter.Dotnet) {
    case None -> assertTrue(true, "dotnet + portable is fine")
    case Some(msg) -> assertTrue(false, "dotnet + portable should be accepted, got: " + msg)
  }
  match Cli.shapeTargetError(Cli.SAot, Emitter.Jvm) {
    case None -> assertTrue(true, "jvm + aot is accepted here; Lyric.Release fails loud on GraalVM (#1975)")
    case Some(msg) -> assertTrue(false, "jvm + aot should pass the target check, got: " + msg)
  }
}

test "shapeUnsupportedError: standalone is F0044 until it is implemented (#6262)" {
  match Cli.shapeUnsupportedError(Cli.SStandalone, Emitter.Dotnet) {
    case None -> assertTrue(false, "standalone is not implemented and must fail loud")
    case Some(msg) -> assertTrue(Str.contains(msg, "F0044") and Str.contains(msg, "6262"), "standalone names F0044 and the tracking issue, got: " + msg)
  }
  match Cli.shapeUnsupportedError(Cli.SPortable, Emitter.Dotnet) {
    case None -> assertTrue(true, "portable is implemented")
    case Some(msg) -> assertTrue(false, "portable should be supported, got: " + msg)
  }
  match Cli.shapeUnsupportedError(Cli.SAot, Emitter.Dotnet) {
    case None -> assertTrue(true, "aot on dotnet is implemented")
    case Some(msg) -> assertTrue(false, "dotnet aot should be supported, got: " + msg)
  }
}

// ─── the --target native carve-out (#6266 regression) ────────────────────
// `--target native` resolves to shape = aot, but that is native's ONLY and
// NORMAL path (LLVM IR -> clang), not a packaging hop layered on a managed
// build. Keying the gates on the raw shape rejected `--target native --define`
// and `--target native --watch` — both previously-shipped behaviour (#5977) —
// and the rejection even suggested `--shape portable`, which F0043 refuses for
// native, leaving no way to satisfy it.
test "usesPackagingPipeline: native aot is NOT a packaging pipeline (#6266)" {
  assertFalse(
    Cli.usesPackagingPipeline(Cli.SAot, Emitter.Native),
    "native's aot shape is its normal compile path, not a packaging hop"
  )
}

test "usesPackagingPipeline: managed aot and standalone ARE packaging pipelines" {
  assertTrue(Cli.usesPackagingPipeline(Cli.SAot, Emitter.Dotnet), "dotnet aot goes through Lyric.Release")
  assertTrue(Cli.usesPackagingPipeline(Cli.SAot, Emitter.Jvm), "jvm aot goes through Lyric.Release")
  assertTrue(Cli.usesPackagingPipeline(Cli.SStandalone, Emitter.Dotnet), "standalone would be a packaging publish")
}

test "usesPackagingPipeline: portable is never a packaging pipeline" {
  assertFalse(Cli.usesPackagingPipeline(Cli.SPortable, Emitter.Dotnet), "dotnet portable")
  assertFalse(Cli.usesPackagingPipeline(Cli.SPortable, Emitter.Jvm), "jvm portable")
}

test "defineBuildGateError: --target native keeps --define working (#5977, #6266)" {
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Native, "") {
    case None -> assertTrue(true, "native --define is a shipped feature and must not be gated")
    case Some(msg) -> assertTrue(false, "native --define must be allowed, got: " + msg)
  }
}

test "manifestDefineGateError: --target native keeps manifest defines working (#6266)" {
  match Cli.manifestDefineGateError(true, Cli.SAot, Emitter.Native, "/p/lyric.toml") {
    case None -> assertTrue(true, "native manifest defines must not be gated by the aot shape")
    case Some(msg) -> assertTrue(false, "native manifest defines must be allowed, got: " + msg)
  }
}

test "defineBuildGateError: a CLI-sourced shape never gets manifest advice (#6277)" {
  // Project mode always has a manifest path in hand, but when the shape came
  // from `--aot` the advice must not tell the user to edit a manifest key they
  // never set. The call site passes "" for a CLI-named shape.
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "") {
    case None -> assertTrue(false, "aot shape should still reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "--aot/--standalone") and (not Str.contains(msg, "in that manifest")), "CLI-sourced rejection names flags, not a manifest key, got: " + msg)
  }
}

test "defineBuildGateError: single-file --manifest shape is manifest-sourced too (#6278)" {
  // Band B0 taught single-file builds to read `[build] shape` from an explicit
  // `--manifest`, so that path can be manifest-sourced just like project mode;
  // the call site must pass the manifest path, not "".
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "/p/custom.toml") {
    case None -> assertTrue(false, "aot shape should still reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "/p/custom.toml") and (not Str.contains(msg, "--aot/--standalone")), "single-file manifest-sourced shape points at the manifest, got: " + msg)
  }
}

test "defineBuildGateError: manifest-sourced shape gets manifest-shaped advice" {
  // Telling a user to "build without --aot" is useless when the shape came from
  // their manifest and no such flag was ever passed.
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "/p/lyric.toml") {
    case None -> assertTrue(false, "manifest aot shape should still reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "/p/lyric.toml") and Str.contains(msg, "in that manifest") and (not Str.contains(msg, "--aot/--standalone")), "manifest-sourced rejection points at the manifest, not at flags, got: " + msg)
  }
}

test "defineBuildGateError: the rejection never suggests a shape the target refuses (#6266)" {
  // The old message said "build with --shape portable" — impossible on native
  // (F0043) and, on managed targets, phrased as a shape the user may not want.
  // It now names the flags to drop instead.
  match Cli.defineBuildGateError(true, true, false, Cli.SAot, Emitter.Dotnet, "") {
    case None -> assertTrue(false, "dotnet aot should still reject --define")
    case Some(msg) -> assertTrue(Str.contains(msg, "--aot") and (not Str.contains(msg, "--shape portable")), "message tells the user which flag to drop, got: " + msg)
  }
}

// ─── profile is independent of shape on the AOT path (#6267) ─────────────
// `buildReleaseSingle`/`buildReleaseProject` used to hardcode
// "build_profile=release", so `--debug --aot` — the debuggable-AOT combination
// band B0 exists to unlock — reported profile=release. They now thread the
// resolved profile through `profileOnlyDefines`, which is `withProfileDefine`
// over an empty list, so these tests pin the behaviour at its source.
test "withProfileDefine: release prepends build_profile=release" {
  val empty: List[String] = newList()
  val defs = Cli.withProfileDefine(empty, Cli.ProfRelease)
  assertEqualInt(defs.count, 1, "release profile contributes exactly one define")
  assertEqual(defs[0], "build_profile=release", "release profile define")
}

test "withProfileDefine: debug contributes nothing (#6267)" {
  val empty: List[String] = newList()
  val defs = Cli.withProfileDefine(empty, Cli.ProfDebug)
  assertEqualInt(
    defs.count,
    0,
    "debug must NOT inject build_profile=release — pipeParseAndErase supplies the debug fallback"
  )
}

test "withProfileDefine: a user define still wins under last-wins (#6267)" {
  val user: List[String] = newList()
  user.add("build_profile=CUSTOM")
  val defs = Cli.withProfileDefine(user, Cli.ProfRelease)
  assertEqualInt(defs.count, 2, "profile define plus the user's")
  assertEqual(defs[0], "build_profile=release", "profile define goes first")
  assertEqual(defs[1], "build_profile=CUSTOM", "user define goes last so last-wins keeps it")
}

// ─── axis composition: resolveBuildAxes / defaultShapeForTarget ──────────
// Both #6266 and #6267 were composition bugs: every individual predicate was
// tested, but the function that combines CLI-over-manifest precedence with the
// native shape default was only covered end-to-end by hand. These pin the
// composition itself.
test "defaultShapeForTarget: bare --target native defaults to aot" {
  val noShape: Option[Cli.BuildShape] = None
  match Cli.defaultShapeForTarget(noShape, Emitter.Native) {
    case Some(s) -> assertEqual(Cli.shapeName(s), "aot", "native with no --shape defaults to aot")
    case None -> assertTrue(false, "native must get a default shape")
  }
}

test "defaultShapeForTarget: managed targets get no default (manifest may still speak)" {
  val noShape: Option[Cli.BuildShape] = None
  match Cli.defaultShapeForTarget(noShape, Emitter.Dotnet) {
    case None -> assertTrue(true, "dotnet defers to the manifest, then to portable")
    case Some(s) -> assertTrue(false, "dotnet must not be forced to " + Cli.shapeName(s))
  }
}

test "defaultShapeForTarget: an explicit CLI shape is never overridden" {
  // Load-bearing for F0043: `--target native --shape portable` must survive to
  // resolveBuildAxes so the error fires, rather than being silently upgraded.
  val portable: Option[Cli.BuildShape] = Some(value = Cli.SPortable)
  match Cli.defaultShapeForTarget(portable, Emitter.Native) {
    case Some(s) -> assertEqual(Cli.shapeName(s), "portable", "explicit shape survives the native default")
    case None -> assertTrue(false, "explicit shape must survive")
  }
}

test "resolveBuildAxes: no CLI axes and no manifest -> portable/debug" {
  val noShape: Option[Cli.BuildShape] = None
  val noProfile: Option[Cli.BuildProfile] = None
  val noMf: Option[String] = None
  match Cli.resolveBuildAxes(noShape, noProfile, noMf, Emitter.Dotnet) {
    case Ok(a) -> {
      assertEqual(Cli.shapeName(a.shape), "portable", "default shape")
      assertEqual(Cli.profileName(a.profile), "debug", "default profile")
    }
    case Err(m) -> assertTrue(false, "defaults must resolve, got: " + m)
  }
}

test "resolveBuildAxes: CLI axes win, and the two are independent" {
  val aot: Option[Cli.BuildShape] = Some(value = Cli.SAot)
  val dbg: Option[Cli.BuildProfile] = Some(value = Cli.ProfDebug)
  val noMf: Option[String] = None
  match Cli.resolveBuildAxes(aot, dbg, noMf, Emitter.Dotnet) {
    case Ok(a) -> {
      assertEqual(Cli.shapeName(a.shape), "aot", "CLI shape wins")
      assertEqual(Cli.profileName(a.profile), "debug", "debug survives an aot shape (#6267)")
    }
    case Err(m) -> assertTrue(false, "--debug --aot is a valid pairing, got: " + m)
  }
}

test "resolveBuildAxes: native + explicit portable is F0043, not a silent upgrade" {
  val portable: Option[Cli.BuildShape] = Some(value = Cli.SPortable)
  val noProfile: Option[Cli.BuildProfile] = None
  val noMf: Option[String] = None
  match Cli.resolveBuildAxes(portable, noProfile, noMf, Emitter.Native) {
    case Ok(a) -> assertTrue(false, "native + portable must fail, resolved to " + Cli.shapeName(a.shape))
    case Err(m) -> assertTrue(Str.contains(m, "F0043"), "native + portable names F0043, got: " + m)
  }
}

test "resolveBuildAxes: standalone is rejected by F0044 wherever it comes from" {
  val standalone: Option[Cli.BuildShape] = Some(value = Cli.SStandalone)
  val noProfile: Option[Cli.BuildProfile] = None
  val noMf: Option[String] = None
  match Cli.resolveBuildAxes(standalone, noProfile, noMf, Emitter.Dotnet) {
    case Ok(_) -> assertTrue(false, "standalone is unimplemented and must fail")
    case Err(m) -> assertTrue(Str.contains(m, "F0044"), "standalone names F0044, got: " + m)
  }
}

// ─── shape naming under the sugar flags (#6281) ──────────────────────────
// `--aot`/`--standalone` never populate the raw `--shape` string, so any
// message built from that string prints a blank name. `shapeName` on the
// RESOLVED shape is what messages must use.
test "shapeName: every shape has a printable name (#6281)" {
  assertEqual(Cli.shapeName(Cli.SPortable), "portable", "portable")
  assertEqual(Cli.shapeName(Cli.SStandalone), "standalone", "standalone")
  assertEqual(Cli.shapeName(Cli.SAot), "aot", "aot")
}

test "parseShapeName round-trips every shape through shapeName (#6281)" {
  // Guarantees a message built from `shapeName(parseShapeName(x))` can never
  // come out blank for a value the CLI accepted.
  for nm in ["portable", "standalone", "aot"] {
    match Cli.parseShapeName(nm) {
      case Some(sh) -> assertEqual(Cli.shapeName(sh), nm, "round-trip " + nm)
      case None -> assertTrue(false, "parseShapeName rejected a valid shape: " + nm)
    }
  }
}

// ─── --rid warning wording per target ────────────────────────────────────
test "ridNoEffectWarning: native points at --triple, not an unsatisfiable shape" {
  val msg = Cli.ridNoEffectWarning(Emitter.Native)
  assertTrue(
    Str.contains(msg, "--triple") and (not Str.contains(msg, "--shape aot")),
    "native --rid advice must not suggest a shape it already has, got: " + msg
  )
}

test "ridNoEffectWarning: managed targets name the packaging shapes" {
  val msg = Cli.ridNoEffectWarning(Emitter.Dotnet)
  assertTrue(Str.contains(msg, "--shape aot"), "dotnet --rid advice names the shapes, got: " + msg)
}

// ─── the --release migration note (docs/63 §6 mitigation 2) ──────────────
test "shouldPrintReleaseNote: bare --release resolving to a non-aot shape prints the note" {
  assertTrue(
    Cli.shouldPrintReleaseNote(true, false, Cli.SPortable),
    "bare --release now yields a portable artifact where it used to yield an AOT binary"
  )
}

test "shouldPrintReleaseNote: silent when the shape was named, or resolves to aot, or no --release" {
  assertFalse(
    Cli.shouldPrintReleaseNote(true, true, Cli.SPortable),
    "an explicit --shape means the user already knows the axes are separate"
  )
  assertFalse(
    Cli.shouldPrintReleaseNote(true, false, Cli.SAot),
    "manifest shape = aot preserves the old artifact, so there is nothing to warn about"
  )
  assertFalse(Cli.shouldPrintReleaseNote(false, false, Cli.SPortable), "no --release -> no note")
}

// ─── filterExtraRefs (#4282) ─────────────────────────────────────────
test "filterExtraRefs: excludes the primary DLL and Lyric.Stdlib.dll, keeps only .dll files, sorted" {
  val files: List[String] = newList()
  files.add("/refs/Zeta.dll")
  files.add("/refs/App.dll")
  files.add("/refs/Lyric.Stdlib.dll")
  files.add("/refs/notes.txt")
  files.add("/refs/Alpha.dll")
  val result = Cli.filterExtraRefs(files, "App.dll", ".dll")
  assertEqualInt(result.count, 2, "filterExtraRefs: excludes primary DLL, Lyric.Stdlib.dll, and non-DLL files")
  assertEqual(result[0], "/refs/Alpha.dll", "filterExtraRefs: sorted ascending, entry 0")
  assertEqual(result[1], "/refs/Zeta.dll", "filterExtraRefs: sorted ascending, entry 1")
}

test "filterExtraRefs: empty input yields an empty list" {
  val files: List[String] = newList()
  val result = Cli.filterExtraRefs(files, "App.dll", ".dll")
  assertEqualInt(result.count, 0, "filterExtraRefs: empty input")
}

test "filterExtraRefs: no matches when every file is excluded" {
  val files: List[String] = newList()
  files.add("/refs/App.dll")
  files.add("/refs/Lyric.Stdlib.dll")
  files.add("/refs/readme.md")
  val result = Cli.filterExtraRefs(files, "App.dll", ".dll")
  assertEqualInt(result.count, 0, "filterExtraRefs: primary DLL, stdlib, and non-DLL all excluded")
}

// ─── buildOneNative colocation (#4127) ──────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-clibuild-" + label + "-" + uuidToString(newUuid()))
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

func writeFileOrPanic(path: in String, content: in String): Unit {
  match File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

test "buildOneNative: a runnable program (declares main) colocates Lyric.Stdlib.dll beside the output" {
  val dir = freshTempDir("exe")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "hello.l")
  writeFileOrPanic(srcPath, "package ExeColocationFixture\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outPath = Path.join(dir, "hello.dll")

  val exitCode = Cli.buildOneNative(srcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "buildOneNative: exe fixture compiles cleanly")
  assertTrue(File.fileExists(outPath), "buildOneNative: output DLL is produced")
  assertTrue(
    File.fileExists(Path.join(dir, "Lyric.Stdlib.dll")),
    "buildOneNative: Lyric.Stdlib.dll is colocated beside a runnable program's output"
  )
}

test "buildOneNative: a library (no main) does NOT colocate Lyric.Stdlib.dll beside the output" {
  val dir = freshTempDir("lib")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "lib.l")
  writeFileOrPanic(srcPath, "package LibColocationFixture\n\npub func helper(): Int {\n  1\n}\n")
  val outPath = Path.join(dir, "lib.dll")

  val exitCode = Cli.buildOneNative(srcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "buildOneNative: library fixture compiles cleanly")
  assertTrue(File.fileExists(outPath), "buildOneNative: output DLL is produced")
  assertTrue(
    not File.fileExists(Path.join(dir, "Lyric.Stdlib.dll")),
    "buildOneNative: a library build must not colocate Lyric.Stdlib.dll (would clobber a stdlib self-build)"
  )
}

// ─── single-file + nearby-manifest dependency resolution (D123) ────────
// Exercises `buildOneNative` auto-discovering a lyric.toml near a loose .l
// file — one that is compiled directly (`lyric build thatfile.l`), NOT via
// that manifest's `[project.packages]` — and resolving a `path = "..."`
// dependency declared there.  The dependency's DLL is produced with a
// direct `buildOneNative` call (mirroring how a real `lyric build
// --manifest dep/lyric.toml` populates `dep/bin/<Name>.dll`) rather than
// pulling in the full project-manifest machinery, keeping the fixture
// self-contained.
func writeManifestOrPanic(path: in String, content: in String): Unit {
  writeFileOrPanic(path, content)
}

func bytesEqual(a: in List[Byte], b: in List[Byte]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i += 1
  }
  true
}

test "buildOneNative: single-file build near a manifest resolves an already-built path dependency" {
  val depDir = freshTempDir("dep")
  defer {
    cleanup(depDir)
  }
  // `resolveManifestDependencies` requires the dependency directory to have
  // its own lyric.toml (to read its output-assembly name) even though this
  // fixture builds the DLL directly via `buildOneNative` rather than
  // `buildProject` — matching what a real `lyric build --manifest
  // dep/lyric.toml` would leave behind.
  writeManifestOrPanic(
    Path.join(depDir, "lyric.toml"),
    "[package]\n" + "name = \"DepSf\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"DepSfProj\"\n" +
      "output_assembly = \"DepSf.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"DepSf\" = \"dep.l\"\n"
  )
  val depSrcPath = Path.join(depDir, "dep.l")
  writeFileOrPanic(depSrcPath, "package DepSf\n\npub func greet(name: String): String {\n  \"hi \" + name\n}\n")
  val depDllPath = Path.join(Path.join(depDir, "bin"), "DepSf.dll")
  val depExit = Cli.buildOneNative(depSrcPath, depDllPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(depExit, 0, "fixture dependency compiles cleanly")
  assertTrue(File.fileExists(depDllPath), "fixture dependency DLL exists at the expected bin/ path")

  val appDir = freshTempDir("app")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSf\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" + "DepSf = { path = \"" +
      depDir +
      "\" }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(
    looseSrcPath,
    "package AppSf.Loose\n\nimport DepSf\n\npub func run(): String {\n  greet(\"world\")\n}\n"
  )
  val outPath = Path.join(appDir, "loose.dll")

  // manifestPath = None: this is the auto-discovery path, not an explicit
  // --manifest — `loose.l` is never listed in any `[project.packages]`.
  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "single-file build resolves the nearby manifest's path dependency")
  assertTrue(File.fileExists(outPath), "output DLL is produced")
}

// ─── single-file + nearby-manifest own-package inclusion (#5571) ────────
// A loose .l file near a lyric.toml that imports one of THAT manifest's own
// [project.packages] (the `lyric build tests/x.l` inside-a-library-tree
// shape, e.g. lyric-web's tests/jvm_server_smoke.l importing Web) compiles
// the imported package into the synthetic project request.  Before this,
// the request carried only dependencies, so the import either failed to
// resolve or fell through to an unrelated same-named function.
test "buildOneNative: single-file build near a manifest compiles the [project.packages] it imports" {
  val dir = freshTempDir("ownpkg")
  defer {
    cleanup(dir)
  }
  writeManifestOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\n" + "name = \"OwnPkg\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"OwnPkg\"\n" +
      "output_assembly = \"OwnPkg.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"OwnPkgLib\" = \"src/lib.l\"\n"
  )
  match File.createDir(Path.join(dir, "src")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  match File.createDir(Path.join(dir, "tests")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create tests dir: " + IOError.message(e))
  }
  writeFileOrPanic(
    Path.join(Path.join(dir, "src"), "lib.l"),
    "package OwnPkgLib\n\npub func answer(): Int {\n  42\n}\n"
  )
  val loosePath = Path.join(Path.join(dir, "tests"), "consumer.l")
  writeFileOrPanic(loosePath, "package OwnPkg.Consumer\n\nimport OwnPkgLib\n\nfunc main(): Int {\n  answer() - 42\n}\n")
  val outPath = Path.join(Path.join(dir, "tests"), "consumer.dll")

  val exitCode = Cli.buildOneNative(loosePath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "single-file build compiles the manifest's own imported package into the bundle")
  assertTrue(File.fileExists(outPath), "output DLL is produced")
}

// A manifest whose [project.packages] declares Std.*/Lyric.* entries (the
// stdlib and compiler trees themselves) must NOT have those swept in as
// own packages: they resolve through the restored bundles, and compiling
// them into the user assembly double-books their types — a file built
// near lyric-stdlib/lyric.toml lost `Std.Core.Option_Some` match
// resolution this way (wave-5 integration regression).
test "buildOneNative: single-file build near a manifest never sweeps in Std.*/Lyric.* packages" {
  val dir = freshTempDir("stdhead")
  defer {
    cleanup(dir)
  }
  writeManifestOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\n" + "name = \"StdHead\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"StdHead\"\n" +
      "output_assembly = \"StdHead.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"Std.Core\" = \"fake/core.l\"\n"
  )
  // The manifest points Std.Core at a bogus path: if the sweep ever
  // includes reserved-head packages again, the build fails on the missing
  // source instead of using the restored stdlib bundle.
  match File.createDir(Path.join(dir, "tests")) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create tests dir: " + IOError.message(e))
  }
  val loosePath = Path.join(Path.join(dir, "tests"), "consumer.l")
  writeFileOrPanic(
    loosePath,
    "package StdHead.Consumer\n\nimport Std.Core\n\nfunc main(): Int {\n  val o: Option[Int] = Some(7)\n  match o {\n    case Some(v) -> v - 7\n    case None -> 1\n  }\n}\n"
  )
  val outPath = Path.join(Path.join(dir, "tests"), "consumer.dll")

  val exitCode = Cli.buildOneNative(loosePath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "Std.Core resolves via the restored stdlib bundle, not the manifest sweep")
  assertTrue(File.fileExists(outPath), "output DLL is produced")
}

test "buildOneNative: single-file build near a manifest fails loudly on an unbuilt path dependency" {
  val depDir = freshTempDir("dep-unbuilt")
  defer {
    cleanup(depDir)
  }
  // The dependency is a well-formed, buildable package (it has its own
  // lyric.toml) — it has just never been built, so no bin/DepSfb.dll
  // exists yet.  This exercises `Release.localDepNotBuiltMessage`'s branch
  // specifically, distinct from the "no lyric.toml at all" branch.
  writeManifestOrPanic(
    Path.join(depDir, "lyric.toml"),
    "[package]\n" + "name = \"DepSfb\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" + "name = \"DepSfbProj\"\n" +
      "output_assembly = \"DepSfb.dll\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"DepSfb\" = \"dep.l\"\n"
  )
  val depSrcPath = Path.join(depDir, "dep.l")
  writeFileOrPanic(depSrcPath, "package DepSfb\n\npub func greet(name: String): String {\n  \"hi \" + name\n}\n")

  val appDir = freshTempDir("app-unbuilt")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfb\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" + "DepSfb = { path = \"" +
      depDir +
      "\" }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(
    looseSrcPath,
    "package AppSfb.Loose\n\nimport DepSfb\n\npub func run(): String {\n  greet(\"world\")\n}\n"
  )
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertTrue(exitCode != 0, "single-file build fails loudly instead of silently ignoring the unbuilt dependency")
}

// Regression for a review finding on this PR: `emitSingleFileOrProject`
// originally checked `resolvedDeps.hadUnbuiltLocalDep` but never
// `resolvedDeps.hadWorkspaceError`, so a manifest declaring a broken
// `{ workspace = true }` dependency (unlike a `path` dependency, this
// resolves purely from the workspace member index — no DLL-existence
// check) fell through to a silent, dependency-less compile instead of
// failing loud like `buildProject` already does for the same condition.
// `MissingMember` is deliberately never a workspace member, so
// `Ws.resolveDep` returns `None` and `buildWorkspaceDeps` reports
// `hadError = true` purely from manifest resolution — no real package
// build is attempted, keeping this deterministic and fast.
test "buildOneNative: single-file build near a manifest fails loudly on a broken workspace dependency" {
  val wsRoot = freshTempDir("ws-broken")
  defer {
    cleanup(wsRoot)
  }
  writeManifestOrPanic(Path.join(wsRoot, "lyric.toml"), "[workspace]\n")

  val appDir = Path.join(wsRoot, "app")
  match File.createDir(appDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create app dir " + appDir + ": " + IOError.message(e))
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfWs\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "MissingMember = { workspace = true }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppSfWs.Loose\n\npub func run(): Int {\n  1\n}\n")
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertTrue(
    exitCode != 0,
    "single-file build fails loudly on a broken workspace dependency instead of silently compiling without it"
  )
}

// Regression for a second review finding on this PR: the "malformed
// lyric.toml" and "cannot read lyric.toml" branches for a `path = "..."`
// dependency printed an error but never set `hadUnbuiltLocalDep`, unlike
// their sibling "no lyric.toml found" / "DLL not built" branches a few
// lines away — the same silent-swallow shape as the workspace-error bug
// above, just in different branches of the same function.
test "buildOneNative: single-file build near a manifest fails loudly on a malformed dependency manifest" {
  val depDir = freshTempDir("dep-malformed")
  defer {
    cleanup(depDir)
  }
  // Deliberately broken TOML: an inline table missing its closing brace.
  writeManifestOrPanic(Path.join(depDir, "lyric.toml"), "[package]\nname = \"DepSfMalformed\n")

  val appDir = freshTempDir("app-malformed")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfMalformed\"\n" + "version = \"0.1.0\"\n" + "\n" + "[dependencies]\n" +
      "DepSfMalformed = { path = \"" +
      depDir +
      "\" }\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppSfMalformed.Loose\n\npub func run(): Int {\n  1\n}\n")
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertTrue(
    exitCode != 0,
    "single-file build fails loudly on a malformed dependency manifest instead of silently compiling without it"
  )
}

// Exercises the JVM branch of `emitSingleFileOrProject`: a manifest
// declaring `[maven]` entries (but no `[dependencies]`) is itself enough to
// flip `hasContribution` to true via `jvmNeedsMaven`, routing the compile
// through the synthetic project path and `injectMavenClasspathForJvm` on
// `--target jvm` — a code path none of the other new cases exercise since
// they all use `Emitter.Dotnet`. Deliberately does NOT declare a real
// restored Maven JAR (no `target/restore/jvm-classpath.txt`): the source
// itself uses no Java FFI types, so the build only needs to prove the
// routing/injection fires without error, not resolve a real classpath —
// `injectMavenClasspathForJvm` degrades to an empty classpath and a
// stderr note when the restore file is absent, not a failure.
test "buildOneNative: a manifest with [maven] entries near a single file compiles on --target jvm" {
  val appDir = freshTempDir("app-jvm-maven")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfJvmMaven\"\n" + "version = \"0.1.0\"\n" + "\n" + "[maven]\n" +
      "\"io.undertow:undertow-core\" = \"2.3.13.Final\"\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppSfJvmMaven.Loose\n\npub func run(): Int {\n  1\n}\n")
  val outPath = Path.join(appDir, "loose.jar")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Jvm, None, "", "")
  assertEqualInt(exitCode, 0, "single-file JVM build with [maven]-only manifest compiles cleanly")
  assertTrue(File.fileExists(outPath), "single-file JVM build produces the output JAR")
}

// ─── #2762: JVM builds must not emit a .runtimeconfig.json ──────────────────
// `.runtimeconfig.json` is a .NET-only artifact `dotnet exec` reads to pick a
// framework version; a JVM build produces a self-contained runnable JAR run
// directly via `java -jar`, so emitting one there is stray .NET tooling
// cruft left behind by shared build-pipeline code (`cli_build.l`'s target
// match at the `writeRuntimeConfig` call site).  Builds the identical source
// into two SEPARATE fresh directories (one per target) so the JVM directory's
// absence check can never be satisfied by a runtimeconfig.json left behind by
// a different build.
test "buildOneNative: --target jvm does not emit a .runtimeconfig.json (contrasted with --target dotnet)" {
  val dotnetDir = freshTempDir("runtimeconfig-dotnet")
  defer {
    cleanup(dotnetDir)
  }
  val dotnetSrcPath = Path.join(dotnetDir, "prog.l")
  writeFileOrPanic(dotnetSrcPath, "package RuntimeConfigDotnetFixture\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val dotnetOutPath = Path.join(dotnetDir, "prog.dll")
  val dotnetExit = Cli.buildOneNative(dotnetSrcPath, dotnetOutPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(dotnetExit, 0, "dotnet build of the fixture compiles cleanly")
  assertTrue(
    File.fileExists(Path.join(dotnetDir, "prog.runtimeconfig.json")),
    "positive control: a --target dotnet build DOES emit prog.runtimeconfig.json"
  )

  val jvmDir = freshTempDir("runtimeconfig-jvm")
  defer {
    cleanup(jvmDir)
  }
  val jvmSrcPath = Path.join(jvmDir, "prog.l")
  writeFileOrPanic(jvmSrcPath, "package RuntimeConfigJvmFixture\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val jvmOutPath = Path.join(jvmDir, "prog.jar")
  val jvmExit = Cli.buildOneNative(jvmSrcPath, jvmOutPath, Emitter.Jvm, None, "", "")
  assertEqualInt(jvmExit, 0, "jvm build of the fixture compiles cleanly")
  assertTrue(File.fileExists(jvmOutPath), "jvm build produces the output JAR")
  assertTrue(
    not File.fileExists(Path.join(jvmDir, "prog.runtimeconfig.json")),
    "a --target jvm build must NOT emit a .runtimeconfig.json beside the JAR"
  )
}

// #5353: `hasContribution`'s `activeFeatures.count > 0 or declaredFeatures.count
// > 0` term routes a single-file build through the synthetic project path even
// when a manifest declares nothing else — no `[dependencies]`, no `[maven]`, no
// `[nuget]`. Two functions with the same name, each gated by a different
// feature, only coexist without a duplicate-symbol error if `@cfg` erasure
// actually ran: with `x` active and `y` inactive, only the `x`-gated `dispatch`
// should survive, so `run()` resolves and returns 1. If a regression drops the
// features term from `hasContribution` (or fails to thread activeFeatures into
// the synthetic `EmitProjectRequest`), erasure never runs, both `dispatch`
// definitions remain, and the build fails loudly with a duplicate-symbol error
// instead of silently reverting to un-erased bare-`Emitter.emit` behavior.
test "buildOneNative: a manifest with only a [features] table near a single file routes through the synthetic path" {
  val appDir = freshTempDir("app-features-only")
  defer {
    cleanup(appDir)
  }
  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfFeatures\"\n" + "version = \"0.1.0\"\n" + "\n" + "[features]\n" +
      "default = [\"x\"]\n" +
      "x = []\n" +
      "y = []\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(
    looseSrcPath,
    "package AppSfFeatures.Loose\n\n" + "@cfg(feature = \"x\")\n" + "pub func dispatch(): Int {\n" + "  1\n" + "}\n" +
      "\n" +
      "@cfg(feature = \"y\")\n" +
      "pub func dispatch(): Int {\n" +
      "  2\n" +
      "}\n" +
      "\n" +
      "pub func run(): Int {\n" +
      "  dispatch()\n" +
      "}\n"
  )
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(
    exitCode,
    0,
    "single-file build with a [features]-only manifest routes through @cfg erasure (no duplicate `dispatch`)"
  )
  assertTrue(File.fileExists(outPath), "single-file build produces the output DLL")
}

// #5352: `hasContribution`'s `resolvedDeps.nugetThirdPartyPaths.count > 0` term
// is the one remaining independent branch of the OR-chain none of the other
// cases in this file exercise — every other case uses a `path`/workspace
// dependency, a `[maven]`-only manifest, or a bare manifest. Fixture mirrors
// `cli_shared_self_test.l`'s `resolveNugetAssets` happy-path test: a real
// `obj/project.assets.json` resolving one package-typed runtime DLL, with no
// `[dependencies]`/`[maven]`/`[features]` in the manifest at all. The "DLL" is
// a real compiled Lyric assembly (not an empty stub file) because
// `newCodegenCtx`/`addAssemblyToIndexesAndValueTypes` eagerly parse every
// `nugetAssemblyPaths` entry as PE metadata during the real compile below.
test "buildOneNative: a manifest with a genuine [nuget]-resolved third-party DLL near a single file compiles" {
  val appDir = freshTempDir("app-nuget-only")
  defer {
    cleanup(appDir)
  }
  val pkgsDir = freshTempDir("app-nuget-only-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(appDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val fixtureRelDllPath = Path.join(
    Path.join("newtonsoft.json", "13.0.3"),
    Path.join("lib", Path.join("netstandard2.0", "Newtonsoft.Json.dll"))
  )
  val fixtureDllPath = Path.join(pkgsDir, fixtureRelDllPath)
  val fixtureSrcPath = Path.join(pkgsDir, "fixture_lib.l")
  writeFileOrPanic(fixtureSrcPath, "package NugetOnlyFixtureLib\n\npub func noop(): Int {\n  0\n}\n")
  val fixtureBuildExit = Cli.buildOneNative(fixtureSrcPath, fixtureDllPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(
    fixtureBuildExit,
    0,
    "fixture third-party DLL stand-in compiles (a real PE so readAssemblyVersion doesn't choke on it)"
  )

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Newtonsoft.Json/13.0.3\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtime\": {\n" +
    "          \"lib/netstandard2.0/Newtonsoft.Json.dll\": {}\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfNugetOnly\"\n" + "version = \"0.1.0\"\n" + "\n" + "[nuget]\n" +
      "\"Newtonsoft.Json\" = \"13.0.3\"\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppSfNugetOnly.Loose\n\npub func run(): Int {\n  1\n}\n")
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitCode, 0, "single-file build with a [nuget]-only third-party-resolved manifest compiles cleanly")
  assertTrue(File.fileExists(outPath), "single-file build produces the output DLL")
}

// #5744: `hasContribution`'s `resolvedDeps.nativeAssetPaths.count > 0` term is
// the sibling of the #5352 test above — that one exercised
// `nugetThirdPartyPaths` (a genuine *managed* third-party DLL); this one
// resolves a `runtimeTargets`-only entry (no sibling `runtime` map for the
// package, so `nugetThirdPartyPaths`/`restoredDlls` both stay empty and only
// the native-asset branch of the OR-chain can route the build through the
// synthetic project path).  Also uses a runnable program (declares `main`)
// so `copyNugetNativeAssetsBeside`'s own end-to-end wiring — not just the
// pure resolver `cli_shared_self_test.l` already covers — is exercised: the
// fake native asset must actually land beside the compiled output.
test "buildOneNative: a manifest with only a NuGet-resolved native asset (no managed DLL) near a runnable program compiles and colocates it" {
  val hostRid = Environment.runtimeIdentifier()
  if hostRid.length == 0 {
    // No host RID (e.g. under a JVM CLI host) — nothing to assert against.
    return
  }
  val appDir = freshTempDir("app-native-only")
  defer {
    cleanup(appDir)
  }
  val pkgsDir = freshTempDir("app-native-only-pkgs")
  defer {
    cleanup(pkgsDir)
  }
  val objDir = Path.join(appDir, "obj")
  match File.createDir(objDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + objDir + ": " + IOError.message(e))
  }

  val nativeRelPath = "runtimes/" + hostRid + "/native/libfakenative.so"
  val fixtureFullPath = Path.join(pkgsDir, Path.join(Path.join("fake.native.pkg", "1.0.0"), nativeRelPath))
  val fixtureDir = Path.dirname(fixtureFullPath)
  match File.createDir(fixtureDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + fixtureDir + ": " + IOError.message(e))
  }
  writeFileOrPanic(fixtureFullPath, "fake native asset bytes")

  val assetsJson = "{\n" + "  \"targets\": {\n" + "    \".NETCoreApp,Version=v10.0\": {\n" +
    "      \"Fake.Native.Pkg/1.0.0\": {\n" +
    "        \"type\": \"package\",\n" +
    "        \"runtimeTargets\": {\n" +
    "          \"" +
    nativeRelPath +
    "\": { \"assetType\": \"native\", \"rid\": \"" +
    hostRid +
    "\" }\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  },\n" +
    "  \"project\": {\n" +
    "    \"restore\": {\n" +
    "      \"packagesPath\": \"" +
    Str.replace(pkgsDir, "\\", "\\\\") +
    "\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  writeFileOrPanic(Path.join(objDir, "project.assets.json"), assetsJson)

  writeManifestOrPanic(
    Path.join(appDir, "lyric.toml"),
    "[package]\n" + "name = \"AppSfNativeOnly\"\n" + "version = \"0.1.0\"\n"
  )
  val looseSrcPath = Path.join(appDir, "loose.l")
  writeFileOrPanic(looseSrcPath, "package AppSfNativeOnly.Loose\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outPath = Path.join(appDir, "loose.dll")

  val exitCode = Cli.buildOneNative(looseSrcPath, outPath, Emitter.Dotnet, None, "", "")
  assertEqualInt(
    exitCode,
    0,
    "single-file build with a native-only-resolved manifest (no [nuget]/[features]/deps) routes through the synthetic path and compiles"
  )
  assertTrue(File.fileExists(outPath), "single-file build produces the output DLL")

  val copiedPath = Path.join(Path.dirname(outPath), Path.basename(fixtureFullPath))
  assertTrue(
    File.fileExists(copiedPath),
    "copyNugetNativeAssetsBeside actually ran end-to-end and colocated the native asset beside the output"
  )
}

test "buildOneNative: a manifest with no dependencies/features near a single file is byte-identical to no manifest" {
  val noManifestDir = freshTempDir("nomanifest")
  defer {
    cleanup(noManifestDir)
  }
  val srcA = Path.join(noManifestDir, "plain.l")
  writeFileOrPanic(srcA, "package PlainSf\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outA = Path.join(noManifestDir, "plain.dll")
  val exitA = Cli.buildOneNative(srcA, outA, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitA, 0, "no-manifest fixture compiles cleanly")

  val bareManifestDir = freshTempDir("baremanifest")
  defer {
    cleanup(bareManifestDir)
  }
  writeManifestOrPanic(
    Path.join(bareManifestDir, "lyric.toml"),
    "[package]\n" + "name = \"BareManifestSf\"\n" + "version = \"0.1.0\"\n"
  )
  val srcB = Path.join(bareManifestDir, "plain.l")
  writeFileOrPanic(srcB, "package PlainSf\n\nfunc main(): Unit {\n  println(1)\n}\n")
  val outB = Path.join(bareManifestDir, "plain.dll")
  val exitB = Cli.buildOneNative(srcB, outB, Emitter.Dotnet, None, "", "")
  assertEqualInt(exitB, 0, "bare-manifest fixture compiles cleanly")

  val bytesA = match File.readBytes(outA) {
    case Ok(b) -> b
    case Err(e) -> panic("cannot read " + outA + ": " + IOError.message(e))
  }
  val bytesB = match File.readBytes(outB) {
    case Ok(b) -> b
    case Err(e) -> panic("cannot read " + outB + ": " + IOError.message(e))
  }
  assertTrue(
    bytesEqual(bytesA, bytesB),
    "a manifest with nothing dependency/feature-relevant does not change the compiled output (byte-for-byte)"
  )
}

// ─── buildProject's preResolvedDeps seam (#5786, regression test #5819) ────
// `buildReleaseProject` resolves manifest dependencies once and threads the
// result into `buildProject` via `preResolvedDeps` instead of letting
// `buildProject` re-resolve internally — the #5786 fix for a duplicated
// `checkDllIsStale`/`resolveAllNugetAssets` pass (and duplicated
// `warnIfNugetUnresolved` output) on every `--release` build. Exercises the
// seam directly rather than through a full `--release` (ILC) build: a
// dependency-free manifest can never produce a genuine
// `hadWorkspaceError = true` from an internal re-resolution, so handing
// `buildProject` a `preResolvedDeps` SENTINEL with `hadWorkspaceError = true`
// only fails the build if `buildProject` actually reads the value it was
// given — a regression that silently discarded `preResolvedDeps` and always
// re-resolved internally would flip this from a build failure back to a
// clean build, an easily observable divergence via the exit code alone.
test "buildProject: a preResolvedDeps sentinel's hadWorkspaceError is honored, not silently re-resolved" {
  val dir = freshTempDir("preresolved-sentinel")
  defer {
    cleanup(dir)
  }
  writeManifestOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\n" + "name = \"PreResolvedSentinelApp\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"PreResolvedSentinelApp\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"PreResolvedSentinelApp.Main\" = \"main.l\"\n"
  )
  writeFileOrPanic(
    Path.join(dir, "main.l"),
    "package PreResolvedSentinelApp.Main\n\nfunc main(): Unit {\n  println(1)\n}\n"
  )

  val sentinel = Cli.ResolvedManifestDeps(
    restoredDlls = newList(),
    depTemplateSrcs = newList(),
    nugetThirdPartyPaths = newList(),
    nativeAssetPaths = newList(),
    hadWorkspaceError = true,
    hadUnbuiltLocalDep = false
  )
  val noCliFeatures: List[String] = newList()
  val exitCode = Cli.buildProject(
    Path.join(dir, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noCliFeatures,
    false,
    false,
    true,
    None,
    Some(value = sentinel),
    newList()
  )
  assertEqualInt(
    exitCode,
    1,
    "a preResolvedDeps sentinel with hadWorkspaceError = true must short-circuit the build to a failure — " +
      "proves buildProject reads the handed-in resolution rather than silently re-resolving it (#5786/#5819)"
  )
}

test "buildProject: preResolvedDeps = None re-resolves internally and a dependency-free manifest still builds" {
  val dir = freshTempDir("preresolved-none")
  defer {
    cleanup(dir)
  }
  writeManifestOrPanic(
    Path.join(dir, "lyric.toml"),
    "[package]\n" + "name = \"PreResolvedNoneApp\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
      "name = \"PreResolvedNoneApp\"\n" +
      "\n" +
      "[project.packages]\n" +
      "\"PreResolvedNoneApp.Main\" = \"main.l\"\n"
  )
  writeFileOrPanic(
    Path.join(dir, "main.l"),
    "package PreResolvedNoneApp.Main\n\nfunc main(): Unit {\n  println(1)\n}\n"
  )

  val noCliFeatures: List[String] = newList()
  val exitCode = Cli.buildProject(
    Path.join(dir, "lyric.toml"),
    None,
    Emitter.Dotnet,
    noCliFeatures,
    false,
    false,
    true,
    None,
    None,
    newList()
  )
  assertEqualInt(
    exitCode,
    0,
    "with preResolvedDeps = None, buildProject re-resolves internally; a dependency-free manifest has no real " +
      "workspace error so the build succeeds — the sibling test's failure is the sentinel, not a broken fixture"
  )
}

// ─── filterExtraRefs on the JVM target (D131) ────────────────────────────
test "filterExtraRefs: on --target jvm keeps only .jar files, excluding the primary jar" {
  val files: List[String] = newList()
  files.add("/refs/Zeta.jar")
  files.add("/refs/App.jar")
  files.add("/refs/Alpha.jar")
  files.add("/refs/App.dll")
  files.add("/refs/notes.txt")
  val result = Cli.filterExtraRefs(files, "App.jar", ".jar")
  assertEqualInt(result.count, 2, "filterExtraRefs: excludes the primary jar and every non-.jar file")
  assertEqual(result[0], "/refs/Alpha.jar", "filterExtraRefs: sorted ascending, entry 0")
  assertEqual(result[1], "/refs/Zeta.jar", "filterExtraRefs: sorted ascending, entry 1")
}

// ─── stagedMavenClasspath (D131) ─────────────────────────────────────────
// The JVM `--release` path feeds this straight into `native-image -cp`, so a
// stray empty entry would become a bogus classpath element rather than a
// visible error.
test "stagedMavenClasspath: no module-path.txt yields an empty list" {
  val dir = freshTempDir("mvncp-absent")
  val result = Cli.stagedMavenClasspath(dir)
  assertEqualInt(result.count, 0, "absent module-path.txt is not an error, just no -cp")
  cleanup(dir)
}

test "stagedMavenClasspath: an empty module-path.txt yields an empty list" {
  val dir = freshTempDir("mvncp-empty")
  // buildProject writes this file unconditionally, empty when no [maven] deps.
  match File.writeText(Path.join(dir, "module-path.txt"), "") {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + IOError.message(e))
  }
  assertEqualInt(Cli.stagedMavenClasspath(dir).count, 0, "empty file yields no entries")
  cleanup(dir)
}

test "stagedMavenClasspath: splits colon-separated entries and drops blanks" {
  val dir = freshTempDir("mvncp-entries")
  // Trailing newline and a trailing separator are both realistic; neither may
  // produce an empty classpath entry.
  match File.writeText(Path.join(dir, "module-path.txt"), "/m2/guava.jar:/m2/gson.jar:\n") {
    case Ok(_) -> ()
    case Err(e) -> panic("write failed: " + IOError.message(e))
  }
  val result = Cli.stagedMavenClasspath(dir)
  assertEqualInt(result.count, 2, "two real entries, trailing separator dropped")
  assertEqual(result[0], "/m2/guava.jar", "entry 0")
  assertEqual(result[1], "/m2/gson.jar", "entry 1")
  cleanup(dir)
}

// ─── #6503: workspace-member import resolution for single-file builds ────────
// Unit tests for `resolveWorkspaceImportDeps` against a synthetic
// mini-workspace: a virtual [workspace]-only root plus one member whose
// manifest name ("Lyric.LibX") differs from its source package ("LibX"),
// mirroring the ecosystem convention (member Lyric.Mq declares package Mq).
// The member's bin DLL is a placeholder file — resolution only checks
// existence (single-file builds never build members implicitly, D123).
func mkMiniWorkspace(label: in String): String {
  val root = freshTempDir(label)
  // `assembleWorkspace` keys off section ENTRIES, so a bare `[workspace]`
  // header with no keys is not recognized as a workspace root — write an
  // explicit empty exclude list (the real repo root also carries one).
  match File.writeText(Path.join(root, "lyric.toml"), "[workspace]\nexclude = []\n") {
    case Ok(_) -> ()
    case Err(e) -> panic("write root toml: " + IOError.message(e))
  }
  val libDir = Path.join(root, "libx")
  val _ = File.createDir(libDir)
  val _ = File.createDir(Path.join(libDir, "src"))
  val _ = File.createDir(Path.join(libDir, "bin"))
  val libToml = "[package]\n" + "name    = \"Lyric.LibX\"\n" + "version = \"0.1.0\"\n" + "\n" + "[project]\n" +
    "name            = \"Lyric.LibX\"\n" +
    "output          = \"single\"\n" +
    "output_assembly = \"LibX.dll\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"LibX\" = \"src/libx.l\"\n"
  match File.writeText(Path.join(libDir, "lyric.toml"), libToml) {
    case Ok(_) -> ()
    case Err(e) -> panic("write member toml: " + IOError.message(e))
  }
  match File.writeText(Path.join(Path.join(libDir, "src"), "libx.l"), "package LibX\n\npub func answer(): Int {\n  42\n}\n") {
    case Ok(_) -> ()
    case Err(e) -> panic("write member src: " + IOError.message(e))
  }
  match File.writeText(Path.join(Path.join(libDir, "bin"), "LibX.dll"), "placeholder") {
    case Ok(_) -> ()
    case Err(e) -> panic("write member dll: " + IOError.message(e))
  }
  root
}

test "resolveWorkspaceImportDeps: package-key fallback maps import to member (#6503)" {
  val root = mkMiniWorkspace("wsimp-fallback")
  val noSeen: List[String] = newList()
  val deps = Cli.resolveWorkspaceImportDeps("package T\n\nimport LibX\n", root, noSeen)
  assertEqualInt(deps.restoredDlls.count, 1, "one member resolved via [project.packages] key")
  assertTrue(Str.startsWith(deps.restoredDlls[0], "Lyric.LibX\t"), "entry carries the member name")
  assertTrue(Str.endsWith(deps.restoredDlls[0], "LibX.dll"), "entry carries the member DLL path")
  assertEqualInt(deps.depTemplateSrcs.count, 1, "member sources collected for template resolution")
  assertFalse(deps.hadUnbuiltMember, "built member is not flagged unbuilt")
  cleanup(root)
}

test "resolveWorkspaceImportDeps: exact member-name match works for reserved-head members (#6503)" {
  val root = mkMiniWorkspace("wsimp-exact")
  val noSeen: List[String] = newList()
  val deps = Cli.resolveWorkspaceImportDeps("package T\n\nimport Lyric.LibX\n", root, noSeen)
  assertEqualInt(deps.restoredDlls.count, 1, "exact member-name match resolves despite the Lyric.* head")
  cleanup(root)
}

test "resolveWorkspaceImportDeps: unbuilt member fails loudly, compiler/stdlib heads skip (#6503)" {
  val root = mkMiniWorkspace("wsimp-unbuilt")
  val _ = File.deleteFile(Path.join(Path.join(Path.join(root, "libx"), "bin"), "LibX.dll"))
  val noSeen: List[String] = newList()
  val deps = Cli.resolveWorkspaceImportDeps("package T\n\nimport LibX\n", root, noSeen)
  assertEqualInt(deps.restoredDlls.count, 0, "unbuilt member restores nothing")
  assertTrue(deps.hadUnbuiltMember, "unbuilt member is flagged for the loud failure")
  val deps2 = Cli.resolveWorkspaceImportDeps(
    "package T\n\nimport Std.Json\nimport Lyric.Parser\nimport Msil.Bridge\n",
    root,
    noSeen
  )
  assertEqualInt(deps2.restoredDlls.count, 0, "bundle-resolved heads never match members")
  assertFalse(deps2.hadUnbuiltMember, "bundle-resolved heads are not flagged")
  cleanup(root)
}

test "resolveWorkspaceImportDeps: alreadySeen dep names are not double-restored (#6503)" {
  val root = mkMiniWorkspace("wsimp-seen")
  val seen: List[String] = newList()
  seen.add("Lyric.LibX")
  val deps = Cli.resolveWorkspaceImportDeps("package T\n\nimport LibX\n", root, seen)
  assertEqualInt(deps.restoredDlls.count, 0, "a manifest-resolved dep is not restored again")
  assertFalse(deps.hadUnbuiltMember, "no unbuilt flag for an alreadySeen dep")
  cleanup(root)
}
