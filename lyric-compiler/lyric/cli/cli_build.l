package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Parse
import Std.Hash as Hash
import Lyric.Manifest as Mf
import Lyric.BuildDefines as BD
import Lyric.Lexer
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc
import Lyric.Release as Release
import Lyric.Generator as Generator
import Lyric.Emitter as Emitter
import Lyric.AppHost as AppHost
import Lyric.CfgGate as CfgGate
import Std.Sort as Sort
import Std.Time as Time
import Std.Format as Format
import Std.Char as Ch

// Helper to extract build kind from manifest if available, defaulting to "lib".
func readBuildKindFromManifest(manifestOpt: in Option[String]): String {
  match manifestOpt {
    case None -> "lib"
    case Some(mfPath) -> {
      match File.readText(mfPath) {
        case Err(_) -> "lib"
        case Ok(mfText) -> {
          match Mf.parseManifest(mfText, mfPath) {
            case Err(_) -> "lib"
            case Ok(mf) -> getBuildKind(mf)
          }
        }
      }
    }
  }
}

// The `[build] shape` / `[build] profile` axes from a manifest (docs/63 §4.2),
// defaulting to `portable` / `debug`.  Both swallow read and parse failures and
// fall back to the default: a genuinely malformed manifest is reported by the
// build path that parses it for real, and reporting it twice from here would
// double up the diagnostic (the `readBuildKindFromManifest` precedent).
// The `[build]` section of a manifest, or None when the path is absent, the
// file is unreadable, the TOML is malformed, or no `[build]` table is present.
func readBuildSection(manifestOpt: in Option[String]): Option[Mf.BuildSection] {
  val absent: Option[Mf.BuildSection] = None
  val mfPath = match manifestOpt { case None -> return absent; case Some(p) -> p }
  val mfText = match File.readText(mfPath) { case Err(_) -> return absent; case Ok(t) -> t }
  match Mf.parseManifest(mfText, mfPath) {
    case Err(_) -> absent
    case Ok(mf) -> mf.build
  }
}

func readBuildShapeFromManifest(manifestOpt: in Option[String]): BuildShape {
  readBuildShapeFromSection(readBuildSection(manifestOpt))
}

func readBuildProfileFromManifest(manifestOpt: in Option[String]): BuildProfile {
  readBuildProfileFromSection(readBuildSection(manifestOpt))
}

// Manifest-value variants of the two helpers above: same default-on-absence
// behavior, but read the `[build]` section straight out of an already-parsed
// manifest instead of re-reading/re-parsing the file. Lets a caller who
// already parsed `lyric.toml` once (`cmdBuild`'s project-mode branch, #6193)
// avoid a redundant re-parse per axis.
func readBuildShapeFromSection(section: in Option[Mf.BuildSection]): BuildShape {
  match section {
    case None -> SPortable
    case Some(s) -> match parseShapeName(s.shape) { case Some(sh) -> sh; case None -> SPortable }
  }
}

func readBuildProfileFromSection(section: in Option[Mf.BuildSection]): BuildProfile {
  match section {
    case None -> ProfDebug
    case Some(s) -> match parseProfileName(s.profile) { case Some(p) -> p; case None -> ProfDebug }
  }
}

// The resolved build axes for one `lyric build` invocation (docs/63 §3).
pub record ResolvedAxes {
  shape: BuildShape
  profile: BuildProfile
}

// Resolve the shape axis with CLI-over-manifest-DECLARED-over-target-default
// precedence (#6268): a manifest's `[build] shape` is only defaulted OVER —
// rather than treated as an explicit user choice worth validating — when it
// was never declared at all. `BuildSection.shape` alone can't tell "the
// manifest said portable" from "the manifest said nothing" (`resolveBuildShape`
// in manifest.l parses both to the same `"portable"` string), which is exactly
// why `BuildSection.shapeDeclared` exists. The target's bare default
// (`aot` for native, since a native build is AOT by construction — docs/63
// §5.1 — `portable` otherwise) applies ONLY when neither the CLI nor the
// manifest declared a shape; a declared non-`aot` shape on `--target native`
// (from either surface) survives to `resolveAxesChecked`'s `shapeTargetError`
// check below, which raises `F0043` instead of silently upgrading it.
func resolveShapeAxis(
  cliShape: in Option[BuildShape], section: in Option[Mf.BuildSection], target: in CompileTarget
): BuildShape {
  match cliShape {
    case Some(s) -> return s
    case None -> ()
  }
  match section {
    case Some(sec) -> {
      if sec.shapeDeclared {
        return match parseShapeName(sec.shape) { case Some(sh) -> sh; case None -> SPortable }
      }
    }
    case None -> ()
  }
  match target {
    case Native -> SAot
    case _ -> SPortable
  }
}

// Resolve the shape and profile axes with CLI-over-manifest-over-default
// precedence (docs/63 §4.2 — the same precedence rule docs/60 uses for defines,
// so the toolchain has one rule and not two), then run the compatibility checks
// that depend on the resolved value: `F0043` (shape invalid for the target) and
// `F0044` (shape valid but unimplemented).
//
// `cliShape`/`cliProfile` are `None` when the user named neither on the command
// line, which is what lets a manifest value win over the default without the
// default silently overriding the manifest. Callers pass the RAW `cliShape`
// here (never pre-defaulted via a target check) — `resolveShapeAxis` above is
// the only place the target-aware default is applied, and it applies after
// consulting the manifest's `shapeDeclared` bit, not before (#6268).
pub func resolveBuildAxes(
  cliShape: in Option[BuildShape],
  cliProfile: in Option[BuildProfile],
  manifestOpt: in Option[String],
  target: in CompileTarget,
): Result[ResolvedAxes, String] {
  val section = readBuildSection(manifestOpt)
  val shape = resolveShapeAxis(cliShape, section, target)
  val profile = match cliProfile { case Some(p) -> p; case None -> readBuildProfileFromSection(section) }
  resolveAxesChecked(shape, profile, target)
}

// Manifest-value variant of `resolveBuildAxes`: same precedence and
// compatibility checks, but reads the `[build]` section straight out of an
// already-parsed manifest instead of re-reading/re-parsing `mfPath` — lets
// `cmdBuild`'s project-mode branch parse `lyric.toml` once and thread that
// single parse through the shape/profile axis resolution too (#6193).
pub func resolveBuildAxesFromManifest(
  cliShape: in Option[BuildShape],
  cliProfile: in Option[BuildProfile],
  manifest: in Option[Manifest],
  target: in CompileTarget,
): Result[ResolvedAxes, String] {
  // Explicitly typed `absent` (rather than a bare `None` arm) sidesteps a
  // match fall-through type-inference quirk (W0004/#1663): an untyped
  // `None` arm can infer its `Option[T]` from the scrutinee (`Option[Manifest]`)
  // instead of the sibling arm's actual type (`Option[BuildSection]`).
  val absent: Option[Mf.BuildSection] = None
  val section = match manifest { case None -> absent; case Some(m) -> m.build }
  val shape = resolveShapeAxis(cliShape, section, target)
  val profile = match cliProfile { case Some(p) -> p; case None -> readBuildProfileFromSection(section) }
  resolveAxesChecked(shape, profile, target)
}

// Shared compatibility-check tail of `resolveBuildAxes`/`resolveBuildAxesFromManifest`.
func resolveAxesChecked(
  shape: in BuildShape, profile: in BuildProfile, target: in CompileTarget
): Result[ResolvedAxes, String] {
  match shapeTargetError(shape, target) {
    case Some(msg) -> return Err(error = msg)
    case None -> ()
  }
  match shapeUnsupportedError(shape, target) {
    case Some(msg) -> return Err(error = msg)
    case None -> ()
  }
  Ok(value = ResolvedAxes(shape = shape, profile = profile))
}

// The `--rid` "has no effect" warning, worded for the actual target.
//
// On `--target native` the remedy the managed message suggests is unsatisfiable:
// native's shape is always `aot` (portable/standalone are `F0043` there) and
// `--rid` still does nothing, because native cross-compiles via `--triple`.
// Pointing at `--shape aot` would send the user in a circle.
pub func ridNoEffectWarning(target: in CompileTarget): String {
  match target {
    case Native -> "build: warning: --rid has no effect on --target native; use --triple to select the target platform"
    case _ -> "build: warning: --rid has no effect without --shape aot or --shape standalone"
  }
}

// The one-version migration note for `--release` without an explicit shape
// (docs/63 §6 mitigation 2). Before band B0 a bare `--release` also produced a
// self-contained Native AOT binary; now it selects the optimization profile
// only. It is a heads-up that the artifact shape changed, not a deprecation
// warning on a legacy path. Printed before the build runs, so it also appears
// ahead of a compile failure — the shape decision is already made by then, and
// deferring it until after a successful build would mean losing it exactly when
// the user is iterating on errors.
pub func releaseProfileOnlyNote(): String {
  "build: note: --release now selects the optimization profile only; it no longer implies a " +
    "self-contained native binary. Pass --aot (or --shape aot) for that. See docs/63 §6."
}

// True iff a bare `--release` on this invocation changed artifact shape relative
// to the pre-B0 behaviour — the user asked for `--release`, named no shape on
// the CLI, and the resolved shape is not `aot`. Pure so the note's trigger
// condition is unit-testable (docs/63 §6).
pub func shouldPrintReleaseNote(sawReleaseFlag: in Bool, cliShapeNamed: in Bool, resolved: in BuildShape): Bool {
  if (not sawReleaseFlag) or cliShapeNamed {
    return false
  }
  match resolved {
    case SAot -> false
    case _ -> true
  }
}

// True iff the manifest at `mfPath` declares a non-empty `[build.define]` table
// (docs/60 §3.1). Used by `cmdBuild`'s gate to reject up front — rather than
// silently drop — manifest defines on a build shape that cannot consume them
// (a non-`portable` shape routes into `buildReleaseProject`, which threads
// no defines). A read/parse failure degrades to `false`: the real build below
// surfaces the manifest error with full diagnostics.
func manifestDeclaresBuildDefines(mfPath: in String): Bool {
  match File.readText(mfPath) {
    case Err(_) -> false
    case Ok(mfText) -> {
      match Mf.parseManifest(mfText, mfPath) {
        case Err(_) -> false
        case Ok(mf) -> manifestDeclaresBuildDefinesValue(mf)
      }
    }
  }
}

// Manifest-value variant of `manifestDeclaresBuildDefines`: same predicate,
// but against an already-parsed manifest instead of re-reading/re-parsing
// `mfPath` (#6193).
func manifestDeclaresBuildDefinesValue(manifest: in Manifest): Bool {
  Mf.getManifestBuildDefines(manifest).count > 0
}

// The rejection message for a manifest `[build.define]` table on a build shape
// that cannot consume it (docs/60 §3.1). `reason` names the specific shape.
pub func manifestDefinesUnsupportedMsg(mfPath: in String, reason: in String): String {
  "build: [build.define] in " + mfPath + " is not supported with " + reason +
    "; manifest defines are threaded on portable-shape project builds (#5852/#5977)"
}

// Pure accept/reject predicate for a manifest `[build.define]` table on a
// project build (docs/60 §3.1 / #6139). Returns `Some(message)` when the manifest
// declares defines and the build *shape* cannot consume them, or `None` when the
// defines can be applied.
//
// docs/63 band B0 re-scoped this from the `--release` flag to the shape axis.
// The AOT-packaging path is what threads no defines; the optimization profile
// has nothing to do with it. So `--release --shape portable` now correctly
// accepts manifest defines, where before it was rejected for the wrong reason.
//
// `--target native` consumes defines (#5977: list literals + module-level `val`
// inlining). `--watch` is intentionally absent: `buildProject` reapplies the
// manifest defines on every rebuild, so it is not a silent-drop shape.
// Pulled out of `cmdBuild` so the reject matrix is unit-testable without a build
// (#6188), mirroring `defineBuildGateError`.
pub func manifestDefineGateError(
  mfHasDefines: in Bool,
  shape: in BuildShape,
  target: in CompileTarget,
  mfPath: in String,
): Option[String] {
  if not mfHasDefines {
    return None
  }
  if not usesPackagingPipeline(shape, target) {
    return None
  }
  Some(
    value = manifestDefinesUnsupportedMsg(
      mfPath,
      "--shape " + shapeName(shape) + " (the packaging path threads no defines)"
    )
  )
}

// Resolve the `[native]` config for a `--target native` build (N6.4):
// honour an explicit `--manifest`, else discover the nearest lyric.toml.
// An **explicitly supplied** `--manifest` that cannot be read or parsed
// (e.g. a malformed `[native]` table, or an out-of-range `opt_level`) is
// surfaced as `Err(message)` so the build fails loudly — the user pointed
// at that file on purpose (#4863).  A **discovered** manifest degrades to
// `Ok(None)` on any read/parse failure so a native single-file build is
// never blocked by an unrelated malformed lyric.toml found up the tree.
// `Ok(None)` also covers "no manifest found" and "no `[native]` table".
func resolveNativeConfig(manifestPath: in Option[String]): Result[Option[Mf.NativeConfig], String] {
  // Explicitly typed so the emitter cannot mistype a bare `None` arm as
  // `Option<String>` (the self-hosted lowerMatchExprMsil fall-through bug,
  // #1663 / #3943, which an earlier draft of this function tripped through
  // ilverify): every "no config" leaf returns this pinned value.
  val noneCfg: Option[Mf.NativeConfig] = None
  match manifestPath {
    case Some(p) -> match File.readText(p) {
      case Err(e) -> Err(error = "build: cannot read manifest " + p + ": " + IOError.message(e))
      case Ok(mfText) -> match Mf.parseManifest(mfText, p) {
        case Err(me) -> Err(error = "build: " + ManifestError.message(me))
        case Ok(m) -> Ok(value = m.native)
      }
    }
    case None -> match discoverManifest(None) {
      case None -> Ok(value = noneCfg)
      case Some(mf) -> match File.readText(mf) {
        case Err(_) -> Ok(value = noneCfg)
        case Ok(mfText) -> match Mf.parseManifest(mfText, mf) {
          case Err(_) -> Ok(value = noneCfg)
          case Ok(m) -> Ok(value = m.native)
        }
      }
    }
  }
}

// Default the `--target native` clang `-O` level from the resolved BUILD
// PROFILE (docs/63 §5.2 Q-BP-003, #6263) when neither `--opt` nor the
// manifest's `[native] opt_level` supply one: `release` gets `-O2` (matching
// the pre-existing hardcoded default in `Lyric.LlvmBridge.linkAndEmitNative`),
// `debug` gets `-O0`, matching `docs/01-language-reference.md`'s
// `--opt`/`[native] opt_level` precedence note. Resolved HERE — one level up
// from `buildOneNativeWithFeatures` — rather than by widening that function's
// signature, so its existing ~35 direct self-test call sites (which pass an
// explicit `""` opt and rely on the OLD unconditional `-O2` default deep in
// `linkAndEmitNative`) are completely unaffected; only a real
// `cmdBuild`/`cmdRun` CLI invocation, which alone has a resolved
// `BuildProfile` in scope, goes through this. A non-Native target, or a
// non-empty `cliOpt`, is returned unchanged — this function's only job is
// filling in the "nobody said anything" case for native. `pub` so
// `cli_build_self_test.l` can pin the precedence/defaulting behavior
// directly (#6263).
pub func resolveNativeOptDefault(
  cliOpt: in String,
  manifestPath: in Option[String],
  target: in CompileTarget,
  profile: in BuildProfile,
): String {
  if cliOpt != "" {
    return cliOpt
  }
  match target {
    case Native -> ()
    case _ -> return cliOpt
  }
  match resolveNativeConfig(manifestPath) {
    case Ok(ncOpt) -> match ncOpt { case Some(nc) -> { if nc.optLevel != "" { return nc.optLevel } }; case None -> () }
    case Err(_) -> ()  // a malformed manifest is reported for real by the actual build call below
  }
  match profile {
    case ProfRelease -> "2"
    case ProfDebug -> "0"
  }
}

// Rejects the two unambiguous foot-guns from `--package-version` (#4426): an
// empty value (which would embed a blank <Version> and fail cryptically
// inside contract metadata / `dotnet pack`) and a leading 'v'/'V' prefix (a
// common git-tag artifact — NuGet SemVer2 does not accept a "v" prefix).
// Full SemVer2 grammar validation is intentionally left to `dotnet pack`
// itself: NuGet accepts a wider version syntax (up to 4 numeric components)
// than strict SemVer, so re-implementing that grammar here risks rejecting
// versions NuGet would happily accept.
pub func validatePackageVersionArg(v: in String): Option[String] {
  if Str.isEmpty(Str.trim(v)) {
    return Some(value = "--package-version requires a non-empty value")
  }
  if v.length > 1 and (v[0] == 'v' or v[0] == 'V') and Ch.isAsciiDigit(v[1]) {
    return Some(
      value = "--package-version '" + v + "' has a leading '" + ("" + v[0]) +
        "' prefix, which NuGet SemVer2 does not accept — use '" +
        Str.substring(v, 1, v.length - 1) +
        "' instead"
    )
  }
  None
}

// Message for the `--release-from-dll` positional-argument warning: source
// files passed alongside `--release-from-dll` are ignored (the DLL is
// already built).  Pulled out of `cmdBuild` so the exact wording is
// unit-testable without invoking the native AOT release path (#4282).
pub func releaseFromDllIgnoredArgsWarning(positional: in List[String]): String {
  "build: warning: source-file arguments are ignored alongside --release-from-dll: " + Str.joinList(", ", positional)
}

// Pure accept/reject predicate for `lyric build --define` (#5852 / #6139).
// Returns `Some(message)` when `--define` is not supported for the given build
// shape, or `None` when it is allowed. All three backends consume defines now
// (dotnet/jvm #5852, native #5977), so `targetConsumable` is `true` for every
// current target (the parameter stays for a future non-consumable target).
//
// docs/63 band B0 re-scoped this from the `--release` flag to the shape axis:
// it is the AOT-packaging path that threads no defines, not the optimization
// profile. `--release --shape portable --define K=V` is therefore accepted now,
// where before it was rejected for a reason that did not apply.
//
// Every path that would otherwise drop the defines silently is still rejected
// up front:
//   - a non-consumable target (none today),
//   - `--watch` (the rebuild action carries no defines), and
//   - a non-portable shape (the packaging paths thread no defines).
// Pulled out of `cmdBuild` so the accept/reject matrix is unit-testable without
// a manifest round-trip (#6140). `shapeManifestPath` names the manifest that
// *configured the shape*, and only that: pass "" whenever the shape came from a
// CLI flag, even in project mode, or the advice tells the user to edit a
// manifest key they never set (#6277).
pub func defineBuildGateError(
  hasDefines: in Bool,
  targetConsumable: in Bool,
  watch: in Bool,
  shape: in BuildShape,
  target: in CompileTarget,
  shapeManifestPath: in String,
): Option[String] {
  if not hasDefines {
    return None
  }
  if (not targetConsumable) or watch {
    return Some(
      value = "build: --define is supported on single-file and project (--manifest / lyric.toml) --target dotnet/jvm/native builds; it is not supported with --watch"
    )
  }
  if not usesPackagingPipeline(shape, target) {
    return None
  }
  // The advice has to match how the shape was actually selected: telling a user
  // to "build without --aot" is useless when the shape came from their manifest
  // and no such flag was ever passed.
  val fix = if shapeManifestPath.length > 0 {
    " (configured in " + shapeManifestPath + ") — the packaging build path does not thread defines (#5852); " +
      "drop --define, or set shape = \"portable\" in that manifest"
  } else {
    " — the packaging build path does not thread defines (#5852); drop --define, or build without --aot/--standalone"
  }
  Some(value = "build: --define is not supported with --shape " + shapeName(shape) + fix)
}

// Filter a `--extra-refs-dir` directory listing down to the extra references
// for `--release-from-dll`: only files with extension `ext` (`.dll` on the
// .NET target, `.jar` on the JVM target), excluding the primary artifact
// itself (`artifactBase`, the release target's own basename) and
// `Lyric.Stdlib.dll` (colocated independently by the .NET release pipeline
// via `locateStdlib`, so including it here would duplicate it; on the JVM
// target the stdlib closure is compiled into the bundled JAR and no such file
// exists, making the exclusion inert rather than wrong).  Sorted for
// deterministic ordering.  Pulled out of `cmdBuild` so the filtering logic
// is unit-testable without invoking the (heavy, toolchain-dependent) native
// release path (#4282).
pub func filterExtraRefs(files: in List[String], artifactBase: in String, ext: in String): List[String] {
  val result: List[String] = newList()
  val sorted = Sort.sortStrings(files.toArray())
  for f in sorted {
    val fBase = Path.basename(f)
    if Str.endsWith(f, ext) and fBase != artifactBase and fBase != "Lyric.Stdlib.dll" {
      result.add(f)
    }
  }
  result
}

// The parsed manifest driving a single-file build's dependency resolution,
// alongside the raw path/text `resolveManifestFeatures` also needs (feature
// resolution scans the raw TOML text directly rather than the parsed
// `Manifest` — see `Mf.readFeatureDefaultsFromToml`).
record LoadedManifest {
  manifest: Manifest
  mfPath: String
  mfText: String
}

// The result of `emitSingleFileOrProject`: the emit outcome plus whatever
// restored-dependency / third-party-NuGet DLL paths it resolved (empty when
// no manifest contributed anything).  `buildOneNative` needs these back so
// its existing stdlib-colocation step can ALSO colocate the newly-resolved
// dependency DLLs beside a runnable program's output — otherwise a program
// that now compiles against a workspace/path dependency would fail at
// `dotnet exec` time with a missing-assembly error (D123).
record NonNativeEmitOutcome {
  emitResult: EmitResult
  restoredDlls: List[String]
  nugetThirdPartyPaths: List[String]
  nativeAssetPaths: List[String]
}

// Discover the nearest lyric.toml for a SINGLE-FILE build by walking up from
// the source file's OWN directory — deliberately NOT
// `Environment.currentDirectory()` (the convention `discoverManifest` / the
// project-mode commands use).  `lyric build sub/dir/foo.l` must find a
// lyric.toml relative to `foo.l`'s own location, matching what a project
// rooted at `sub/dir/` would see, regardless of where the invoking shell's
// cwd happens to be.  `sourcePath` is absolutized first: a bare relative
// filename like "foo.l" has `Path.dirname` == "." and walking up from "."
// alone can never leave the cwd, so resolving against
// `Environment.currentDirectory()` first is required for the walk to reach
// any parent directory at all (D123).
func discoverManifestForSourceFile(sourcePath: in String): Option[String] {
  val absSource = if Path.isAbsolute(sourcePath) {
    sourcePath
  } else {
    Path.join(Environment.currentDirectory(), sourcePath)
  }
  Disc.findNearestManifest(Path.dirname(absSource))
}

// Load + parse the manifest that should drive a single-file build's
// dependency resolution.  Mirrors `resolveNativeConfig`'s explicit-vs-
// discovered asymmetry (#4863): an EXPLICIT `--manifest` that fails to read
// or parse is a loud `Err` (the user pointed at this file on purpose); a
// manifest found by walking up from the source file's own directory
// degrades silently to `Ok(None)` on any read/parse failure (or when none is
// found at all), so an unrelated malformed lyric.toml elsewhere in the tree
// never blocks an otherwise-independent single-file build.
func loadManifestForSingleFileBuild(
  sourcePath: in String, explicitManifest: in Option[String]
): Result[Option[LoadedManifest], String] {
  val noneLm: Option[LoadedManifest] = None
  match explicitManifest {
    case Some(p) -> match File.readText(p) {
      case Err(e) -> Err(error = "build: cannot read manifest " + p + ": " + IOError.message(e))
      case Ok(mfText) -> match Mf.parseManifest(mfText, p) {
        case Err(me) -> Err(error = "build: " + ManifestError.message(me))
        case Ok(m) -> Ok(
          value = Some(
            value = LoadedManifest(
              manifest = m,
              mfPath = p,
              mfText = mfText
            )
          )
        )
      }
    }
    case None -> match discoverManifestForSourceFile(sourcePath) {
      case None -> Ok(value = noneLm)
      case Some(mf) -> match File.readText(mf) {
        case Err(_) -> Ok(value = noneLm)
        case Ok(mfText) -> match Mf.parseManifest(mfText, mf) {
          case Err(_) -> Ok(value = noneLm)
          case Ok(m) -> Ok(
            value = Some(
              value = LoadedManifest(
                manifest = m,
                mfPath = mf,
                mfText = mfText
              )
            )
          )
        }
      }
    }
  }
}

// The dotted package names `source` imports, in first-appearance order.
// A text scan over lines beginning with `import ` (the same idiom as
// `Release.packageNameOf`), taking the dotted path token, dropping any
// `as Alias` suffix and inline comment, and skipping `import extern`
// (an FFI form, not a package reference).
func importedPackageNames(source: in String): List[String] {
  val names: List[String] = newList()
  val lines = Str.split(source, "\n")
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if Str.startsWith(line, "import ") {
      var rest = Str.trim(Str.substring(line, 7, Str.length(line) - 7))
      match Str.indexOf(rest, "//") {
        case Some(ci) -> {
          rest = Str.trim(Str.substring(rest, 0, ci))
        }
        case None -> ()
      }
      match Str.indexOf(rest, " ") {
        case Some(si) -> {
          rest = Str.substring(rest, 0, si)
        }
        case None -> ()
      }
      if rest.length > 0 and rest != "extern" {
        if not stringListContains(names, rest) {
          names.add(rest)
        }
      }
    }
    i += 1
  }
  names
}

// The manifest's own [project.packages] entries reachable from `source`'s
// transitive import closure, read + generator-preprocessed via
// `readProjectPackageSources`.  A single-file build near a manifest could
// previously never compile a file that imports one of the manifest's own
// packages (`lyric build tests/x.l` inside a library tree): the synthetic
// one-package request carried only dependencies, so `import Web` either
// failed to resolve or fell through to an unrelated same-named function
// (#5571).  Including exactly the imported packages (not the whole
// [project.packages] table) keeps the D123 "only when earning its keep"
// gate intact for loose scripts that merely sit near a manifest.
// Returns None after printing errors when a package's sources cannot be
// read.
// `Std.*` / `Lyric.*` manifest entries must never be swept in as own
// packages: those heads resolve through the stdlib / compiler restored
// bundles, and compiling them into the user assembly double-books their
// types against the bundle registration (a file built near
// lyric-stdlib/lyric.toml lost `Std.Core.Option_Some` resolution this way).
func isReservedHeadPackage(name: in String): Bool {
  name == "Std" or name == "Lyric" or Str.startsWith(name, "Std.") or Str.startsWith(name, "Lyric.")
}

func collectImportedOwnPackages(
  proj: in ProjectSection,
  mfDir: in String,
  mfPath: in String,
  source: in String,
  ownPkgName: in String,
): Option[List[ProjectPackage]] {
  val needed = importedPackageNames(source)
  // Never include a manifest entry carrying the source's own package name:
  // building one of the project's own package files directly (`lyric build
  // src/web.l`) can pull the file's own package back into `needed` through
  // a sibling's import cycle, and bundling two declarations of the same
  // package is a compile error.
  val included: List[String] = newList()
  included.add(ownPkgName)
  val result: List[ProjectPackage] = newList()
  var hadFatal = false
  var changed = true
  while changed and not hadFatal {
    changed = false
    var pi = 0
    while pi < proj.packages.count {
      val pkgEntry = proj.packages[pi]
      if stringListContains(needed, pkgEntry.name) and not stringListContains(included, pkgEntry.name) and not isReservedHeadPackage(pkgEntry.name) {
        match readProjectPackageSources(pkgEntry, mfDir, mfPath) {
          case Some(pkgRead) -> {
            val pkgSources = pkgRead.sources
            included.add(pkgEntry.name)
            changed = true
            if pkgSources.count > 0 {
              result.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources, paths = pkgRead.paths))
              var si = 0
              while si < pkgSources.count {
                val innerNames = importedPackageNames(pkgSources[si])
                var ni = 0
                while ni < innerNames.count {
                  if not stringListContains(needed, innerNames[ni]) {
                    needed.add(innerNames[ni])
                  }
                  ni += 1
                }
                si += 1
              }
            }
          }
          case None -> {
            hadFatal = true
          }
        }
      }
      pi += 1
    }
  }
  if hadFatal {
    val noPkgs: Option[List[ProjectPackage]] = None
    return noPkgs
  }
  Some(value = result)
}

func noContributionOutcome(req: in EmitRequest): NonNativeEmitOutcome {
  NonNativeEmitOutcome(
    emitResult = Emitter.emit(req),
    restoredDlls = newList(),
    nugetThirdPartyPaths = newList(),
    nativeAssetPaths = newList()
  )
}

func failedEmitOutcome(msg: in String): NonNativeEmitOutcome {
  printErr(msg)
  val noDiags: List[Diagnostic] = newList()
  NonNativeEmitOutcome(
    emitResult = EmitResult(outputPath = None, diagnostics = noDiags),
    restoredDlls = newList(),
    nugetThirdPartyPaths = newList(),
    nativeAssetPaths = newList()
  )
}

// Non-native (Dotnet/Jvm) emit path for `buildOneNative`.  When the source
// file sits near a lyric.toml — an explicit `--manifest`, or one discovered
// by walking up from the source file's own directory
// (`discoverManifestForSourceFile`) — that actually declares dependencies,
// NuGet/Maven assets, features, or [project.packages] the source imports,
// synthesizes a project-shaped `EmitProjectRequest` and routes it through
// `Emitter.emitProject`: the same dependency-resolution and bundling
// pipeline `buildProject` uses for a manifest's `[project.packages]`,
// instead of the standalone `Emitter.emit` path, which structurally cannot
// see anything outside `Std.*` (D123).  The manifest's own packages that
// the source (transitively) imports are compiled into the request
// alongside the source's package (`collectImportedOwnPackages`, #5571),
// and the caller's `--features` / `--no-default-features` /
// `--all-features` selection is honored exactly as in a project build.
//
// Falls back to the historical `Emitter.emit(req)` path UNCHANGED whenever
// there is nothing for the new pipeline to contribute: no manifest found at
// all, or a manifest found but declaring nothing dependency/feature-relevant
// — so the overwhelmingly common case (a standalone script, a stdlib
// self-test, anything with no nearby lyric.toml) compiles byte-for-byte
// identically to before.  This gate is deliberate, not incidental: routing
// EVERY single-file compile through `emitProject` unconditionally was
// measured (empirically, by diffing output bytes) to change the output even
// with zero dependencies — the project bridge embeds its `Lyric.Contract`
// resource as `Lyric.Contract.<pkg>` (the multi-package convention) rather
// than single-file's bare `Lyric.Contract` — so the new path is only taken
// when it is actually earning its keep.
//
// A dependency the manifest declares but that has not been built/restored
// yet fails the build loudly (`hadUnbuiltLocalDep`) instead of silently
// compiling without it: single-file mode never triggers an implicit
// restore (a deliberate, conservative default — see the decision log).
func emitSingleFileOrProject(
  req: in EmitRequest,
  sourcePath: in String,
  manifestPath: in Option[String],
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
): NonNativeEmitOutcome {
  val loaded = match loadManifestForSingleFileBuild(sourcePath, manifestPath) {
    case Err(msg) -> return failedEmitOutcome(msg)
    case Ok(opt) -> opt
  }
  val lm = match loaded {
    case None -> {
      // #6503: no usable manifest above the source — the workspace ROOT is a
      // virtual [workspace]-only manifest `findNearestManifest` deliberately
      // walks past (no [package] section) — but the file can still import
      // WORKSPACE MEMBERS.  Resolve its imports against already-built member
      // DLLs; when nothing matches, fall back to the historical
      // no-contribution path byte-for-byte unchanged.
      return emitSingleFileWithWorkspaceMembers(req, sourcePath)
    }
    case Some(l) -> l
  }

  val (activeFeatures, declaredFeatures) = resolveManifestFeatures(
    lm.mfText,
    lm.mfPath,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    req.target
  )
  val resolvedDeps = resolveManifestDependencies(lm.manifest, lm.mfPath, req.target, cliFeatures, noDefaultFeatures)
  if resolvedDeps.hadWorkspaceError {
    return failedEmitOutcome(
      sourcePath + ": build failed (workspace dependency declared in " + lm.mfPath + " failed to build; see above)"
    )
  }
  if resolvedDeps.hadUnbuiltLocalDep {
    return failedEmitOutcome(
      sourcePath + ": build failed (unresolved dependency declared in " + lm.mfPath + "; see above)"
    )
  }

  val pkgNameRaw = Release.packageNameOf(req.source)
  val pkgName = if pkgNameRaw.length > 0 { pkgNameRaw } else { req.assemblyName }

  val noOwnPkgs: List[ProjectPackage] = newList()
  val ownPkgs = match lm.manifest.project {
    case Some(proj) -> match collectImportedOwnPackages(proj, Path.dirname(lm.mfPath), lm.mfPath, req.source, pkgName) {
      case Some(ps) -> ps
      case None -> return failedEmitOutcome(
        sourcePath + ": build failed (cannot read a [project.packages] source declared in " + lm.mfPath +
          "; see above)"
      )
    }
    case None -> noOwnPkgs
  }

  val hasMavenEntries = match lm.manifest.maven { case Some(m) -> m.entries.count > 0; case None -> false }
  val jvmNeedsMaven = match req.target { case Jvm -> hasMavenEntries; case _ -> false }

  val hasContribution = resolvedDeps.restoredDlls.count > 0 or resolvedDeps.nugetThirdPartyPaths.count > 0 or
    resolvedDeps.nativeAssetPaths.count > 0 or
    activeFeatures.count > 0 or
    declaredFeatures.count > 0 or
    resolvedDeps.depTemplateSrcs.count > 0 or
    ownPkgs.count > 0 or
    jvmNeedsMaven

  if not hasContribution {
    return noContributionOutcome(req)
  }

  // docs/60 (#5852 phase C): this single-file build routed to the project path
  // (a nearby lyric.toml contributes dependencies/features). `req.defines` (the
  // user's `--define`s) is threaded into the project request below, merged
  // beneath the manifest's well-known `version` in the bridges.

  val srcs: List[String] = newList()
  srcs.add(req.source)
  val ownPaths: List[String] = newList()
  ownPaths.add(sourcePath)
  val pkgs: List[ProjectPackage] = newList()
  // The source's own package goes FIRST: the JVM bundled compile takes
  // `packages[0].name` as the bundle's entry package, and the MSIL entry
  // scan is first-wins (#2885) — same ordering convention as `cmdTest`'s
  // test-package-first layout.
  pkgs.add(ProjectPackage(name = pkgName, sources = srcs, paths = ownPaths))
  var opi = 0
  while opi < ownPkgs.count {
    pkgs.add(ownPkgs[opi])
    opi += 1
  }

  // Jvm parity with `buildProjectFromManifest`: a workspace/path dependency's
  // own packages must ride the same bundled compile as `pkgs` — Jvm gets
  // nothing from `resolvedDeps.restoredDllPaths`, which
  // `resolveManifestDependencies` never populates for Jvm (#6136, #6697) —
  // see that function's comment for the full rationale.
  match req.target {
    case Jvm -> {
      var jdpi = 0
      while jdpi < resolvedDeps.depTemplateSrcs.count {
        pkgs.add(resolvedDeps.depTemplateSrcs[jdpi])
        jdpi += 1
      }
    }
    case _ -> ()
  }

  val projReq = EmitProjectRequest(
    packages = pkgs,
    assemblyName = req.assemblyName,
    outputPath = req.outputPath,
    target = req.target,
    restoredDllPaths = resolvedDeps.restoredDlls,
    activeFeatures = activeFeatures,
    declaredFeatures = declaredFeatures,
    packageVersion = req.packageVersion,
    depTemplateSrcs = resolvedDeps.depTemplateSrcs,
    nugetAssemblyPaths = resolvedDeps.nugetThirdPartyPaths,
    defines = req.defines
  )

  var mavenSaved: Option[String] = None
  match req.target {
    case Jvm -> {
      val injection = injectMavenClasspathForJvm(Path.dirname(lm.mfPath), lm.manifest)
      mavenSaved = injection.savedFfiJars
    }
    case _ -> ()
  }

  val emitResult = Emitter.emitProject(projReq)
  restoreMavenClasspath(mavenSaved)

  NonNativeEmitOutcome(
    emitResult = emitResult,
    restoredDlls = resolvedDeps.restoredDlls,
    nugetThirdPartyPaths = resolvedDeps.nugetThirdPartyPaths,
    nativeAssetPaths = resolvedDeps.nativeAssetPaths
  )
}

// #6503: the manifestless single-file leg of `emitSingleFileOrProject` —
// resolve the source's imports against the enclosing workspace's members
// (already-built DLLs only, see `resolveWorkspaceImportDeps`) and, when any
// match, synthesize the same project-shaped request the manifest leg builds:
// restored member DLLs on MSIL, bundled member sources on JVM (#6136
// parity).  No manifest means no features / own-packages / NuGet / Maven
// contribution — those axes stay empty.
func emitSingleFileWithWorkspaceMembers(req: in EmitRequest, sourcePath: in String): NonNativeEmitOutcome {
  val absSource = if Path.isAbsolute(sourcePath) {
    sourcePath
  } else {
    Path.join(Environment.currentDirectory(), sourcePath)
  }
  val noSeen: List[String] = newList()
  val wsDeps = resolveWorkspaceImportDeps(req.source, Path.dirname(absSource), noSeen, req.target)
  if wsDeps.hadUnbuiltMember {
    return failedEmitOutcome(sourcePath + ": build failed (an import names an unbuilt workspace member; see above)")
  }
  // On Jvm a matched member never contributes to `restoredDlls` (#6771) —
  // its SOURCE in `depTemplateSrcs` is what the JVM bundle needs, so check
  // both rather than just `restoredDlls`, or a JVM single-file build with a
  // workspace-member import would fall through to `noContributionOutcome`
  // and compile the import as an unresolved-call fallback (#6503).
  if wsDeps.restoredDlls.count == 0 and wsDeps.depTemplateSrcs.count == 0 {
    return noContributionOutcome(req)
  }
  val pkgNameRaw = Release.packageNameOf(req.source)
  val pkgName = if pkgNameRaw.length > 0 { pkgNameRaw } else { req.assemblyName }
  val srcs: List[String] = newList()
  srcs.add(req.source)
  val ownPaths: List[String] = newList()
  ownPaths.add(sourcePath)
  val pkgs: List[ProjectPackage] = newList()
  pkgs.add(ProjectPackage(name = pkgName, sources = srcs, paths = ownPaths))
  // JVM parity with the manifest leg: member packages ride the bundled
  // compile — the JVM leg below deliberately never forwards `wsDeps.restoredDlls`
  // into `EmitProjectRequest.restoredDllPaths` (#6136, #6697).
  match req.target {
    case Jvm -> {
      var wj = 0
      while wj < wsDeps.depTemplateSrcs.count {
        pkgs.add(wsDeps.depTemplateSrcs[wj])
        wj += 1
      }
    }
    case _ -> ()
  }
  val noFeatures: List[String] = newList()
  val noNuget: List[String] = newList()
  val noRestoredDlls: List[String] = newList()
  // #6697: a matched member's `bin/<name>.dll` is always an MSIL PE (never
  // a JVM-compatible JAR); on `--target jvm` the member's SOURCE already
  // rides the bundle via `pkgs` above, so feeding its `.dll` path into
  // `restoredDllPaths` here would hit the same JAR-parse hard-fail in
  // `emitProjectJvmInProcess` that the manifest leg's fix
  // (`resolveManifestDependencies`) addresses.
  val projReq = EmitProjectRequest(
    packages = pkgs,
    assemblyName = req.assemblyName,
    outputPath = req.outputPath,
    target = req.target,
    restoredDllPaths = match req.target { case Jvm -> noRestoredDlls; case _ -> wsDeps.restoredDlls },
    activeFeatures = noFeatures,
    declaredFeatures = noFeatures,
    packageVersion = req.packageVersion,
    depTemplateSrcs = wsDeps.depTemplateSrcs,
    nugetAssemblyPaths = noNuget,
    defines = req.defines
  )
  val emitResult = Emitter.emitProject(projReq)
  NonNativeEmitOutcome(
    emitResult = emitResult,
    restoredDlls = wsDeps.restoredDlls,
    nugetThirdPartyPaths = newList(),
    nativeAssetPaths = newList()
  )
}

// Compile `sourcePath` to a DLL at `outPath`.
// Returns the exit code: 0 on success, 1 on error.
// `manifestPath` is forwarded to the generator pre-processor so custom
// @generate(Pkg.Name) annotations can resolve their generator DLLs.
// `pub` so `cli_build_self_test.l` can drive the stdlib/restored-dep
// colocation behavior directly against a temp source file (#4127).
pub func buildOne(
  sourcePath: in String, outPath: in String, target: in CompileTarget, manifestPath: in Option[String]
): Int {
  buildOneNative(sourcePath, outPath, target, manifestPath, "", "")
}

// `nativeTriple` / `nativeOpt` only apply to `--target native` (the
// `--triple` / `--opt` flags); empty strings mean host triple / -O2.
// Callers with no CLI feature selection of their own (`lyric run`, the
// self-tests) use this default-feature entry point; `cmdBuild` threads the
// user's `--features` / `--no-default-features` / `--all-features` through
// `buildOneNativeWithFeatures` below (#5571).
pub func buildOneNative(
  sourcePath: in String,
  outPath: in String,
  target: in CompileTarget,
  manifestPath: in Option[String],
  nativeTriple: in String,
  nativeOpt: in String,
): Int {
  val noCliFeatures: List[String] = newList()
  val noCliDefines: List[String] = newList()
  buildOneNativeWithFeatures(
    sourcePath,
    outPath,
    target,
    manifestPath,
    nativeTriple,
    nativeOpt,
    noCliFeatures,
    false,
    false,
    noCliDefines
  )
}

pub func buildOneNativeWithFeatures(
  sourcePath: in String,
  outPath: in String,
  target: in CompileTarget,
  manifestPath: in Option[String],
  nativeTriple: in String,
  nativeOpt: in String,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  cliDefines: in List[String],
): Int {
  val buildStart = Time.now()
  var source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }

  // Run custom @generate(X.Y) pre-processing before handing source to the
  // emitter.  Built-in generators (@generate(Json) etc.) are handled later
  // inside the F# bootstrap's Generate.synthesizeItems pass.
  source = match Generator.preprocess(source, match manifestPath { case Some(p) -> p; case None -> "" }, sourcePath) {
    case Ok(augmented) -> augmented
    case Err(msg) -> {
      printErr("build: generator error: " + msg)
      return 1
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: cannot create output dir: " + IOError.message(e))
  }

  val outBase = Path.basename(outPath)
  val asmName = stemOf(outBase, 4)  // strip ".dll"
  val req = EmitRequest(
    source = source,
    assemblyName = asmName,
    outputPath = outPath,
    target = target,
    packageVersion = "",
    defines = cliDefines,
    path = sourcePath
  )

  // var-mutation shape (stage-0 value-position-match lowering gap,
  // #4631; see cli_run.l's runTarget note).
  var isNativeTarget = false
  match target {
    case Native -> {
      isNativeTarget = true
    }
    case _ -> ()
  }
  // Merge [native] manifest defaults with the CLI knobs (N6.4): the
  // --triple/--opt flags (non-empty) override the manifest triple/opt_level;
  // extra_libs is manifest-only and applied unconditionally.
  var effTriple = nativeTriple
  var effOpt = nativeOpt
  val effLibs: List[String] = newList()
  if isNativeTarget {
    val ncResult = resolveNativeConfig(manifestPath)
    match ncResult {
      case Err(msg) -> {
        printErr(msg)
        return 1
      }
      case Ok(ncOpt) -> match ncOpt {
        case Some(nc) -> {
          if effTriple == "" {
            effTriple = nc.triple
          }
          if effOpt == "" {
            effOpt = nc.optLevel
          }
          for lib in nc.extraLibs {
            effLibs.add(lib)
          }
        }
        case None -> ()
      }
    }
  }
  var resolvedRestoredDlls: List[String] = newList()
  var resolvedNugetPaths: List[String] = newList()
  var resolvedNativePaths: List[String] = newList()
  val result = if isNativeTarget {
    Emitter.emitNative(req, effTriple, effOpt, effLibs)
  } else {
    val outcome = emitSingleFileOrProject(req, sourcePath, manifestPath, cliFeatures, noDefaultFeatures, allFeatures)
    resolvedRestoredDlls = outcome.restoredDlls
    resolvedNugetPaths = outcome.nugetThirdPartyPaths
    resolvedNativePaths = outcome.nativeAssetPaths
    outcome.emitResult
  }
  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError -> {
        hadError = true
      }
      case DiagWarning -> ()
    }
    printDiag(d)
  }

  if hadError {
    printErr(sourcePath + ": build failed")
    return 1
  }

  // Also check the output path: if the emitter reported no diagnostics but
  // still failed (e.g. the --internal-build subprocess exited non-zero with
  // errors already printed to stderr), outputPath will be None.
  match result.outputPath {
    case None -> {
      printErr(sourcePath + ": build failed")
      return 1
    }
    case Some(_) -> ()
  }

  // A `.runtimeconfig.json` is a .NET-only artifact consumed by `dotnet exec`;
  // a JVM build produces a self-contained runnable JAR, so emitting one there
  // would leave stray .NET tooling cruft next to the JAR.
  match target {
    case Dotnet -> {
      writeRuntimeConfig(outPath)
      // A runnable program (declares a zero-arg `main`) needs its managed
      // dependencies beside the output to run standalone — `dotnet exec` (and a
      // native apphost) resolve from the assembly's own directory and there is
      // no probing path back to the toolchain lib dir.  Co-locate the stdlib
      // bundle so `lyric build prog.l` yields a working artifact, mirroring
      // `lyric run`.  Libraries (no `main`) are left untouched: colocation there
      // is unnecessary and must never run for a stdlib self-build (which has no
      // `main` and would otherwise be clobbered by the seed bundle).
      // `emitSingleFileOrProject` (D123) resolves manifest dependencies to
      // DLL paths when a nearby lyric.toml contributes any — colocate those
      // beside the output exactly like `buildProject` does, so a runnable
      // single-file program that now compiles against a workspace/path/NuGet
      // dependency can also actually load it at `dotnet exec` time.  Empty
      // lists (the common no-manifest case) make these calls no-ops.
      if Release.declaresEntryMain(source) {
        copyRuntimeDepsBeside(outPath, findCompiledLibDir())
        copyRestoredDepDlls(outPath, resolvedRestoredDlls)
        copyNugetAssembliesBeside(outPath, resolvedNugetPaths)
        copyNugetNativeAssetsBeside(outPath, resolvedNativePaths)
      }
    }
    case Jvm -> ()
    case Native -> ()
  }
  val elapsedMs = Time.totalMillis(Time.since(Time.now(), buildStart))
  Console.println("built " + outPath + " in " + Format.formatFixed(elapsedMs, 0) + "ms")
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Build command
// ─────────────────────────────────────────────────────────────────────────────
func cmdBuild(argv: in slice[String]): Int {
  var force = false
  var explicitOut: Option[String] = None
  var manifestArg: Option[String] = None
  var target: CompileTarget = Dotnet
  // `--target native` knobs (D-N-001): LLVM triple + clang -O level.
  var tripleArg = ""
  var optArg = ""

  // D045 build features.  Captured here for spec parity with the F#
  // bootstrap CLI; the self-hosted compiler will consume them once the
  // emitter ships (Phase 5+ stage 7).
  val cliFeatures: List[String] = newList()
  var noDefaultFeatures: Bool = false
  var allFeatures: Bool = false
  // docs/60 build defines: `--define K=V` (repeatable). Precedence-merged
  // with well-known defines inside `buildOneNativeWithFeatures`.
  val cliDefines: List[String] = newList()
  // docs/63 §4.1: the profile axis (`--debug`/`--release`) and the shape axis
  // (`--shape`, plus the `--aot`/`--standalone` sugar). Both are captured as
  // "did the user say it" here and resolved against the manifest below, so
  // CLI-over-manifest precedence is explicit rather than implied by a default.
  var sawDebugFlag: Bool = false
  var sawReleaseFlag: Bool = false
  var shapeArg: String = ""
  var sawAotFlag: Bool = false
  var sawStandaloneFlag: Bool = false
  var ridArg: Option[String] = None
  var noRestore: Bool = false
  var watch: Bool = false
  var releaseFromDll: Option[String] = None
  var packageVersionArg: Option[String] = None
  var extraRefsDir: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--force" {
      force = true
      i += 1
    } else if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: -o requires an argument")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --manifest requires an argument")
        return 1
      }
    } else if arg == "--features" {
      if i + 1 < argv.length {
        val raw = argv[i + 1]
        // Comma-separated, whitespace-trimmed; empty entries dropped.
        val pieces = Str.split(raw, ",")
        for piece in pieces {
          val trimmed = Str.trim(piece)
          if Str.length(trimmed) > 0 {
            cliFeatures.add(trimmed)
          }
        }
        i += 2
      } else {
        printErr("build: --features requires a comma-separated list")
        return 1
      }
    } else if arg == "--no-default-features" {
      noDefaultFeatures = true
      i += 1
    } else if arg == "--all-features" {
      allFeatures = true
      i += 1
    } else if arg == "--release" {
      sawReleaseFlag = true
      i += 1
    } else if arg == "--debug" {
      sawDebugFlag = true
      i += 1
    } else if arg == "--shape" {
      if i + 1 < argv.length {
        shapeArg = argv[i + 1]
        i += 2
      } else {
        printErr("build: --shape requires an argument (portable, standalone, or aot)")
        return 1
      }
    } else if arg == "--aot" {
      sawAotFlag = true
      i += 1
    } else if arg == "--standalone" {
      sawStandaloneFlag = true
      i += 1
    } else if arg == "--define" {
      if i + 1 < argv.length {
        val kv = argv[i + 1]
        match Str.indexOf(kv, "=") {
          case Some(eq) -> {
            val k = Str.substring(kv, 0, eq)
            if k.length == 0 {
              printErr("build: --define requires KEY=VALUE (empty key): " + kv)
              return 1
            }
            // Carry the raw "KEY=VALUE" string; decoded to a Define at the
            // MSIL bridge (keeps EmitRequest free of a cross-package field).
            cliDefines.add(kv)
          }
          case None -> {
            printErr("build: --define requires KEY=VALUE, got: " + kv)
            return 1
          }
        }
        i += 2
      } else {
        printErr("build: --define requires a KEY=VALUE argument")
        return 1
      }
    } else if arg == "--rid" {
      if i + 1 < argv.length {
        ridArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --rid requires an argument")
        return 1
      }
    } else if arg == "--no-restore" {
      noRestore = true
      i += 1
    } else if arg == "--watch" {
      watch = true
      i += 1
    } else if arg == "--release-from-dll" {
      if i + 1 < argv.length {
        releaseFromDll = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --release-from-dll requires an argument")
        return 1
      }
    } else if arg == "--extra-refs-dir" {
      if i + 1 < argv.length {
        extraRefsDir = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --extra-refs-dir requires an argument")
        return 1
      }
    } else if arg == "--package-version" {
      if i + 1 < argv.length {
        packageVersionArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("build: --package-version requires an argument")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          target = Jvm
        } else if t == "native" {
          target = Native
        } else {
          target = Dotnet
        }
        i += 2
      } else {
        printErr("build: --target requires an argument")
        return 1
      }
    } else if arg == "--triple" {
      if i + 1 < argv.length {
        tripleArg = argv[i + 1]
        i += 2
      } else {
        printErr("build: --triple requires an argument (an LLVM target triple, e.g. x86_64-unknown-linux-gnu)")
        return 1
      }
    } else if arg == "--opt" {
      if i + 1 < argv.length {
        optArg = argv[i + 1]
        i += 2
      } else {
        printErr("build: --opt requires an argument (0, 1, 2, 3, or s)")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }
  match packageVersionArg {
    case Some(v) -> match validatePackageVersionArg(v) {
      case Some(msg) -> {
        printErr("build: " + msg)
        return 1
      }
      case None -> ()
    }
    case None -> ()
  }
  // docs/63 §4: validate the profile/shape spellings before anything reads a
  // manifest, so a conflicting invocation fails the same way in project mode
  // and single-file mode.
  match profileFlagConflictError(sawDebugFlag, sawReleaseFlag) {
    case Some(msg) -> {
      printErr(msg)
      return 1
    }
    case None -> ()
  }
  // Validate the `--shape` VALUE before adjudicating conflicts: otherwise
  // `--aot --shape bogus` reports an F0041 conflict (because "bogus" != "aot")
  // instead of saying the value is not a shape at all.
  var shapeFromArg: Option[BuildShape] = None
  if shapeArg.length > 0 {
    val parsedShape = parseShapeName(shapeArg)
    match parsedShape {
      case Some(_) -> ()
      case None -> {
        printErr("build: --shape must be portable, standalone, or aot, got \"" + shapeArg + "\"")
        return 1
      }
    }
    shapeFromArg = parsedShape
  }
  match shapeFlagConflictError(shapeArg, sawAotFlag, sawStandaloneFlag) {
    case Some(msg) -> {
      printErr(msg)
      return 1
    }
    case None -> ()
  }
  // `--shape <v>` wins its own spelling; `--aot`/`--standalone` are sugar that
  // lowers to it (the conflict check above guarantees they agree).
  var cliShape: Option[BuildShape] = None
  if shapeArg.length > 0 {
    cliShape = shapeFromArg
  } else if sawAotFlag {
    cliShape = Some(value = SAot)
  } else if sawStandaloneFlag {
    cliShape = Some(value = SStandalone)
  }
  val cliShapeNamed = match cliShape { case Some(_) -> true; case None -> false }
  val cliProfile: Option[BuildProfile] = if sawReleaseFlag {
    Some(value = ProfRelease)
  } else if sawDebugFlag {
    Some(value = ProfDebug)
  } else {
    None
  }
  // `--target native`'s "AOT by construction" default (docs/63 §5.1) is no
  // longer pre-applied here (#6268): `resolveBuildAxes`/
  // `resolveBuildAxesFromManifest` below apply it themselves, AFTER
  // consulting the manifest's `shapeDeclared` bit, so a manifest-declared
  // non-`aot` shape on native reaches `F0043` instead of being silently
  // overridden by a bare CLI default computed before the manifest was ever
  // read. `cliShape` (raw, un-defaulted) is passed straight through.
  // `--release-from-dll` links a pre-built managed artifact; no source is
  // compiled, so the profile axis has nothing to apply to, and the shape is
  // `aot` by definition. Naming either is a request we cannot honour — reject
  // it rather than silently ignore it (the same no-silent-drop contract the
  // define gates enforce). `--shape aot` is accepted as a consistent no-op.
  match releaseFromDll {
    case Some(_) -> {
      val badShape = match cliShape { case Some(SAot) -> false; case Some(_) -> true; case None -> false }
      if badShape {
        // Name the RESOLVED shape, not the raw `--shape` string: the
        // `--aot`/`--standalone` sugar never populates `shapeArg`, so using it
        // here printed a blank name (#6281).
        val namedShape = match cliShape { case Some(sh) -> shapeName(sh); case None -> "" }
        printErr(
          "build: --release-from-dll always produces a native binary; --shape " + namedShape +
            " cannot be honoured (drop the flag, or pass --shape aot)"
        )
        return 1
      }
      if sawReleaseFlag or sawDebugFlag {
        printErr("build: --release-from-dll compiles no source, so --debug/--release has nothing to apply to; drop it")
        return 1
      }
    }
    case None -> ()
  }
  match releaseFromDll {
    case Some(dll) -> {
      if positional.count > 0 {
        printErr(releaseFromDllIgnoredArgsWarning(positional))
      }
      if not File.fileExists(dll) {
        printErr("build: --release-from-dll: file not found: " + dll)
        return 1
      }
      match target {
        case Native -> {
          printErr("build: --release-from-dll does not apply to --target native")
          return 1
        }
        case _ -> ()
      }
      val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case _ -> Release.DotnetAot }
      // On `--target jvm` the prebuilt input is a bundled JAR and the extra
      // references are classpath JARs, not managed DLLs.
      val refsExt = outputExt(target, "lib")
      val extraRefs: List[String] = match extraRefsDir {
        case Some(refsDir) -> {
          match File.listFiles(refsDir) {
            case Ok(files) -> filterExtraRefs(files, Path.basename(dll), refsExt)
            case Err(e) -> {
              printErr("build: --extra-refs-dir: " + IOError.message(e))
              return 1
            }
          }
        }
        case None -> newList()
      }
      val absDll = if Path.isAbsolute(dll) { dll } else { Path.join(Environment.currentDirectory(), dll) }
      val outNative = match explicitOut {
        case Some(o) -> o
        case None -> {
          val base = Path.basename(absDll)
          Path.join(Path.dirname(absDll), stemOf(base, 4))  // strip ".dll"
        }
      }
      return Release.buildRelease(releaseTarget, absDll, extraRefs, ridArg, outNative)
    }
    case None -> {
      match extraRefsDir {
        case Some(_) -> {
          printErr("build: --extra-refs-dir requires --release-from-dll")
          return 1
        }
        case None -> ()
      }
    }
  }
  // `--no-restore` only affects project-mode auto-restore; warn rather than
  // silently ignore it on a single-file build (#2048).
  if noRestore and positional.count > 0 {
    printErr("build: warning: --no-restore has no effect without a project manifest")
  }
  // docs/60 build defines: all three backends can now consume a `--define` —
  // MSIL/JVM on single-file and project builds (#5852), and native on both
  // single-file builds (#5977 — list-literal lowering + module-level `val`
  // inlining make `@build_const`/`Std.BuildInfo` work) and project builds
  // (#6818 — `buildProjectFromManifest`'s native branch threads
  // `projReq.defines` through `Emitter.emitNativeProject`).
  //
  // The `--define` gate itself now runs *after* the shape axis is resolved
  // (docs/63 §5.3), inside each branch below — it keys off the packaging shape,
  // which can come from the manifest, not off the `--release` flag.
  val consumableTarget = match target { case Dotnet -> true; case Jvm -> true; case Native -> true }
  // Project-mode: `lyric build --manifest lyric.toml`, or no positional source
  // at all (discover the nearest lyric.toml by walking up from the cwd).
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("build: no source file given and no lyric.toml found in this directory or any parent")
        printUsage()
        return 1
      }
    }
    // Parse `lyric.toml` once here and thread the value through the axis
    // resolution / defines-gate / plain-build calls below, instead of each of
    // those helpers re-reading and re-parsing the same file (#6193 — this
    // branch used to parse the manifest 4-5x per build). A read/parse
    // failure degrades to `None`, matching the old per-helper default-on-
    // failure contract (`readBuildSection`'s doc comment); the real
    // diagnostic still surfaces below, from whichever build call ends up
    // re-parsing it for real.
    val mfText = match File.readText(mfPath) { case Ok(t) -> t; case Err(_) -> "" }
    val manifestValOpt: Option[Manifest] = match Mf.parseManifest(mfText, mfPath) {
      case Ok(m) -> Some(value = m)
      case Err(_) -> None
    }
    // docs/63: resolve both axes against this manifest. A `[build] shape = "aot"`
    // routes into the AOT-packaging pipeline exactly as an explicit `--aot` does
    // — the manifest is a default for the same axis, not a separate mechanism
    // (which is what `kind = "aot"` used to be).
    val axes = match resolveBuildAxesFromManifest(cliShape, cliProfile, manifestValOpt, target) {
      case Ok(a) -> a
      case Err(msg) -> {
        printErr(msg)
        return 1
      }
    }
    // Same profile-aware native `-O` default the single-file branch applies
    // below (`resolveNativeOptDefault`, #6263) — a project-mode `--target
    // native` build under the default `--debug` profile used to fall through
    // to `linkAndEmitNative`'s old hardcoded `-O2`, inconsistent with the
    // single-file path this same PR fixes (review finding on #6899). A no-op
    // on Dotnet/Jvm or when `--opt`/`[native] opt_level` already supply one.
    val effOptArgProj = resolveNativeOptDefault(optArg, Some(value = mfPath), target, axes.profile)
    // docs/60 §3.1: manifest `[build.define]` is threaded through `buildProject`.
    // Reject up front (no silent drop, #6139) on any shape that cannot consume
    // it. `--watch` is fine — `buildProject` reapplies the manifest defines on
    // every rebuild. `manifestDefineGateError` is a pure predicate (unit-tested,
    // #6188) so this reject matrix can't silently regress.
    val mfHasDefines = match manifestValOpt { case Some(mv) -> manifestDeclaresBuildDefinesValue(mv); case None -> false }
    match manifestDefineGateError(mfHasDefines, axes.shape, target, mfPath) {
      case Some(msg) -> {
        printErr(msg)
        return 1
      }
      case None -> ()
    }
    // Only name the manifest when the shape actually came from it (#6277).
    val shapeSrc = if cliShapeNamed { "" } else { mfPath }
    match defineBuildGateError(cliDefines.count > 0, consumableTarget, watch, axes.shape, target, shapeSrc) {
      case Some(msg) -> {
        printErr(msg)
        return 1
      }
      case None -> ()
    }
    // `--watch` is an inner-loop tool; the packaging shapes are far too slow to
    // rebuild on every keystroke (#4203, re-scoped from `--release` per
    // docs/63 §5.3).
    if watch and usesPackagingPipeline(axes.shape, target) {
      printErr(
        "build: --watch is not supported with --shape " + shapeName(axes.shape) +
          " (the packaging build is far too slow to rerun on every edit)"
      )
      return 1
    }
    if usesPackagingPipeline(axes.shape, target) {
      return buildReleaseProject(
        mfPath,
        explicitOut,
        target,
        ridArg,
        cliFeatures,
        noDefaultFeatures,
        allFeatures,
        noRestore,
        packageVersionArg,
        axes.profile
      )
    }
    if shouldPrintReleaseNote(sawReleaseFlag, cliShapeNamed, axes.shape) {
      printErr(releaseProfileOnlyNote())
    }
    if watch {
      return watchLoop(
        projectWatchFiles(mfPath),
        BuildProj(
          mfPath = mfPath,
          outArg = explicitOut,
          target = target,
          feats = cliFeatures,
          noDef = noDefaultFeatures,
          allF = allFeatures,
          noRestore = noRestore,
          pkgVer = packageVersionArg,
          profile = axes.profile,
          nativeTriple = tripleArg,
          nativeOpt = effOptArgProj
        )
      )
    }
    // `--rid` only applies to the packaging shapes (Native AOT / self-contained).
    // Reached only when the shape is NOT one — the branch above returns for
    // those — so `--rid` is genuinely unused here (#2022, re-scoped from
    // `--release` per docs/63 §5.3).
    match ridArg {
      case Some(_) -> printErr(ridNoEffectWarning(target))
      case None -> ()
    }
    // `--triple`/`--opt` CLI flags thread into a `--target native` project
    // build via `buildProjectFromManifest`'s `nativeTriple`/`nativeOpt`
    // params, overriding the manifest's own `[native]` table exactly like
    // the single-file path (#6815 item 2). They're harmless no-ops on
    // Dotnet/Jvm — `buildProjectFromManifest` only reads them when
    // `target == Native`.
    // Reuse the manifest already parsed above when it parsed cleanly (the
    // common case); fall back to `buildProject`'s own re-parse otherwise so a
    // genuinely malformed manifest still gets a real diagnostic instead of a
    // silently-defaulted build (#6193).
    match manifestValOpt {
      case Some(manifestVal) -> {
        return buildProjectFromManifest(
          mfPath,
          mfText,
          manifestVal,
          explicitOut,
          target,
          cliFeatures,
          noDefaultFeatures,
          allFeatures,
          noRestore,
          packageVersionArg,
          None,
          withProfileDefine(cliDefines, axes.profile),
          tripleArg,
          effOptArgProj
        )
      }
      case None -> {
        return buildProjectWithNativeFlags(
          mfPath,
          explicitOut,
          target,
          cliFeatures,
          noDefaultFeatures,
          allFeatures,
          noRestore,
          packageVersionArg,
          None,
          withProfileDefine(cliDefines, axes.profile),
          tripleArg,
          effOptArgProj
        )
      }
    }
  }

  val sourcePath = positional[0]
  if not File.fileExists(sourcePath) {
    printErr("build: source file not found: " + sourcePath)
    return 1
  }

  // docs/63: resolve both axes. A single-file build honours `[build] shape` /
  // `[build] profile` from an explicitly-passed `--manifest` only; there is no
  // manifest discovery on this path, matching `readBuildKindFromManifest`.
  val axes = match resolveBuildAxes(cliShape, cliProfile, manifestArg, target) {
    case Ok(a) -> a
    case Err(msg) -> {
      printErr(msg)
      return 1
    }
  }

  // Same contract as the project branch (#6277/#6278): name the manifest only
  // when the shape actually came from it. A single-file build reads
  // `[build] shape` from an explicitly-passed `--manifest`, so that path can be
  // manifest-sourced too.
  val sfShapeSrc = if cliShapeNamed { "" } else { match manifestArg { case Some(mp) -> mp; case None -> "" } }
  match defineBuildGateError(cliDefines.count > 0, consumableTarget, watch, axes.shape, target, sfShapeSrc) {
    case Some(msg) -> {
      printErr(msg)
      return 1
    }
    case None -> ()
  }

  if watch and usesPackagingPipeline(axes.shape, target) {
    printErr(
      "build: --watch is not supported with --shape " + shapeName(axes.shape) +
        " (the packaging build is far too slow to rerun on every edit)"
    )
    return 1
  }

  if shouldPrintReleaseNote(sawReleaseFlag, cliShapeNamed, axes.shape) {
    printErr(releaseProfileOnlyNote())
  }

  // Routing uses the same predicate as the gates (#6271): `--target native`
  // resolves to `SAot` but produces its binary through the LLVM pipeline, not
  // through `Lyric.Release`, so only a genuine packaging pipeline takes the hop.
  if usesPackagingPipeline(axes.shape, target) {
    return buildReleaseSingle(sourcePath, explicitOut, target, ridArg, manifestArg, axes.profile)
  }

  // `--rid` only applies to the packaging shapes; warn here so the flag isn't
  // silently dropped, mirroring the project-mode warning above (#4206).
  //
  // Reached only when the shape is NOT a packaging pipeline — the branch above
  // returns for those — so `--rid` is genuinely unused here.
  match ridArg {
    case Some(_) -> printErr(ridNoEffectWarning(target))
    case None -> ()
  }

  val outPath = match explicitOut {
    case Some(o) -> o
    case None -> {
      val dir = Path.dirname(sourcePath)
      val stem = stemOf(Path.basename(sourcePath), 2)  // strip ".l"
      val buildKind = readBuildKindFromManifest(manifestArg)
      val ext = outputExt(target, buildKind)
      Path.join(dir, stem + ext)
    }
  }

  // #6263: default the native `-O` level from the resolved profile axis when
  // neither `--opt` nor the manifest supply one — see `resolveNativeOptDefault`'s
  // doc comment. A no-op on Dotnet/Jvm (returns `optArg` unchanged).
  val effOptArg = resolveNativeOptDefault(optArg, manifestArg, target, axes.profile)

  if watch {
    val files: List[String] = newList()
    files.add(sourcePath)
    return watchLoop(
      files,
      BuildFile(
        sourcePath = sourcePath,
        outArg = outPath,
        target = target,
        manifest = manifestArg,
        nativeTriple = tripleArg,
        nativeOpt = effOptArg,
        feats = cliFeatures,
        noDef = noDefaultFeatures,
        allF = allFeatures,
        profile = axes.profile
      )
    )
  }

  buildOneNativeWithFeatures(
    sourcePath,
    outPath,
    target,
    manifestArg,
    tripleArg,
    effOptArg,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    withProfileDefine(cliDefines, axes.profile)
  )
}

// Append the well-known `build_profile` define (docs/60 §3.3) for the resolved
// profile, so `@build_const("build_profile")` and `Std.BuildInfo.profile` report
// the profile axis rather than "did this build go through Lyric.Release".
//
// Before docs/63 band B0 the `release` value was injected only by the
// AOT-packaging paths, so `--release --shape portable` — which was not
// expressible — could not report it. Only `release` is appended: `debug` is
// already the fallback `pipeParseAndErase` injects, and appending it here would
// override an explicit `--define build_profile=…` that the user passed on
// purpose (`withWellKnownProfile` skips its fallback when the key is present).
pub func withProfileDefine(defines: in List[String], profile: in BuildProfile): List[String] {
  match profile {
    case ProfDebug -> defines
    case ProfRelease -> {
      val merged: List[String] = newList()
      // The profile define goes first so an explicit `--define build_profile=X`
      // still wins under the last-wins merge.
      merged.add("build_profile=release")
      var i = 0
      while i < defines.count {
        merged.add(defines[i])
        i += 1
      }
      merged
    }
  }
}

// Single-file `lyric build --release <source.l>`: compile to a staging DLL,
// then produce a self-contained native binary via Lyric.Release.  The default
// output is the source stem with no extension (an executable), next to the
// source unless `-o` overrides it.
// The compiler-injected well-known `build_profile=release` define for a
// staging compile (docs/60 §3.3), as the `"KEY=VALUE"` form the build path
// threads. A normal build gets the `"debug"` fallback injected in
// `pipeParseAndErase`; the packaging paths thread the RESOLVED profile so
// last-wins reports it for `@build_const("build_profile")` /
// `Std.BuildInfo.profile`.
//
// This takes the profile as a parameter rather than hardcoding `release`
// (#6267): shape and profile are independent axes, so `--debug --aot` — the
// debuggable-AOT combination band B0 exists to unlock — must report `debug`,
// not `release`.
func profileOnlyDefines(profile: in BuildProfile): List[String] {
  val empty: List[String] = newList()
  withProfileDefine(empty, profile)
}

func buildReleaseSingle(
  sourcePath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  ridArg: in Option[String],
  manifestArg: in Option[String],
  profile: in BuildProfile,
): Int {
  // Native is unreachable here because `usesPackagingPipeline` is false for
  // every native shape, so cmdBuild never routes a native build into this
  // function. It is NOT because the CLI rejects `--release --target native`:
  // that combination is valid and simply sets the profile (native is AOT by
  // construction). Do not re-add a rejection on that basis.
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case _ -> Release.DotnetAot }

  // Reject an unbuildable JVM release request (bad/cross-target `--rid`,
  // unsupported host) BEFORE the managed build, so a bad flag costs nothing
  // rather than a full compile.
  match releaseTarget {
    case JvmNativeImage -> {
      match Release.jvmReleasePreflightError(ridArg, Environment.runtimeIdentifier()) {
        case Some(msg) -> {
          printErr("release: " + msg)
          return 1
        }
        case None -> ()
      }
    }
    case DotnetAot -> ()
  }

  val srcText = match File.readText(sourcePath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val pkgName = Release.packageNameOf(srcText)
  // Validate the entry package up front — before the (slow) managed build —
  // so a source with no `package` declaration fails fast (#2021).
  if pkgName == "" {
    printErr("build: --release: no `package` declaration found in " + sourcePath)
    return 1
  }

  val srcDir = Path.dirname(sourcePath)
  val stem = stemOf(Path.basename(sourcePath), 2)  // strip ".l"
  // Name the staging assembly after the PACKAGE, not the source filename, for
  // consistency with the emitter's assembly-naming convention and with
  // buildReleaseProject's staging DLL (named from proj.outputAssembly /
  // proj.name).  `ilc` roots the native build from the PE's `EntryPointToken`
  // (set by the MSIL emitter), not from the assembly's file name — there is
  // no C# trampoline in this pipeline (see `Lyric.Release`).  The native
  // output keeps the file-stem name (what the user expects from `foo.l`).
  //
  // The JVM arm stages a bundled `.jar` instead: `native-image` takes the
  // entry point from the JAR manifest's `Main-Class`, which the JVM backend
  // writes from the same package.
  val stagingArtifact = Path.join(Path.join(srcDir, ".lyric-release"), pkgName + outputExt(target, "lib"))
  // Inject `build_profile=release` into the staging compile (docs/60 §3.3) —
  // `buildOne`/`buildOneNative` pass no defines, so use the feature-aware entry
  // point directly with the release profile define.
  val buildExit = buildOneNativeWithFeatures(
    sourcePath,
    stagingArtifact,
    target,
    manifestArg,
    "",
    "",
    newList(),
    false,
    false,
    profileOnlyDefines(profile)
  )
  if buildExit != 0 {
    return buildExit
  }

  val outNative = match explicitOut { case Some(o) -> o; case None -> Path.join(srcDir, stem) }
  // No explicit extra references here on either target.  On JVM that is not a
  // Maven gap: `emitSingleFileOrProject` runs `injectMavenClasspathForJvm`
  // before emitting, so the staging JAR's manifest already carries a
  // `Class-Path:` naming every restored Maven jar — and `native-image -jar`
  // honours manifest `Class-Path` (verified against a two-JAR fixture:
  // classes from the referenced jar resolve into the image with no `-cp` at
  // all).  `buildReleaseProject` passes `-cp` as well only because it has
  // `module-path.txt` to hand, not because the manifest route is insufficient.
  Release.buildRelease(releaseTarget, stagingArtifact, newList(), ridArg, outNative)
}

// Project-mode `lyric build --release` (no explicit source file): compile every
// package in [project.packages] into a staging bundle DLL, then produce a
// self-contained native binary via Lyric.Release.  The entry package — the one
// whose source declares `func main()` — is validated before the managed build so
// a project with no entry fails fast without a slow DLL build.
func buildReleaseProject(
  mfPath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  ridArg: in Option[String],
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
  packageVersionOverride: in Option[String],
  profile: in BuildProfile,
): Int {
  // Native is unreachable here because `usesPackagingPipeline` is false for
  // every native shape, so cmdBuild never routes a native build into this
  // function. It is NOT because the CLI rejects `--release --target native`:
  // that combination is valid and simply sets the profile (native is AOT by
  // construction). Do not re-add a rejection on that basis.
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case _ -> Release.DotnetAot }

  // Reject an unbuildable JVM release request (bad/cross-target `--rid`,
  // unsupported host) BEFORE the managed build, so a bad flag costs nothing
  // rather than a full compile.
  match releaseTarget {
    case JvmNativeImage -> {
      match Release.jvmReleasePreflightError(ridArg, Environment.runtimeIdentifier()) {
        case Some(msg) -> {
          printErr("release: " + msg)
          return 1
        }
        case None -> ()
      }
    }
    case DotnetAot -> ()
  }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("build: " + ManifestError.message(e))
      return 1
    }
  }
  val proj = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("build: " + mfPath + " has no [project] section")
      return 1
    }
  }
  if proj.packages.count == 0 {
    printErr("build: " + mfPath + " [project.packages] is empty")
    return 1
  }

  val mfDir = Path.dirname(mfPath)

  // Scan each package's sources to find the entry package — the one declaring
  // `func main()`.  Every entry candidate is collected before reporting so a
  // conflict lists all offending packages at once instead of one pair per
  // rebuild (#3219). A `test_only = true` entry (#6579) is skipped here too:
  // it never reaches the actual release bundle (`buildProjectFromManifest`'s
  // own `pkgEntry.testOnly` skip below it in `buildProject`), so it cannot be
  // the real entry package regardless of what it declares.
  val entryPkgNames: List[String] = newList()
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    if pkgEntry.testOnly {
      pi += 1
      continue
    }
    var combined = ""
    if pkgEntry.paths.count > 0 {
      // Explicit file list (TOML array form): read each file in order.
      var fi = 0
      while fi < pkgEntry.paths.count {
        val absFile = if Path.isAbsolute(pkgEntry.paths[fi]) {
          pkgEntry.paths[fi]
        } else {
          Path.join(mfDir, pkgEntry.paths[fi])
        }
        match File.readText(absFile) {
          case Ok(raw) -> {
            combined = combined + "\n" + raw
          }
          case Err(e) -> {
            printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
            return 1
          }
        }
        fi += 1
      }
    } else {
      val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
      if File.fileExists(abs) {
        match File.readText(abs) {
          case Ok(raw) -> {
            combined = raw
          }
          case Err(e) -> {
            printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
            return 1
          }
        }
      } else if File.dirExists(abs) {
        val allFiles = match File.listFilesRecursive(abs) {
          case Ok(fs) -> fs
          case Err(e) -> {
            printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
            return 1
          }
        }
        for f in allFiles.toArray() {
          if Str.endsWith(f, ".l") {
            match File.readText(f) {
              case Ok(raw) -> {
                combined = combined + "\n" + raw
              }
              case Err(e) -> {
                printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
                return 1
              }
            }
          }
        }
      } else {
        printErr("build: package '" + pkgEntry.name + "': path not found: " + abs)
        return 1
      }
    }
    if Release.declaresEntryMain(combined) {
      entryPkgNames.add(pkgEntry.name)
    }
    pi += 1
  }

  if entryPkgNames.count > 1 {
    var names = "'" + entryPkgNames[0] + "'"
    var ni = 1
    while ni < entryPkgNames.count {
      names = names + ", '" + entryPkgNames[ni] + "'"
      ni += 1
    }
    printErr(
      "build: --release: multiple packages declare `func main()`: " + names + " — exactly one entry package is required"
    )
    return 1
  }
  if entryPkgNames.count == 0 {
    printErr(
      "build: --release: no package in this project declares `func main()` (checked " + toString(proj.packages.count) +
        " package(s))"
    )
    return 1
  }
  // Build to a staging directory so the production `bin/` output is untouched
  // by the intermediate managed artifact (a `.dll` for .NET AOT, a bundled
  // `.jar` for GraalVM native-image).
  val artifactBase = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + outputExt(target, "lib") }
  val stagingDir = Path.join(mfDir, ".lyric-release")
  val stagingArtifact = Path.join(stagingDir, artifactBase)

  // Resolve every dependency (workspace, path, and NuGet-as-Lyric-package)
  // ONCE, up front: `buildProject` needs it to build the staging DLL below,
  // and the AOT linker's extra-references list (collected after) needs the
  // exact same resolution again — `resolveManifestDependencies` transitively
  // rebuilds every workspace dep, so running it twice per `--release` build
  // doubled that work (checkDllIsStale + resolveAllNugetAssets per dep,
  // warnIfNugetUnresolved printing up to twice) for no behavioral difference
  // (#5786).  Passed into `buildProject` via `preResolvedDeps` instead of
  // letting it re-resolve internally.
  val resolved = resolveManifestDependencies(manifest, mfPath, target, cliFeatures, noDefaultFeatures)
  if resolved.hadWorkspaceError {
    return 1
  }

  // The staging DLL is a --release build: inject the well-known
  // `build_profile=release` define (docs/60 §3.3) so the release binary's
  // `@build_const("build_profile")` and `Std.BuildInfo.profile` report "release"
  // instead of the "debug" fallback `pipeParseAndErase` injects for normal
  // builds. `[build.define]`/user `--define` stay gated on --release (cmdBuild
  // rejects them before this point), so this compiler-injected define is the
  // only one the release staging compile carries.
  val buildExit = buildProject(
    mfPath,
    Some(value = stagingArtifact),
    target,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    noRestore,
    packageVersionOverride,
    Some(value = resolved),
    profileOnlyDefines(profile)
  )
  if buildExit != 0 {
    return buildExit
  }

  // Collect every managed reference the AOT linker needs but the staging DLL
  // above doesn't embed: workspace deps, local `path = "..."` deps (and
  // their transitive deps), and `[nuget]`-resolved assets — both restored
  // Lyric packages (e.g. `Lyric.Web`, `Lyric.Docker`) and genuine
  // third-party .NET assemblies (e.g. `Microsoft.Data.Sqlite`).  Reuses the
  // `resolved` resolution computed above (and threaded through
  // `buildProject` via `preResolvedDeps`) instead of a bespoke
  // `[dependencies]`-only walk that silently dropped every `[nuget]` entry,
  // which crashed ILC at runtime with `FileNotFoundException` for any
  // NuGet-restored assembly the program actually calls into (#5782).
  //
  // On the JVM target none of the above applies — do not read this as "the
  // JVM arm handles everything the .NET arm does":
  //
  //   - Same-manifest `[project.packages]` siblings, `[dependencies]`
  //     path/workspace deps (#6264), and the transitive `Std.*` closure all
  //     genuinely ARE compiled into the bundled JAR: `emitProjectJvmInProcess`
  //     merges the project's own packages, and `buildProjectFromManifest`
  //     (called above via `buildProject` for the staging build) additionally
  //     appends every collected `depTemplateSrcs` package to that same bundle
  //     for `target = Jvm` — see its comment for the full rationale. So the
  //     staging JAR built above already embeds a path/workspace dep's code;
  //     it needs no external reference for that.
  //
  // The only external classpath entries are the restored `[maven]` jars, which
  // `buildProject` has just written beside the staging JAR as
  // `module-path.txt`.
  val extraRefs: List[String] = match target {
    case Jvm -> stagedMavenClasspath(stagingDir)
    case _ -> {
      val refs: List[String] = newList()
      var rdi = 0
      while rdi < resolved.restoredDlls.count {
        val entry = resolved.restoredDlls[rdi]
        val tabPos = Str.indexOfRaw(entry, "\t")
        val dllPath = if tabPos >= 0 { entry.substring(tabPos + 1, entry.length - tabPos - 1) } else { entry }
        refs.add(dllPath)
        rdi += 1
      }
      var npi = 0
      while npi < resolved.nugetThirdPartyPaths.count {
        refs.add(resolved.nugetThirdPartyPaths[npi])
        npi += 1
      }
      refs
    }
  }

  val stem = stemOf(artifactBase, 4)
  val outNative = match explicitOut { case Some(o) -> o; case None -> Path.join(mfDir, stem) }
  val releaseExit = Release.buildRelease(releaseTarget, stagingArtifact, extraRefs, ridArg, outNative)
  // Stage restored NuGet native runtime assets (e.g. SQLite's libe_sqlite3)
  // beside the native binary, same as the plain (non-release) path does at
  // the `Dotnet` build-project call site — the release path never called
  // this, so a native-AOT release binary silently missed its P/Invoke
  // runtime assets at startup (#5783). No-op on JVM: native assets are
  // resolved from `[nuget]`, a .NET-only concept.
  match target {
    case Jvm -> ()
    case _ -> {
      if releaseExit == 0 {
        copyNugetNativeAssetsBeside(outNative, resolved.nativeAssetPaths)
      }
    }
  }
  releaseExit
}

// Read the restored Maven classpath a JVM `buildProject` wrote beside its
// output JAR (`module-path.txt`, colon-separated, always written — empty when
// the manifest declares no `[maven]` deps).  Returns an empty list when the
// file is absent or blank so a Maven-free project simply passes no `-cp`.
//
// `pub` so `cli_build_self_test.l` can drive the parse/trim/filter directly
// against a temp directory, like the other release helpers this path uses.
pub func stagedMavenClasspath(stagingDir: in String): List[String] {
  val entries: List[String] = newList()
  val mpPath = Path.join(stagingDir, "module-path.txt")
  val text = match File.readText(mpPath) { case Ok(t) -> Str.trim(t); case Err(_) -> "" }
  if text == "" {
    return entries
  }
  val parts = Str.split(text, ":")
  var i = 0
  while i < parts.length {
    val p = Str.trim(parts[i])
    if p != "" {
      entries.add(p)
    }
    i += 1
  }
  entries
}

// Deterministic ascending sort of a file-path list.
//
// Uses a monomorphic selection sort over `List[String]` rather than
// `Std.Sort.sortStrings`: `cli.l` is compiled by the F# stage-1 bootstrap
// during stage-1, which bundles `Std.Sort` inline and produces broken code for
// its typed-lambda generics — the bundled `sortStrings` crashes at runtime.
// This workaround can be retired once stage-2 self-hosting lands (cli.l
// compiled exclusively by the self-hosted compiler).  Tracking: #2592 slice 4.
func sortFileList(xs: in List[String]): List[String] {
  val remaining: List[String] = newList()
  var c = 0
  while c < xs.count {
    remaining.add(xs[c])
    c = c + 1
  }
  val sorted: List[String] = newList()
  while remaining.count > 0 {
    var bestIdx = 0
    var k = 1
    while k < remaining.count {
      if remaining[k] < remaining[bestIdx] {
        bestIdx = k
      }
      k = k + 1
    }
    sorted.add(remaining[bestIdx])
    remaining.removeAt(bestIdx)
  }
  sorted
}

/// Sources plus their on-disk paths, parallel by index, as read by
/// `readProjectPackageSources` (docs/63 §9.7).
pub record PkgSourceRead {
  sources: List[String]
  paths: List[String]
}

// Read one [project.packages] entry's source texts (single .l file, explicit
// TOML-array file list, or a directory of .l files collected recursively in
// sorted order), running the custom-generator pre-processor on each file.
// Returns None after printing package-labelled errors when anything fails to
// read or preprocess.  Shared by `buildProject` and
// `emitSingleFileOrProject`'s own-package inclusion (#5571).  The returned
// `paths` are parallel to `sources` by index — the real on-disk file each
// entry was read from, so a single-file package (`sources.count == 1`, the
// common case per docs/63 §9.7) keeps a real path for diagnostics / JVM
// `SourceFile` attribution all the way to the backends.
func readProjectPackageSources(pkgEntry: in Mf.PackageEntry, mfDir: in String, mfPath: in String): Option[PkgSourceRead] {
  val pkgSources: List[String] = newList()
  val pkgPaths: List[String] = newList()
  var hadFatal = false
  if pkgEntry.paths.count > 0 {
    // Explicit file list (TOML array form): read each named file in order.
    var fi = 0
    while fi < pkgEntry.paths.count {
      val absFile = if Path.isAbsolute(pkgEntry.paths[fi]) {
        pkgEntry.paths[fi]
      } else {
        Path.join(mfDir, pkgEntry.paths[fi])
      }
      match File.readText(absFile) {
        case Ok(raw) -> {
          match Generator.preprocess(raw, mfPath, absFile) {
            case Ok(t) -> {
              pkgSources.add(t)
              pkgPaths.add(absFile)
            }
            case Err(e) -> {
              printErr("build: package '" + pkgEntry.name + "': generator error in " + absFile + ": " + e)
              hadFatal = true
            }
          }
        }
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
      fi += 1
    }
  } else {
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    if File.fileExists(abs) {
      // Single .l file: read it directly, then run custom generators.
      match File.readText(abs) {
        case Ok(raw) -> {
          match Generator.preprocess(raw, mfPath, abs) {
            case Ok(t) -> {
              pkgSources.add(t)
              pkgPaths.add(abs)
            }
            case Err(e) -> {
              printErr("build: package '" + pkgEntry.name + "': generator error in " + abs + ": " + e)
              hadFatal = true
            }
          }
        }
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
    } else if File.dirExists(abs) {
      // Directory: collect all .l files recursively, sorted for determinism.
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs) -> fs
        case Err(e) -> {
          printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
          newList()
        }
      }
      val lFiles: List[String] = newList()
      for f in allFiles.toArray() {
        if Str.endsWith(f, ".l") {
          lFiles.add(f)
        }
      }
      if lFiles.count == 0 {
        printErr("build: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        val sorted = sortFileList(lFiles)
        for f in sorted {
          match File.readText(f) {
            case Ok(raw) -> {
              match Generator.preprocess(raw, mfPath, f) {
                case Ok(t) -> {
                  pkgSources.add(t)
                  pkgPaths.add(f)
                }
                case Err(e) -> {
                  printErr("build: package '" + pkgEntry.name + "': generator error in " + f + ": " + e)
                  hadFatal = true
                }
              }
            }
            case Err(e) -> {
              printErr("build: package '" + pkgEntry.name + "': " + IOError.message(e))
              hadFatal = true
            }
          }
        }
      }
    } else {
      printErr("build: package '" + pkgEntry.name + "': path not found: " + abs)
      hadFatal = true
    }
  }
  if hadFatal {
    val noSources: Option[PkgSourceRead] = None
    return noSources
  }
  Some(value = PkgSourceRead(sources = pkgSources, paths = pkgPaths))
}

// Project-mode build: reads [project.packages] from lyric.toml and
// bundles every package's .l files into a single DLL.
// `preResolvedDeps`: when the caller already ran `resolveManifestDependencies`
// against this exact manifest/target/feature-set (e.g. `buildReleaseProject`,
// which needs the same resolution again afterward for the AOT linker's
// extra-references list, #5786), pass it here instead of letting
// `buildProject` resolve (and, transitively, rebuild every workspace dep)
// a second time. `None` re-resolves as before — every other caller.
// `pub` so `cli_build_self_test.l` can drive the `preResolvedDeps` seam
// directly, proving it is actually honored rather than silently re-resolved
// (#5819's regression guard for the #5786 double-resolution fix).
pub func buildProject(
  mfPath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
  packageVersionOverride: in Option[String],
  preResolvedDeps: in Option[ResolvedManifestDeps],
  cliDefines: in List[String],
): Int {
  buildProjectWithNativeFlags(
    mfPath,
    explicitOut,
    target,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    noRestore,
    packageVersionOverride,
    preResolvedDeps,
    cliDefines,
    "",
    ""
  )
}

// Same as `buildProject`, but threads `--triple`/`--opt` CLI overrides into a
// `--target native` project build (#6815 item 2). `buildProject` itself stays
// the zero-native-flags entry point so its ~20 existing (non-native-flag)
// call sites are unaffected.
pub func buildProjectWithNativeFlags(
  mfPath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
  packageVersionOverride: in Option[String],
  preResolvedDeps: in Option[ResolvedManifestDeps],
  cliDefines: in List[String],
  nativeTriple: in String,
  nativeOpt: in String,
): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("build: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("build: " + ManifestError.message(e))
      return 1
    }
  }
  buildProjectFromManifest(
    mfPath,
    mfText,
    manifest,
    explicitOut,
    target,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    noRestore,
    packageVersionOverride,
    preResolvedDeps,
    cliDefines,
    nativeTriple,
    nativeOpt
  )
}

// Same as `buildProject`, but takes an already-read/parsed manifest instead
// of re-reading and re-parsing `mfPath` from disk. `cmdBuild`'s project-mode
// branch parses `lyric.toml` once up front (for the shape/profile axes and
// the build-defines gate) and threads that single parse all the way through
// via this entry point, instead of `buildProject`'s own redundant re-parse
// — the manifest was being parsed 4-5x per project build before (#6193).
pub func buildProjectFromManifest(
  mfPath: in String,
  mfText: in String,
  manifest: in Manifest,
  explicitOut: in Option[String],
  target: in CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
  packageVersionOverride: in Option[String],
  preResolvedDeps: in Option[ResolvedManifestDeps],
  cliDefines: in List[String],
  nativeTriple: in String,
  nativeOpt: in String,
): Int {
  val buildStart = Time.now()
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("build: " + mfPath + " has no [project] section")
      return 1
    }
  }

  // Auto-restore: when the manifest declares dependencies and lyric.lock is
  // missing or out of sync with the [dependencies] table, resolve them before
  // building so a clean checkout (or a just-edited dependency set) builds
  // without a manual `lyric restore`.  `--no-restore` opts out.
  if not noRestore and lockNeedsRestore(mfPath, manifest) {
    Console.println("build: resolving dependencies (lyric.lock missing or stale) ...")
    val rc = runRestore(mfPath, false)
    if rc != 0 {
      printErr("build: dependency restore failed")
      return rc
    }
  }

  // D045: resolve active feature set from manifest defaults + CLI flags.
  // `resolveManifestFeatures` (cli/workspace_builder.l, D123) bypasses the
  // Manifest.features field (which has a bootstrap-emitter match quirk when
  // the field type is Option[FeaturesSection]) and scans the raw TOML text
  // directly.  mfText was already read at the top of this function.  Shared
  // with `buildOneNative`'s single-file synthetic project request.
  val (activeFeatures, mfDeclared) = resolveManifestFeatures(
    mfText,
    mfPath,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    target
  )

  val mfDir = Path.dirname(mfPath)
  val buildKind = getBuildKind(manifest)
  // `bundle` (self-contained) is accepted by the manifest parser but not yet
  // implemented; fail loudly rather than silently producing a plain library.
  // `aot` is handled before `buildProject` is called (in `cmdBuild` and
  // `buildReleaseProject`); here it is treated as a normal managed build
  // (the staging DLL step).  Only meaningful for the Dotnet target
  // (Jvm treats `kind` as a no-op).
  match target {
    case Dotnet -> {
      if buildKind == "bundle" {
        printErr(
          mfPath +
            ": [build] kind = \"bundle\" (self-contained) is not yet implemented; use \"exe\" for a framework-dependent launcher or \"lib\" for a managed DLL"
        )
        return 1
      }
    }
    case Jvm -> ()
    case Native -> ()
  }
  val outPath = match explicitOut {
    case Some(o) -> o
    case None -> {
      val ext = outputExt(target, buildKind)
      val stem = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + ext }
      Path.join(Path.join(mfDir, "bin"), stem)
    }
  }

  val outDir = Path.dirname(outPath)
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> printErr("build: cannot create output dir: " + IOError.message(e))
  }

  if proj.packages.count == 0 {
    printErr(
      "build: " + mfPath +
        " [project.packages] is empty — single-DLL projects require explicit per-package source dirs (auto-discovery not yet wired)"
    )
    return 1
  }

  // Collect each package entry's per-file sources.  Each entry may be a
  // single .l file or a directory of .l files; `Emitter.emitProject` merges
  // a multi-file package into one compilation unit (single `package` line,
  // union of import preambles, header-stripped bodies — #2575).
  //
  // A `test_only = true` entry (#6579) is skipped here — it never ships in
  // this production whole-project bundle — but is still resolvable by
  // `collectImportedOwnPackages`/`cli_test.l`'s `libPkgs`, both of which scan
  // `proj.packages` directly rather than this filtered `pkgs` list, so a
  // shared test-only fixture stays importable from `[project.tests]`/a
  // manifest-local single-file build without ever reaching this bundle.
  val pkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    if not pkgEntry.testOnly {
      match readProjectPackageSources(pkgEntry, mfDir, mfPath) {
        case Some(pkgRead) -> {
          if pkgRead.sources.count > 0 {
            pkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgRead.sources, paths = pkgRead.paths))
          }
        }
        case None -> {
          hadFatal = true
        }
      }
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Resolve all dependencies (workspace, path, and NuGet-as-Lyric-package) to
  // DLL paths and collect their source packages for cross-package aspect
  // template resolution (#3498).  `resolveManifestDependencies`
  // (cli/workspace_builder.l, D123) is shared with `buildOneNative`'s
  // single-file synthetic project request — see its doc comment for the
  // workspace-error-vs-unbuilt-local-dep distinction this function preserves
  // verbatim (a workspace failure has always been an immediate `return 1`
  // here; an unbuilt local `path` dep has always been a non-fatal warning).
  // `preResolvedDeps` (#5786) skips this resolution — and the workspace
  // rebuild it triggers — when the caller already ran it.
  val resolved = match preResolvedDeps {
    case Some(r) -> r
    case None -> resolveManifestDependencies(manifest, mfPath, target, cliFeatures, noDefaultFeatures)
  }
  if resolved.hadWorkspaceError {
    return 1
  }
  val restoredDlls = resolved.restoredDlls
  val depTemplatePkgsList = resolved.depTemplateSrcs
  val nugetThirdPartyPaths = resolved.nugetThirdPartyPaths
  val nativeAssetPaths = resolved.nativeAssetPaths

  // On Jvm, a workspace/path dependency's own packages must ride the same
  // bundled compile as `pkgs`: `resolveManifestDependencies` never populates
  // `restoredDllPaths` for a workspace/path/NuGet-Lyric dependency on Jvm
  // (#6697 — the dep's own `bin/*.dll` is always an MSIL PE, never a JVM
  // JAR, so it would crash `emitProjectJvmInProcess`'s restored-dep JAR
  // loader; that loader is real infrastructure for a genuinely pre-compiled
  // JVM producer JAR, #3094, just never fed one by this CLI path), so only
  // `depTemplateSrcs` (aspect/wire templates, not full declarations) carries
  // anything here — without this, a `--target jvm` build of a workspace-dep consumer saw
  // every cross-package symbol from the dep as unknown even though the
  // identical `--target dotnet` build passed via the restored-DLL path
  // (#6136). Harmless duplication on Dotnet is avoided by gating on target:
  // there, the dep is already resolved through `restoredDlls`, and compiling
  // its source a second time into the SAME bundle would double-declare it.
  match target {
    case Jvm -> {
      var jdpi = 0
      while jdpi < depTemplatePkgsList.count {
        pkgs.add(depTemplatePkgsList[jdpi])
        jdpi += 1
      }
    }
    case _ -> ()
  }

  val asmName = stemOf(Path.basename(outPath), 4)
  val projReq = EmitProjectRequest(
    packages = pkgs,
    assemblyName = asmName,
    outputPath = outPath,
    target = target,
    restoredDllPaths = restoredDlls,
    activeFeatures = activeFeatures,
    declaredFeatures = mfDeclared,
    packageVersion = match packageVersionOverride {
      case Some(v) -> v
      case None -> manifest.packageSection.version
    },
    depTemplateSrcs = depTemplatePkgsList,
    nugetAssemblyPaths = nugetThirdPartyPaths,
    // Layer manifest `[build.define]` beneath CLI `--define`s (docs/60 §3.1):
    // CLI wins over a manifest define of the same key, both over the well-known
    // `version` fallback the bridges prepend (decodeDefines is last-wins).
    defines = BD.withManifestDefines(Mf.getManifestBuildDefines(manifest), cliDefines)
  )

  // For JVM builds, inject Maven classpath into LYRIC_FFI_JARS so the JVM
  // auto-FFI resolver can locate downloaded Maven JARs at compile time, via
  // the shared `injectMavenClasspathForJvm` (cli/workspace_builder.l,
  // D123) — also used by `buildOneNative`'s single-file synthetic project
  // request.  The `:` separator is the POSIX path-list separator; Windows
  // drive-letter ambiguity is a known gap tracked in #2214 (both sides
  // fixed together).
  //
  // The original LYRIC_FFI_JARS value is restored immediately after emitProject
  // returns so that multi-package builds do not accumulate stale entries (#3554).
  // `mavenJarColonSep` is reused below to write `module-path.txt` without
  // re-reading the file (#3555).
  var mavenJarColonSep = ""
  var savedFfiJars: Option[String] = None
  match target {
    case Native -> ()
    case Jvm -> {
      val injection = injectMavenClasspathForJvm(mfDir, manifest)
      mavenJarColonSep = injection.classpathColonSep
      savedFfiJars = injection.savedFfiJars
    }
    case Dotnet -> ()
  }

  // `--target native` project builds (#6809): resolve the project's own
  // `[project.packages]` — already collected into `pkgs` above, in manifest
  // declaration order — through the native bridge directly, bypassing
  // `EmitProjectRequest`/`Emitter.emitProject` (which native does not
  // implement — see its own doc comment) since native carries no
  // restored-DLL axis that record was designed for (defines and
  // `[features]`/`@cfg` gating ARE threaded through, via `projReq.defines`/
  // `activeFeatures`/`mfDeclared` below — #6818). `nativeTriple`/`nativeOpt`
  // (non-empty) override the manifest's own `[native]` table triple/opt_level,
  // matching `buildOneNativeWithFeatures`'s single-file precedence rule
  // (#6815 item 2) — `extra_libs` stays manifest-only, same as the
  // single-file path.
  var isNativeTarget = false
  match target {
    case Native -> {
      isNativeTarget = true
    }
    case _ -> ()
  }
  var effTriple = nativeTriple
  var effOpt = nativeOpt
  val effLibs: List[String] = newList()
  if isNativeTarget {
    match manifest.native {
      case Some(nc) -> {
        if effTriple == "" {
          effTriple = nc.triple
        }
        if effOpt == "" {
          effOpt = nc.optLevel
        }
        for lib in nc.extraLibs {
          effLibs.add(lib)
        }
      }
      case None -> ()
    }
  }

  val result = if isNativeTarget {
    Emitter.emitNativeProject(
      pkgs,
      outPath,
      effTriple,
      effOpt,
      effLibs,
      projReq.defines,
      activeFeatures,
      mfDeclared,
      projReq.packageVersion
    )
  } else {
    Emitter.emitProject(projReq)
  }

  // Restore LYRIC_FFI_JARS immediately — before any early return — so
  // subsequent buildProject calls in the same process start clean (#3554).
  restoreMavenClasspath(savedFfiJars)

  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError -> {
        hadError = true
      }
      case DiagWarning -> ()
    }
    printDiag(d)
  }

  if hadError {
    printErr(mfPath + ": project build failed")
    return 1
  }

  match target {
    case Dotnet -> {
      writeRuntimeConfig(outPath)
      // Co-locate the stdlib bundle, restored (workspace/path/Lyric-package
      // NuGet) dependencies, and genuine third-party NuGet assemblies beside
      // the output DLL so `dotnet exec` resolves them.  Unconditional on
      // `buildKind` — a `kind = "lib"` project build is still what `lyric run`
      // executes directly via `dotnet exec` (there is no requirement to opt
      // into `kind = "exe"` first), so it needs the exact same runtime
      // dependencies present as an apphost-launched build (#5066).
      copyRuntimeDepsBeside(outPath, findCompiledLibDir())
      copyRestoredDepDlls(outPath, restoredDlls)
      copyNugetAssembliesBeside(outPath, nugetThirdPartyPaths)
      copyNugetNativeAssetsBeside(outPath, nativeAssetPaths)
      // `kind = "exe"`: emit a native apphost launcher beside the managed DLL
      // so the program runs directly (`./<name>`) without a `dotnet` prefix.
      if buildKind == "exe" {
        match AppHost.emitAppHost(outPath) {
          case Ok(launcherPath) -> Console.println("  launcher: " + launcherPath)
          case Err(m) -> {
            printErr("build: apphost emission failed: " + m)
            return 1
          }
        }
      }
    }
    case Jvm -> {
      // Always written (even empty) so `$(cat bin/module-path.txt)` (book
      // ch14) never hits a missing-file shell error — only its *contents*
      // depend on whether Maven deps were declared and restored (#3559).
      val mpPath = Path.join(outDir, "module-path.txt")
      match File.writeText(mpPath, mavenJarColonSep) {
        case Err(e) -> printErr("build: warning: cannot write " + mpPath + ": " + IOError.message(e))
        case Ok(_) -> ()
      }
    }
    // A native build produces a self-contained POSIX binary directly (no
    // runtimeconfig.json / module-path.txt companion artifact needed).
    case Native -> ()
  }
  val elapsedMs = Time.totalMillis(Time.since(Time.now(), buildStart))
  Console.println(
    "built " + outPath + " (" + toString(pkgs.count) + " package(s), " + Format.formatFixed(elapsedMs, 0) + "ms)"
  )
  0
}

// Compute the default output artifact path for a project build (no explicit -o).
// Mirrors the extension logic in buildProject so runProjectOnce finds the file.
// `buildKind` comes from the manifest's [build] section, default "lib".
func projectBinOutputPath(
  mfDir: in String, proj: in ProjectSection, target: in CompileTarget, buildKind: in String
): String {
  val ext = outputExt(target, buildKind)
  val stem = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + ext }
  Path.join(Path.join(mfDir, "bin"), stem)
}

// Collect all .l source file paths from [project.packages] in a lyric.toml.
// Returns (paths, hadFatal). A file entry yields itself; a directory entry yields
// all .l files under it, sorted deterministically.
func collectProjectSourcePaths(mfPath: in String): (List[String], Bool) {
  val paths: List[String] = newList()
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("cannot read manifest: " + IOError.message(e))
      return (paths, true)
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("cannot parse manifest: " + ManifestError.message(e))
      return (paths, true)
    }
  }
  val proj = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr(mfPath + " has no [project] section")
      return (paths, true)
    }
  }
  val mfDir = Path.dirname(mfPath)
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    if pkgEntry.paths.count > 0 {
      // Explicit file list (TOML array form): add each named file, checked
      // for existence for parity with the single-path/directory branch below
      // (silently watching a non-existent file wastes an LSP/watch handle
      // and gives no diagnostic — #4526).
      var fi = 0
      while fi < pkgEntry.paths.count {
        val absFile = if Path.isAbsolute(pkgEntry.paths[fi]) {
          pkgEntry.paths[fi]
        } else {
          Path.join(mfDir, pkgEntry.paths[fi])
        }
        if File.fileExists(absFile) {
          paths.add(absFile)
        } else {
          printErr("package '" + pkgEntry.name + "': path not found: " + absFile)
          hadFatal = true
        }
        fi += 1
      }
    } else {
      val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
      if File.fileExists(abs) {
        paths.add(abs)
      } else if File.dirExists(abs) {
        val allFiles = match File.listFilesRecursive(abs) {
          case Ok(fs) -> fs
          case Err(e) -> {
            printErr("package '" + pkgEntry.name + "': " + IOError.message(e))
            hadFatal = true
            newList()
          }
        }
        val lFiles: List[String] = newList()
        for f in allFiles.toArray() {
          if Str.endsWith(f, ".l") {
            lFiles.add(f)
          }
        }
        val sorted = sortFileList(lFiles)
        for f in sorted {
          paths.add(f)
        }
      } else {
        printErr("package '" + pkgEntry.name + "': path not found: " + abs)
        hadFatal = true
      }
    }
    pi += 1
  };
  (paths, hadFatal)
}
