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
    case Some(p) -> match File.readText(p) { case Err(e) -> Err(error = "build: cannot read manifest " + p + ": " + IOError.message(e)); case Ok(mfText) -> match Mf.parseManifest(mfText, p) { case Err(me) -> Err(error = "build: " + ManifestError.message(me)); case Ok(m) -> Ok(value = m.native) } }
    case None -> match discoverManifest(None) { case None -> Ok(value = noneCfg); case Some(mf) -> match File.readText(mf) { case Err(_) -> Ok(value = noneCfg); case Ok(mfText) -> match Mf.parseManifest(mfText, mf) { case Err(_) -> Ok(value = noneCfg); case Ok(m) -> Ok(value = m.native) } } }
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

// Filter a `--extra-refs-dir` directory listing down to the extra reference
// DLLs for `--release-from-dll`: only `.dll` files, excluding the primary
// DLL itself (`dllBase`, the release target's own basename) and
// `Lyric.Stdlib.dll` (colocated independently by the release pipeline via
// `locateStdlib`, so including it here would duplicate it).  Sorted for
// deterministic ordering.  Pulled out of `cmdBuild` so the filtering logic
// is unit-testable without invoking the (heavy, toolchain-dependent) native
// AOT release path (#4282).
pub func filterExtraRefsDlls(files: in List[String], dllBase: in String): List[String] {
  val result: List[String] = newList()
  val sorted = Sort.sortStrings(files.toArray())
  for f in sorted {
    val fBase = Path.basename(f)
    if Str.endsWith(f, ".dll") and fBase != dllBase and fBase != "Lyric.Stdlib.dll" {
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
// `dotnet exec` time with a missing-assembly error (D122).
record NonNativeEmitOutcome {
  emitResult: EmitResult
  restoredDlls: List[String]
  nugetThirdPartyPaths: List[String]
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
// any parent directory at all (D122).
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
    case Some(p) -> match File.readText(p) { case Err(e) -> Err(error = "build: cannot read manifest " + p + ": " + IOError.message(e)); case Ok(mfText) -> match Mf.parseManifest(mfText, p) { case Err(me) -> Err(error = "build: " + ManifestError.message(me)); case Ok(m) -> Ok(value = Some(value = LoadedManifest(manifest = m, mfPath = p, mfText = mfText))) } }
    case None -> match discoverManifestForSourceFile(sourcePath) { case None -> Ok(value = noneLm); case Some(mf) -> match File.readText(mf) { case Err(_) -> Ok(value = noneLm); case Ok(mfText) -> match Mf.parseManifest(mfText, mf) { case Err(_) -> Ok(value = noneLm); case Ok(m) -> Ok(value = Some(value = LoadedManifest(manifest = m, mfPath = mf, mfText = mfText))) } } }
  }
}

func noContributionOutcome(req: in EmitRequest): NonNativeEmitOutcome {
  NonNativeEmitOutcome(emitResult = Emitter.emit(req), restoredDlls = newList(), nugetThirdPartyPaths = newList())
}

func failedEmitOutcome(msg: in String): NonNativeEmitOutcome {
  printErr(msg)
  val noDiags: List[Diagnostic] = newList()
  NonNativeEmitOutcome(
    emitResult = EmitResult(outputPath = None, diagnostics = noDiags),
    restoredDlls = newList(),
    nugetThirdPartyPaths = newList()
  )
}

// Non-native (Dotnet/Jvm) emit path for `buildOneNative`.  When the source
// file sits near a lyric.toml — an explicit `--manifest`, or one discovered
// by walking up from the source file's own directory
// (`discoverManifestForSourceFile`) — that actually declares dependencies,
// NuGet/Maven assets, or features, synthesizes a one-package
// `EmitProjectRequest` and routes it through `Emitter.emitProject`: the same
// dependency-resolution and bundling pipeline `buildProject` uses for a
// manifest's `[project.packages]`, instead of the standalone `Emitter.emit`
// path, which structurally cannot see anything outside `Std.*` (D122).
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
  req: in EmitRequest, sourcePath: in String, manifestPath: in Option[String]
): NonNativeEmitOutcome {
  val loaded = match loadManifestForSingleFileBuild(sourcePath, manifestPath) {
    case Err(msg) -> return failedEmitOutcome(msg)
    case Ok(opt) -> opt
  }
  val lm = match loaded { case None -> return noContributionOutcome(req); case Some(l) -> l }

  val emptyCliFeatures: List[String] = newList()
  val (activeFeatures, declaredFeatures) = resolveManifestFeatures(lm.mfText, lm.mfPath, emptyCliFeatures, false, false)
  val resolvedDeps = resolveManifestDependencies(lm.manifest, lm.mfPath, req.target)
  if resolvedDeps.hadUnbuiltLocalDep {
    return failedEmitOutcome(
      sourcePath + ": build failed (unresolved dependency declared in " + lm.mfPath + "; see above)"
    )
  }

  val hasMavenEntries = match lm.manifest.maven { case Some(m) -> m.entries.count > 0; case None -> false }
  val jvmNeedsMaven = match req.target { case Jvm -> hasMavenEntries; case _ -> false }

  val hasContribution = resolvedDeps.restoredDlls.count > 0 or resolvedDeps.nugetThirdPartyPaths.count > 0 or
    activeFeatures.count > 0 or
    declaredFeatures.count > 0 or
    resolvedDeps.depTemplateSrcs.count > 0 or
    jvmNeedsMaven

  if not hasContribution {
    return noContributionOutcome(req)
  }

  val pkgNameRaw = Release.packageNameOf(req.source)
  val pkgName = if pkgNameRaw.length > 0 { pkgNameRaw } else { req.assemblyName }
  val srcs: List[String] = newList()
  srcs.add(req.source)
  val pkgs: List[ProjectPackage] = newList()
  pkgs.add(ProjectPackage(name = pkgName, sources = srcs))

  val projReq = EmitProjectRequest(
    packages = pkgs,
    assemblyName = pkgName,
    outputPath = req.outputPath,
    target = req.target,
    restoredDllPaths = resolvedDeps.restoredDlls,
    activeFeatures = activeFeatures,
    declaredFeatures = declaredFeatures,
    packageVersion = req.packageVersion,
    depTemplateSrcs = resolvedDeps.depTemplateSrcs,
    nugetAssemblyPaths = resolvedDeps.nugetThirdPartyPaths
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
    nugetThirdPartyPaths = resolvedDeps.nugetThirdPartyPaths
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
pub func buildOneNative(
  sourcePath: in String,
  outPath: in String,
  target: in CompileTarget,
  manifestPath: in Option[String],
  nativeTriple: in String,
  nativeOpt: in String,
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
    packageVersion = ""
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
      case Ok(ncOpt) -> match ncOpt { case Some(nc) -> { if effTriple == "" { effTriple = nc.triple }; if effOpt == "" { effOpt = nc.optLevel }; for lib in nc.extraLibs { effLibs.add(lib) } }; case None -> () }
    }
  }
  var resolvedRestoredDlls: List[String] = newList()
  var resolvedNugetPaths: List[String] = newList()
  val result = if isNativeTarget {
    Emitter.emitNative(req, effTriple, effOpt, effLibs)
  } else {
    val outcome = emitSingleFileOrProject(req, sourcePath, manifestPath)
    resolvedRestoredDlls = outcome.restoredDlls
    resolvedNugetPaths = outcome.nugetThirdPartyPaths
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
      // `emitSingleFileOrProject` (D122) resolves manifest dependencies to
      // DLL paths when a nearby lyric.toml contributes any — colocate those
      // beside the output exactly like `buildProject` does, so a runnable
      // single-file program that now compiles against a workspace/path/NuGet
      // dependency can also actually load it at `dotnet exec` time.  Empty
      // lists (the common no-manifest case) make these calls no-ops.
      if Release.declaresEntryMain(source) {
        copyRuntimeDepsBeside(outPath, findCompiledLibDir())
        copyRestoredDepDlls(outPath, resolvedRestoredDlls)
        copyNugetAssembliesBeside(outPath, resolvedNugetPaths)
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
  var release: Bool = false
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
      release = true
      i += 1
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
    case Some(v) -> match validatePackageVersionArg(v) { case Some(msg) -> { printErr("build: " + msg); return 1 }; case None -> () }
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
      val extraRefs: List[String] = match extraRefsDir {
        case Some(refsDir) -> {
          match File.listFiles(refsDir) {
            case Ok(files) -> filterExtraRefsDlls(files, Path.basename(dll))
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
    if release {
      return buildReleaseProject(
        mfPath,
        explicitOut,
        target,
        ridArg,
        cliFeatures,
        noDefaultFeatures,
        allFeatures,
        noRestore,
        packageVersionArg
      )
    }
    // `[build] kind = "aot"` in lyric.toml triggers the native AOT pipeline
    // even without `--release` on the command line.  Computed before the
    // `--watch` check so watch mode can reject (rather than silently ignore)
    // the manifest's AOT directive (#4203).
    val autoAot = match target {
      case Dotnet -> readBuildKindFromManifest(Some(value = mfPath)) == "aot"
      case Jvm -> false
      case Native -> false
    }
    if watch and autoAot {
      printErr("build: --watch is not supported with [build] kind = \"aot\" in " + mfPath)
      return 1
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
          pkgVer = packageVersionArg
        )
      )
    }
    if autoAot {
      return buildReleaseProject(
        mfPath,
        explicitOut,
        target,
        ridArg,
        cliFeatures,
        noDefaultFeatures,
        allFeatures,
        noRestore,
        packageVersionArg
      )
    }
    // `--rid` only applies to `--release` / `kind = "aot"` (Native AOT); warn
    // here — the only project-mode path where ridArg is genuinely unused (#2022).
    match ridArg {
      case Some(_) -> printErr("build: warning: --rid has no effect without --release")
      case None -> ()
    }
    return buildProject(
      mfPath,
      explicitOut,
      target,
      cliFeatures,
      noDefaultFeatures,
      allFeatures,
      noRestore,
      packageVersionArg
    )
  }

  val sourcePath = positional[0]
  if not File.fileExists(sourcePath) {
    printErr("build: source file not found: " + sourcePath)
    return 1
  }

  if release and watch {
    printErr("build: --watch is not supported with --release")
    return 1
  }

  if release {
    match target {
      case Native -> {
        printErr(
          "build: --release is not needed with --target native (the build already produces a self-contained native binary)"
        )
        return 1
      }
      case _ -> ()
    }
    return buildReleaseSingle(sourcePath, explicitOut, target, ridArg, manifestArg)
  }

  // `--rid` only applies to `--release` (single-file builds have no
  // `kind = "aot"` auto-trigger); warn here so the flag isn't silently
  // dropped, mirroring the project-mode warning above (#4206).
  match ridArg {
    case Some(_) -> printErr("build: warning: --rid has no effect without --release")
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
        nativeOpt = optArg
      )
    )
  }

  buildOneNative(sourcePath, outPath, target, manifestArg, tripleArg, optArg)
}

// Single-file `lyric build --release <source.l>`: compile to a staging DLL,
// then produce a self-contained native binary via Lyric.Release.  The default
// output is the source stem with no extension (an executable), next to the
// source unless `-o` overrides it.
func buildReleaseSingle(
  sourcePath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  ridArg: in Option[String],
  manifestArg: in Option[String],
): Int {
  // Native is unreachable here (cmdBuild rejects --release + --target native).
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case _ -> Release.DotnetAot }
  // JVM (GraalVM) release fails loud without doing a wasted .NET build.
  match releaseTarget {
    case JvmNativeImage -> return Release.buildRelease(releaseTarget, "", newList(), ridArg, "")
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
  val stagingDll = Path.join(Path.join(srcDir, ".lyric-release"), pkgName + ".dll")
  val buildExit = buildOne(sourcePath, stagingDll, Dotnet, manifestArg)
  if buildExit != 0 {
    return buildExit
  }

  val outNative = match explicitOut { case Some(o) -> o; case None -> Path.join(srcDir, stem) }
  Release.buildRelease(releaseTarget, stagingDll, newList(), ridArg, outNative)
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
): Int {
  // JVM native-image is not yet implemented; delegate to buildRelease which
  // fails loud without performing a wasted managed build.
  // Native is unreachable here (cmdBuild rejects --release + --target native).
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case _ -> Release.DotnetAot }
  match releaseTarget {
    case JvmNativeImage -> return Release.buildRelease(releaseTarget, "", newList(), ridArg, "")
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
  // rebuild (#3219).
  val entryPkgNames: List[String] = newList()
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
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
  // by the intermediate managed DLL.
  val dllBase = match proj.outputAssembly { case Some(s) -> s; case None -> proj.name + ".dll" }
  val stagingDir = Path.join(mfDir, ".lyric-release")
  val stagingDll = Path.join(stagingDir, dllBase)

  val buildExit = buildProject(
    mfPath,
    Some(value = stagingDll),
    Dotnet,
    cliFeatures,
    noDefaultFeatures,
    allFeatures,
    noRestore,
    packageVersionOverride
  )
  if buildExit != 0 {
    return buildExit
  }

  // Collect the pre-built DLL paths of local-path dependencies.  These are not
  // embedded in the bundle — the AOT linker needs them as managed references.
  val extraRefs: List[String] = newList()
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir } else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if not File.fileExists(depToml) {
          printErr(
            "build: --release: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml +
              "'; check the path = \"...\" entry in your lyric.toml"
          )
          return 1
        }
        match File.readText(depToml) {
          case Ok(depMfText) -> {
            match Mf.parseManifest(depMfText, depToml) {
              case Ok(depMf) -> {
                val dllName = match depMf.project {
                  case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
                  case None -> depMf.packageSection.name + ".dll"
                }
                val dllPath = Path.join(depBinDir, dllName)
                if File.fileExists(dllPath) {
                  extraRefs.add(dllPath)
                } else {
                  printErr("build: --release: " + Release.localDepNotBuiltMessage(dep.name, dllPath, depToml))
                  return 1
                }
              }
              case Err(e) -> {
                printErr("build: --release: local dep '" + dep.name + "': malformed lyric.toml: " + ManifestError.message(e))
                return 1
              }
            }
          }
          case Err(e) -> {
            printErr("build: --release: local dep '" + dep.name + "': cannot read " + depToml + ": " + IOError.message(e))
            return 1
          }
        }
      }
      case _ -> ()
    }
    di += 1
  }

  val stem = stemOf(dllBase, 4)
  val outNative = match explicitOut { case Some(o) -> o; case None -> Path.join(mfDir, stem) }
  Release.buildRelease(releaseTarget, stagingDll, extraRefs, ridArg, outNative)
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

// Project-mode build: reads [project.packages] from lyric.toml and
// bundles every package's .l files into a single DLL.
func buildProject(
  mfPath: in String,
  explicitOut: in Option[String],
  target: in CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  noRestore: in Bool,
  packageVersionOverride: in Option[String],
): Int {
  val buildStart = Time.now()
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
  // `resolveManifestFeatures` (cli/workspace_builder.l, D122) bypasses the
  // Manifest.features field (which has a bootstrap-emitter match quirk when
  // the field type is Option[FeaturesSection]) and scans the raw TOML text
  // directly.  mfText was already read at the top of this function.  Shared
  // with `buildOneNative`'s single-file synthetic project request.
  val (activeFeatures, mfDeclared) = resolveManifestFeatures(
    mfText,
    mfPath,
    cliFeatures,
    noDefaultFeatures,
    allFeatures
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
  val pkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val pkgSources: List[String] = newList()
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
              case Ok(t) -> pkgSources.add(t)
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
              case Ok(t) -> pkgSources.add(t)
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
                  case Ok(t) -> pkgSources.add(t)
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
    if pkgSources.count > 0 {
      pkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources))
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Resolve all dependencies (workspace, path, and NuGet-as-Lyric-package) to
  // DLL paths and collect their source packages for cross-package aspect
  // template resolution (#3498).  `resolveManifestDependencies`
  // (cli/workspace_builder.l, D122) is shared with `buildOneNative`'s
  // single-file synthetic project request — see its doc comment for the
  // workspace-error-vs-unbuilt-local-dep distinction this function preserves
  // verbatim (a workspace failure has always been an immediate `return 1`
  // here; an unbuilt local `path` dep has always been a non-fatal warning).
  val resolved = resolveManifestDependencies(manifest, mfPath, target)
  if resolved.hadWorkspaceError {
    return 1
  }
  val restoredDlls = resolved.restoredDlls
  val depTemplatePkgsList = resolved.depTemplateSrcs
  val nugetThirdPartyPaths = resolved.nugetThirdPartyPaths

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
    nugetAssemblyPaths = nugetThirdPartyPaths
  )

  // For JVM builds, inject Maven classpath into LYRIC_FFI_JARS so the JVM
  // auto-FFI resolver can locate downloaded Maven JARs at compile time, via
  // the shared `injectMavenClasspathForJvm` (cli/workspace_builder.l,
  // D122) — also used by `buildOneNative`'s single-file synthetic project
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
    case Native -> {
      printErr(
        "build: --target native does not yet support manifest (multi-package) builds; compile the entry file directly: lyric build <main.l> --target native"
      )
      return 1
    }
    case Jvm -> {
      val injection = injectMavenClasspathForJvm(mfDir, manifest)
      mavenJarColonSep = injection.classpathColonSep
      savedFfiJars = injection.savedFfiJars
    }
    case Dotnet -> ()
  }

  val result = Emitter.emitProject(projReq)

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
    // Unreachable: project-mode native builds are rejected before the
    // emit loop.
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
