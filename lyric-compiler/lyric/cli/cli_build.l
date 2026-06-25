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
import Lyric.Release as Release
import Lyric.Generator as Generator
import Lyric.Emitter as Emitter
import Lyric.AppHost as AppHost
import Lyric.CfgGate as CfgGate
import Std.Sort as Sort
import Std.Time as Time
import Std.Format as Format

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

// Compile `sourcePath` to a DLL at `outPath`.
// Returns the exit code: 0 on success, 1 on error.
// `manifestPath` is forwarded to the generator pre-processor so custom
// @generate(Pkg.Name) annotations can resolve their generator DLLs.
func buildOne(sourcePath: in String, outPath: in String, target: in CompileTarget, manifestPath: in Option[String]): Int {
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

  val result = Emitter.emit(req)
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
      if Release.declaresEntryMain(source) {
        copyRuntimeDepsBeside(outPath, findCompiledLibDir())
      }
    }
    case Jvm -> ()
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
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          target = Jvm
        } else {
          target = Dotnet
        }
        i += 2
      } else {
        printErr("build: --target requires an argument")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }
  match releaseFromDll {
    case Some(dll) -> {
      if positional.count > 0 {
        printErr("build: warning: source-file arguments are ignored alongside --release-from-dll: " + Str.joinList(", ", positional))
      }
      if not File.fileExists(dll) {
        printErr("build: --release-from-dll: file not found: " + dll)
        return 1
      }
      val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case Dotnet -> Release.DotnetAot }
      val extraRefs: List[String] = newList()
      match extraRefsDir {
        case Some(refsDir) -> {
          match File.listFiles(refsDir) {
            case Ok(files) -> {
              val dllBase = Path.basename(dll)
              val sorted = Sort.sortStrings(files.toArray())
              for f in sorted {
                val fBase = Path.basename(f)
                // Exclude the primary DLL and Lyric.Stdlib.dll (locateStdlib adds it independently).
                if Str.endsWith(f, ".dll") and fBase != dllBase and fBase != "Lyric.Stdlib.dll" {
                  extraRefs.add(f)
                }
              }
            }
            case Err(e) -> {
              printErr("build: --extra-refs-dir: " + IOError.message(e))
              return 1
            }
          }
        }
        case None -> ()
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
        noRestore
      )
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
          noRestore = noRestore
        )
      )
    }
    // `[build] kind = "aot"` in lyric.toml triggers the native AOT pipeline
    // even without `--release` on the command line.
    val autoAot = match target {
      case Dotnet -> readBuildKindFromManifest(Some(value = mfPath)) == "aot"
      case Jvm -> false
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
        noRestore
      )
    }
    // `--rid` only applies to `--release` / `kind = "aot"` (Native AOT); warn
    // here — the only project-mode path where ridArg is genuinely unused (#2022).
    match ridArg {
      case Some(_) -> printErr("build: warning: --rid has no effect without --release")
      case None -> ()
    }
    return buildProject(mfPath, explicitOut, target, cliFeatures, noDefaultFeatures, allFeatures, noRestore)
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
    return buildReleaseSingle(sourcePath, explicitOut, target, ridArg, manifestArg)
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
    return watchLoop(files, BuildFile(sourcePath = sourcePath, outArg = outPath, target = target, manifest = manifestArg))
  }

  buildOne(sourcePath, outPath, target, manifestArg)
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
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case Dotnet -> Release.DotnetAot }
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
  // Name the staging assembly after the PACKAGE, not the source filename.  The
  // AOT trampoline references `<pkgName>.Program.main`, and AOT resolves it
  // through the assembly's identity; if the assembly were named from the file
  // stem (e.g. `im.dll` for `package IntMain`) that reference fails to load at
  // runtime (FileNotFoundException for the package-named assembly).  The native
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
): Int {
  // JVM native-image is not yet implemented; delegate to buildRelease which
  // fails loud without performing a wasted managed build.
  val releaseTarget = match target { case Jvm -> Release.JvmNativeImage; case Dotnet -> Release.DotnetAot }
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
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    var combined = ""
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
    noRestore
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
  // `getManifestFeaturesOrEmpty` returns the whole FeaturesSection record from
  // the match arm (bootstrap-emitter-safe pattern); field access happens after
  // the match, outside any match arm body.
  // D045: resolve active feature set from manifest defaults + CLI flags.
  // readFeatureDefaultsFromToml / readFeatureDeclaredFromToml bypass the
  // Manifest.features field (which has a bootstrap-emitter match quirk when
  // the field type is Option[FeaturesSection]) and scan the raw TOML text
  // directly.  mfText was already read at the top of this function.
  val mfDefaults = Mf.readFeatureDefaultsFromToml(mfText, mfPath)
  val mfDeclared = Mf.readFeatureDeclaredFromToml(mfText, mfPath)
  val activeFeatures: List[String] = newList()
  if allFeatures {
    var ai = 0
    while ai < mfDeclared.count {
      activeFeatures.add(mfDeclared[ai])
      ai += 1
    }
  } else {
    if not noDefaultFeatures {
      var ai = 0
      while ai < mfDefaults.count {
        activeFeatures.add(mfDefaults[ai])
        ai += 1
      }
    }
    var ci = 0
    while ci < cliFeatures.count {
      activeFeatures.add(cliFeatures[ci])
      ci += 1
    }
  }

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
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
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
    if pkgSources.count > 0 {
      pkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources))
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Resolve all dependencies (workspace and path) to DLL paths and collect their
  // source packages for cross-package aspect template resolution (#3498).
  // Format: "depName\tdllPath" — passed to emitter.l which writes "DEP\t..." lines.
  val restoredDlls: List[String] = newList()
  val depTemplatePkgsList: List[ProjectPackage] = newList()

  // First, build all workspace dependencies (if we're in a workspace).
  val (wsDepDlls, wsHadError) = buildWorkspaceDeps(manifest, mfPath, target)
  if wsHadError {
    return 1
  }
  var wdi = 0
  while wdi < wsDepDlls.count {
    restoredDlls.add(wsDepDlls[wdi])
    wdi += 1
  }

  // Then, resolve path dependencies (for backwards compat with non-workspace projects).
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir } else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        val depBinDir = Path.join(depDir, "bin")
        if File.fileExists(depToml) {
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
                    restoredDlls.add(dep.name + "\t" + dllPath)
                  } else {
                    printErr("build: " + Release.localDepNotBuiltMessage(dep.name, dllPath, depToml))
                  }
                  // Collect source files from this path dependency so the weaver can
                  // resolve cross-package `from`-instance aspect templates (#3498).
                  match depMf.project {
                    case Some(proj) -> {
                      var pki = 0
                      while pki < proj.packages.count {
                        val pkgEntry = proj.packages[pki]
                        val srcPath = Path.join(depDir, pkgEntry.path)
                        match File.readText(srcPath) {
                          case Ok(srcText) -> {
                            val srcList: List[String] = newList()
                            srcList.add(srcText)
                            depTemplatePkgsList.add(ProjectPackage(name = pkgEntry.name, sources = srcList))
                          }
                          case Err(e) -> {
                            printErr("build: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                          }
                        }
                        pki += 1
                      }
                    }
                    case None -> ()
                  }
                }
                case Err(e) -> {
                  printErr("build: local dep '" + dep.name + "': malformed lyric.toml: " + ManifestError.message(e))
                }
              }
            }
            case Err(e) -> {
              printErr("build: local dep '" + dep.name + "': cannot read " + depToml + ": " + IOError.message(e))
            }
          }
        } else {
          printErr(
            "build: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml +
              "'; check the path = \"...\" entry in your lyric.toml"
          )
        }
      }
      case Mf.DepSource.Workspace(_) -> {
        // Workspace dependencies should have been handled above by buildWorkspaceDeps.
        // If we reach here, it means buildWorkspaceDeps didn't find it, which
        // already printed an error.
        ()
      }
      case _ -> ()
    }
    di += 1
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
    packageVersion = manifest.packageSection.version,
    depTemplateSrcs = depTemplatePkgsList
  )

  // For JVM builds, inject Maven classpath into LYRIC_FFI_JARS so the JVM
  // auto-FFI resolver can locate downloaded Maven JARs at compile time.
  // The `:` separator is the POSIX path-list separator; Windows drive-letter
  // ambiguity is a known gap tracked in #2214 (both sides fixed together).
  //
  // The original LYRIC_FFI_JARS value is restored immediately after emitProject
  // returns so that multi-package builds do not accumulate stale entries (#3554).
  // `mavenJarColonSep` is reused below to write `module-path.txt` without
  // re-reading the file (#3555).
  var mavenJarColonSep = ""
  var savedFfiJars: Option[String] = None
  match target {
    case Jvm -> {
      val classpathFile = Path.join(Path.join(Path.join(mfDir, "target"), "restore"), "jvm-classpath.txt")
      match File.readText(classpathFile) {
        case Ok(text) -> {
          val trimmed = Str.trim(text)
          if trimmed.length > 0 {
            val lines = Str.split(trimmed, "\n")
            var li = 0
            while li < lines.length {
              val line = Str.trim(lines[li])
              if line.length > 0 {
                if mavenJarColonSep.length > 0 {
                  mavenJarColonSep = mavenJarColonSep + ":"
                }
                mavenJarColonSep = mavenJarColonSep + line
              }
              li += 1
            }
          }
        }
        case Err(_) -> {
          val hasMaven = match manifest.maven { case Some(m) -> m.entries.count > 0; case None -> false }
          if hasMaven {
            printErr(
              "build: note: target/restore/jvm-classpath.txt not found; Maven JARs will not be available to the JVM emitter"
            )
            printErr("  run `lyric restore` first to download Maven dependencies")
          }
        }
      }
      if mavenJarColonSep.length > 0 {
        val prevFfi = match Environment.getVar("LYRIC_FFI_JARS") { case Ok(v) -> v; case Err(_) -> "" }
        savedFfiJars = Some(value = prevFfi)
        val injected = if prevFfi.length > 0 { prevFfi + ":" + mavenJarColonSep } else { mavenJarColonSep }
        Environment.setVar("LYRIC_FFI_JARS", injected)
      }
    }
    case Dotnet -> ()
  }

  val result = Emitter.emitProject(projReq)

  // Restore LYRIC_FFI_JARS immediately — before any early return — so
  // subsequent buildProject calls in the same process start clean (#3554).
  match savedFfiJars {
    case Some(prev) -> Environment.setVar("LYRIC_FFI_JARS", prev)
    case None -> ()
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
    printErr(mfPath + ": project build failed")
    return 1
  }

  match target {
    case Dotnet -> {
      writeRuntimeConfig(outPath)
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
        // Co-locate the stdlib bundle and restored dependencies beside the
        // launcher so the produced binary runs standalone: the apphost
        // `./<name>` resolves its managed deps from its own directory.  Only for
        // `kind = "exe"` — a `kind = "lib"` build (including the stdlib bundle
        // itself) is a consumable artifact, not a runnable one.
        copyRuntimeDepsBeside(outPath, findCompiledLibDir())
        copyRestoredDepDlls(outPath, restoredDlls)
      }
    }
    case Jvm -> {
      if mavenJarColonSep.length > 0 {
        val mpPath = Path.join(outDir, "module-path.txt")
        match File.writeText(mpPath, mavenJarColonSep) {
          case Err(e) -> printErr("build: warning: cannot write " + mpPath + ": " + IOError.message(e))
          case Ok(_) -> ()
        }
      }
    }
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
    pi += 1
  };
  (paths, hadFatal)
}
