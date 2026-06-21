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
import Std.ProcessCapture as ProcessCapture
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Emitter as Emitter
import Lyric.TestSynth as TestSynth
import Lyric.Repl as Repl
import Lyric.Discovery as Disc
import Lyric.CfgGate as CfgGate
import Lyric.Workspace as Ws

// ─────────────────────────────────────────────────────────────────────────────
// §11b. Repl command
// ─────────────────────────────────────────────────────────────────────────────
func cmdRepl(argv: in slice[String]): Int {
  Repl.runRepl(argv)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11c. Test command
// ─────────────────────────────────────────────────────────────────────────────
// First `package <name>` declaration in `src` (skipping annotations/comments),
// or "" if none.  Used to wrap a single `@test_module` file as a `ProjectPackage`
// when linking compiler DLLs (#2364 Stage 5).
func firstPackageNameOf(src: in String): String {
  val lines = Str.split(src, "\n")
  var i = 0
  while i < lines.length {
    val t = Str.trim(lines[i])
    if Str.startsWith(t, "package ") {
      return Str.trim(Str.substring(t, 8, t.length - 8))
    }
    i = i + 1
  }
  ""
}

// Emit a single-file `@test_module` plainly (no compiler-DLL linking).
func emitTestPlain(rewritten: in String, stem: in String, outPath: in String, targetJvm: in Bool): EmitResult {
  val tgt = if targetJvm { Jvm } else { Dotnet }
  Emitter.emit(
    EmitRequest(source = rewritten, assemblyName = stem, outputPath = outPath, target = tgt, packageVersion = "")
  )
}

// Emit a single-file `@test_module` that imports `Lyric.*` compiler packages,
// linking the already-compiled compiler DLLs as restored deps (#2364 Stage 5).
func emitTestLinked(
  rewritten: in String, stem: in String, outPath: in String, compilerDlls: in List[String]
): EmitResult {
  val testSrcs: List[String] = newList()
  testSrcs.add(rewritten)
  // Guard against a missing `package` declaration: an empty package name would
  // produce a malformed `ProjectPackage`.  A `@test_module` always carries a
  // `package` line, so this falls back to the assembly stem only defensively
  // (#2564).
  val rawPkgName = firstPackageNameOf(rewritten)
  val testPkgName = if rawPkgName.length > 0 { rawPkgName } else { stem }
  val testPkgs: List[ProjectPackage] = newList()
  testPkgs.add(ProjectPackage(name = testPkgName, sources = testSrcs))
  val activeF: List[String] = newList()
  val declaredF: List[String] = newList()
  val noDepTemplateSrcs: List[ProjectPackage] = newList()
  Emitter.emitProject(
    EmitProjectRequest(
      packages = testPkgs,
      assemblyName = stem,
      outputPath = outPath,
      target = Dotnet,
      restoredDllPaths = compilerDlls,
      activeFeatures = activeF,
      declaredFeatures = declaredF,
      packageVersion = "",
      depTemplateSrcs = noDepTemplateSrcs
    )
  )
}

func cmdTest(argv: in slice[String]): Int {
  var filterArg: Option[String] = None
  var manifestArg: Option[String] = None
  var listMode = false
  var targetJvm = false
  var failFast = false
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--filter" {
      if i + 1 < argv.length {
        filterArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("test: --filter requires a value")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          targetJvm = true
        } else if t == "dotnet" {
          targetJvm = false
        } else {
          printErr("test: --target must be 'dotnet' or 'jvm'")
          return 1
        }
        i += 2
      } else {
        printErr("test: --target requires an argument (dotnet|jvm)")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("test: --manifest requires a path")
        return 1
      }
    } else if arg == "--list" {
      listMode = true
      i += 1
    } else if arg == "--fail-fast" {
      failFast = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // `lyric test --manifest <toml>` reads `[project.tests]` and runs
  // each test file bundled with the manifest's `[project.packages]`
  // (#465).  Each test contributes one synthesised executable; the
  // command's exit code is non-zero if any test fails.
  // Explicit --manifest takes precedence.
  match manifestArg {
    case Some(p) -> return cmdTestManifest(p, filterArg, targetJvm, failFast)
    case None -> ()
  }

  if positional.count == 0 {
    // No explicit source file and no --manifest: auto-discover project.
    match Disc.findNearestManifest(Environment.currentDirectory()) {
      case Some(p) -> return cmdTestManifest(p, filterArg, targetJvm, failFast)
      case None -> {
        printErr("test: missing source file and no lyric.toml found")
        return 1
      }
    }
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("test: " + IOError.message(e))
      return 1
    }
  }

  if listMode {
    match TestSynth.listEntries(source) {
      case Err(diags) -> {
        for d in diags.toArray() {
          printDiag(d)
        }
        return 1
      }
      case Ok(entries) -> {
        for e in entries.toArray() {
          match e {
            case TestEntry(title) -> Console.println("test: " + title)
            case PropertyEntry(title, reason) -> Console.println("prop: " + title + " (" + reason + ")")
            case FixtureEntry(name) -> Console.println("fixture: " + name)
          }
        }
        return 0
      }
    }
  }

  val stem = stemOf(Path.basename(sourcePath), 2)
  val outExt = if targetJvm { ".jar" } else { ".dll" }
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-test"), stem + outExt)

  match TestSynth.synthesize(source, filterArg) {
    case NoTestModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": not a @test_module — add @test_module annotation")
      return 1
    }
    case UserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": @test_module cannot define func main()")
      return 1
    }
    case ParseFailures(diags) -> {
      for d in diags.toArray() {
        printDiag(d)
      }
      return 1
    }
    case Synthesised(rewritten, testCnt, skipCnt) -> {
      Console.println(toString(testCnt) + " test(s), " + toString(skipCnt) + " skipped")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      // #2364 Stage 5: a @test_module that imports `Lyric.*` compiler packages
      // links the already-compiled compiler DLLs as restored deps (via
      // `emitProject`) rather than recompiling them from source (the retired
      // `LYRIC_LOAD_COMPILER` path).  The closure → DLL mapping is computed by
      // `Emitter.compilerClosureDllPaths`; an empty result (no compiler imports,
      // or JVM target) keeps the plain single-file `emit`.  The emit itself is
      // delegated to small helpers so this function body stays simple (the F#
      // stage-0 segment compiler chokes on a large record-valued if-expression).
      val testLibDir = if targetJvm { "" } else { findCompiledLibDir() }
      val compilerDlls: List[String] = if targetJvm {
        newList()
      } else {
        Emitter.compilerClosureDllPaths(rewritten, testLibDir)
      }
      val result = if compilerDlls.count > 0 {
        emitTestLinked(rewritten, stem, outPath, compilerDlls)
      } else {
        emitTestPlain(rewritten, stem, outPath, targetJvm)
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
        return 1
      }
      match result.outputPath {
        case None -> {
          printErr("test: build failed")
          return 1
        }
        case Some(_) -> ()
      }
      // JVM: the bundled JAR is self-contained (the self-hosted JVM bridge
      // bundles the user package plus its transitive stdlib import closure),
      // so it runs directly via `java -jar` with no DLL staging or runtimeconfig.
      if targetJvm {
        val jvmArgs: List[String] = newList()
        jvmArgs.add("-jar")
        jvmArgs.add(outPath)
        val jvmRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("java", jvmArgs, "", 600000)
        Console.print(jvmRes.stdout)
        if jvmRes.stderr.length > 0 {
          Console.error(jvmRes.stderr)
        }
        if jvmRes.exitCode == -1 {
          printErr("test: failed to start java")
          return 1
        }
        if jvmRes.timedOut {
          printErr("test: test binary timed out (600 s limit reached)")
          return 1
        }
        if jvmRes.stdout.length == 0 and jvmRes.exitCode == 0 {
          printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
          return 1
        }
        return jvmRes.exitCode
      }
      // Co-locate the fully-compiled stdlib runtime assemblies beside the
      // test DLL so `dotnet exec` resolves the real stdlib `pub func`s
      // (Std.Testing.assertEqualInt, …).  Discovery is non-hardcoded
      // (findCompiledLibDir): the already-compiled stdlib beside the binary /
      // in the SDK `lib/` / in the dev `.bootstrap/stage1` tree is the source
      // of truth — not the per-PID `/tmp/lyric-stdlib-*` recompile byproduct.
      val testOutDir2 = Path.dirname(outPath)
      val libDir = findCompiledLibDir()
      if libDir.length > 0 {
        copyRuntimeDepsBeside(outPath, libDir, compilerDlls.count > 0)
      } else {
        // Fallback for environments without a discoverable compiled stdlib
        // (e.g. an isolated temp checkout): recover the DLLs the in-process
        // bridge just wrote to its per-PID `/tmp/lyric-stdlib-*` cache.
        val tmpRoot = Environment.getVarOrDefault("TMPDIR", "/tmp")
        match File.listDirs(tmpRoot) {
          case Err(_) -> ()
          case Ok(tmpDirs) -> {
            for d in tmpDirs.toArray() {
              val base = Path.basename(d)
              if Str.startsWith(base, "lyric-stdlib-") {
                match File.listFiles(d) {
                  case Err(_) -> ()
                  case Ok(fs) -> {
                    for f in fs.toArray() {
                      if Str.endsWith(f, ".dll") {
                        val dest = Path.join(testOutDir2, Path.basename(f))
                        if not File.fileExists(dest) {
                          match File.readBytes(f) {
                            case Ok(bs) -> {
                              val _ = File.writeBytes(dest, bs)
                            }
                            case Err(_) -> ()
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      // #2364 Stage 5: co-locate the linked compiler DLLs beside the test so
      // `dotnet exec` resolves them (a flat probing path can't load a non-NuGet
      // bin layout).
      if compilerDlls.count > 0 {
        copyRestoredDepDlls(outPath, compilerDlls)
      }
      writeRuntimeConfig(outPath)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      val dotnetRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("dotnet", execArgs, "", 600000)
      Console.print(dotnetRes.stdout)
      if dotnetRes.stderr.length > 0 {
        Console.error(dotnetRes.stderr)
      }
      if dotnetRes.exitCode == -1 {
        printErr("test: failed to start dotnet")
        1
      } else if dotnetRes.timedOut {
        printErr("test: test binary timed out (600 s limit reached)")
        1
      } else if dotnetRes.stdout.length == 0 and dotnetRes.exitCode == 0 {
        printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
        1
      } else {
        dotnetRes.exitCode
      }
    }
  }
}

// isCfgGatedOut and the directory-package assembly helpers moved to
// `Lyric.CfgGate` (#1123, #1124) so they're independently testable and
// the duplicate-`package`-declaration bug for multi-file directory
// packages is fixed at the assembly level.
// Resolve the output DLL path and package name for a local-path dependency
// from its lyric.toml path and target file extension.  Both the pre-build
// topo loop and the post-build resolve loop share this derivation.
record DepDllInfo {
  dllPath: String
  pkgName: String
}

func resolveDepDllPath(tomlPath: in String, ext: in String): Result[DepDllInfo, String] {
  val mfText = match File.readText(tomlPath) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = "cannot read manifest at '" + tomlPath + "': " + IOError.message(e))
  }
  val mf = match Mf.parseManifest(mfText, tomlPath) {
    case Ok(m) -> m
    case Err(e) -> return Err(error = "malformed lyric.toml at '" + tomlPath + "': " + ManifestError.message(e))
  }
  val pkgName = mf.packageSection.name
  val dllName = match mf.project {
    case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ext }
    case None -> pkgName + ext
  }
  val binDir = Path.join(Path.dirname(tomlPath), "bin")
  Ok(value = DepDllInfo(dllPath = Path.join(binDir, dllName), pkgName = pkgName))
}

func cmdTestManifest(mfPath: in String, filterArg: in Option[String], targetJvm: in Bool, failFast: in Bool): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("test: " + IOError.message(e))
      return 1
    }
  }
  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("test: " + ManifestError.message(e))
      return 1
    }
  }
  val proj: ProjectSection = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("test: " + mfPath + " has no [project] section")
      return 1
    }
  }

  val mfDir = Path.dirname(mfPath)

  if proj.tests.count == 0 {
    // Fallback: scan [project.packages] source paths for @test_module files and
    // run each as a single-file test.  Avoids requiring an explicit [project.tests]
    // entry when the test modules live beside their library packages.
    val scanPaths: List[String] = newList()
    var spi = 0
    while spi < proj.packages.count {
      val pkgEntry = proj.packages[spi]
      spi += 1
      val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
      if File.fileExists(abs) {
        scanPaths.add(abs)
      } else if File.dirExists(abs) {
        val allFiles = match File.listFilesRecursive(abs) { case Ok(fs) -> fs; case Err(_) -> newList() }
        for f in allFiles.toArray() {
          if Str.endsWith(f, ".l") {
            scanPaths.add(f)
          }
        }
      }
    }
    val testFiles: List[String] = newList()
    var si = 0
    while si < scanPaths.count {
      val sp = scanPaths[si]
      si += 1
      val src = match File.readText(sp) { case Ok(t) -> t; case Err(_) -> "" }
      if src.length > 0 {
        val srcLines = Str.split(src, "\n")
        var hasTestMod = false
        var li = 0
        while li < srcLines.length {
          if Str.startsWith(Str.trim(srcLines[li]), "@test_module") {
            hasTestMod = true
          }
          li += 1
        }
        if hasTestMod {
          testFiles.add(sp)
        }
      }
    }
    if testFiles.count == 0 {
      printErr("test: " + mfPath + " has no [project.tests] entries and no @test_module files found in [project.packages]")
      return 1
    }
    var anyFailed = false
    var ti = 0
    while ti < testFiles.count {
      val tPath = testFiles[ti]
      ti += 1
      Console.println("== test: " + tPath)
      val testArgv: List[String] = newList()
      testArgv.add("test")
      testArgv.add(tPath)
      match filterArg {
        case Some(f) -> {
          testArgv.add("--filter")
          testArgv.add(f)
        }
        case None -> ()
      }
      if targetJvm {
        testArgv.add("--target")
        testArgv.add("jvm")
      }
      val rc = cmdTest(testArgv.toArray())
      if rc != 0 {
        anyFailed = true
      }
      if failFast and anyFailed {
        Console.println("== test: stopped early (--fail-fast)")
        return 1
      }
    }
    if anyFailed {
      return 1
    }
    return 0
  }

  val testExt = if targetJvm { ".jar" } else { ".dll" }
  val testTarget: CompileTarget = if targetJvm { Jvm } else { Dotnet }

  // Resolve active feature set from manifest defaults (no CLI flags in the test runner).
  val mfDefaults = Mf.readFeatureDefaultsFromToml(mfText, mfPath)
  val mfDeclared = Mf.readFeatureDeclaredFromToml(mfText, mfPath)
  val activeFeatures: List[String] = newList()
  var afi = 0
  while afi < mfDefaults.count {
    activeFeatures.add(mfDefaults[afi])
    afi += 1
  }

  // Build ProjectPackage entries from [project.packages], matching buildProject.
  val libPkgs: List[ProjectPackage] = newList()
  var hadFatal = false
  var pi = 0
  while pi < proj.packages.count {
    val pkgEntry = proj.packages[pi]
    val abs = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(mfDir, pkgEntry.path) }
    val pkgSources: List[String] = newList()
    if File.fileExists(abs) {
      match File.readText(abs) {
        case Ok(t) -> {
          if CfgGate.isCfgGatedOut(t, activeFeatures) {
            // Package is gated by an inactive feature: substitute an empty stub
            // so that imports of this package from sibling packages resolve, while
            // the @cfg-gated items in those packages are properly elided.
            pkgSources.add(CfgGate.emptyPackageStub(pkgEntry.name))
          } else {
            pkgSources.add(t)
          }
        }
        case Err(e) -> {
          printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
          hadFatal = true
        }
      }
    } else if File.dirExists(abs) {
      val allFiles = match File.listFilesRecursive(abs) {
        case Ok(fs) -> fs
        case Err(e) -> {
          printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
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
        printErr("test: package '" + pkgEntry.name + "': no .l files found in " + abs)
        hadFatal = true
      } else {
        // Read every file first, then hand the (path, contents) list to
        // CfgGate so the assembly logic adds at most one empty-package
        // stub when every file is gated — preventing the duplicate-
        // `package` declaration bug from #1124 when two or more files
        // in a directory package are each gated out.
        val fileEntries: List[CfgGate.CfgGateFile] = newList()
        val sorted = sortFileList(lFiles)
        var readFailed = false
        for f in sorted {
          match File.readText(f) {
            case Ok(t) -> fileEntries.add(CfgGate.CfgGateFile(path = f, contents = t))
            case Err(e) -> {
              printErr("test: package '" + pkgEntry.name + "': " + IOError.message(e))
              hadFatal = true
              readFailed = true
            }
          }
        }
        // All-or-nothing assembly: a partial source list would confuse `@cfg`
        // detection (one missing file can flip the gated-out decision) and
        // produce a misleading downstream "unresolved import" cascade instead
        // of a clear "read failed" error.  `hadFatal` is already set; downstream
        // packages skip importing this one.
        if not readFailed {
          val assembly = CfgGate.assembleDirectoryPackageSources(fileEntries, pkgEntry.name, activeFeatures)
          var ai = 0
          while ai < assembly.sources.count {
            pkgSources.add(assembly.sources[ai])
            ai += 1
          }
        }
      }
    } else {
      printErr("test: package '" + pkgEntry.name + "': path not found: " + abs)
      hadFatal = true
    }
    if pkgSources.count > 0 {
      libPkgs.add(ProjectPackage(name = pkgEntry.name, sources = pkgSources))
    }
    pi += 1
  }

  if hadFatal {
    return 1
  }

  // Build workspace dependencies first, so their DLLs are available when building
  // path deps and test packages. This mirrors the integration in cli_build.l.
  val (wsDepDlls, wsHadError) = buildWorkspaceDeps(manifest, mfPath, testTarget)
  if wsHadError {
    return 1
  }

  // Build local-path dependencies in topological order (#2887).
  // Uses an iterative DFS post-order over the full transitive local-path-dep
  // closure so a dep's own local-path dependencies are always built before the
  // dep itself — even when the manifest order is not dependency-first and even
  // when transitive deps are not listed directly in this manifest.
  //
  // Stack entries are pairs stored as alternating elements with tomlPath on top:
  //   add("open"), add(tomlPath)   → tomlPath at count-1, "open" at count-2
  //   pop tomlPath, pop state
  val dfsSeen: List[String] = newList()
  val topoOrder: List[String] = newList()
  val dfsStack: List[String] = newList()

  // Seed the DFS with direct local-path deps (push in reverse for correct pop order).
  var seedIdx = manifest.deps.count - 1
  while seedIdx >= 0 {
    val seedDep = manifest.deps[seedIdx]
    match seedDep.source {
      case Path(seedDir) -> {
        val seedDepDir = if Path.isAbsolute(seedDir) { seedDir } else { Path.join(mfDir, seedDir) }
        dfsStack.add("open")
        dfsStack.add(Path.join(seedDepDir, "lyric.toml"))
      }
      case _ -> ()
    }
    seedIdx -= 1
  }

  while dfsStack.count > 0 {
    val dfsToml = dfsStack[dfsStack.count - 1]
    dfsStack.removeAt(dfsStack.count - 1)
    val dfsState = dfsStack[dfsStack.count - 1]
    dfsStack.removeAt(dfsStack.count - 1)

    if dfsState == "close" {
      topoOrder.add(dfsToml)
      continue
    }

    // "open": skip if already visited (handles diamond deps and back edges).
    // Deduplication uses raw string equality.  Paths are constructed by
    // Path.join against an absolute base directory (mfDir / dfsMfDir), so
    // any `../` segments are inherited from the manifest's `path =` value.
    // Two manifests that refer to the same dep at different relative paths
    // may produce syntactically-distinct strings for the same filesystem
    // entry and would be visited twice.  Path.normalize (which resolves
    // `../` without a syscall) does not yet exist in Std.Path; when it
    // lands, normalize dfsToml here before the seen-set check (#2916).
    var dfsAlreadySeen = false
    var dfsSeenIdx = 0
    while dfsSeenIdx < dfsSeen.count {
      if dfsSeen[dfsSeenIdx] == dfsToml {
        dfsAlreadySeen = true
      }
      dfsSeenIdx += 1
    }
    if dfsAlreadySeen {
      continue
    }
    dfsSeen.add(dfsToml)

    // Push close marker for this node (will fire after all children are processed).
    dfsStack.add("close")
    dfsStack.add(dfsToml)

    // Parse this dep's manifest to discover its own local-path deps,
    // pushing them as children (in reverse for correct DFS pop order).
    match File.readText(dfsToml) {
      case Ok(dfsText) -> {
        match Mf.parseManifest(dfsText, dfsToml) {
          case Ok(dfsMf) -> {
            val dfsMfDir = Path.dirname(dfsToml)
            var childIdx = dfsMf.deps.count - 1
            while childIdx >= 0 {
              val childDep = dfsMf.deps[childIdx]
              match childDep.source {
                case Path(childDir) -> {
                  val childDepDir = if Path.isAbsolute(childDir) { childDir } else { Path.join(dfsMfDir, childDir) }
                  dfsStack.add("open")
                  dfsStack.add(Path.join(childDepDir, "lyric.toml"))
                }
                case _ -> ()
              }
              childIdx -= 1
            }
          }
          case Err(e) -> {
            Console.println(
              "test: warning: cannot parse manifest at '" + dfsToml + "': " + ManifestError.message(e) +
                "; transitive deps may be missing from build order"
            )
          }
        }
      }
      case Err(e) -> {
        Console.println(
          "test: warning: cannot read manifest at '" + dfsToml + "': " + IOError.message(e) +
            "; transitive deps may be missing from build order"
        )
      }
    }
  }

  // Build each dep in topo order; skip those already built.
  var topoIdx = 0
  while topoIdx < topoOrder.count {
    val buildToml = topoOrder[topoIdx]
    match resolveDepDllPath(buildToml, testExt) {
      case Ok(info) -> {
        if not File.fileExists(info.dllPath) {
          Console.println("test: building dep '" + info.pkgName + "' ...")
          val buildRc = buildProject(buildToml, None, testTarget, newList(), false, false, false)
          if buildRc != 0 {
            printErr("test: failed to build dep '" + info.pkgName + "'")
            return 1
          }
        }
      }
      case Err(e) -> {
        printErr("test: " + e)
        return 1
      }
    }
    topoIdx += 1
  }

  // Resolve local-path dependencies to DLL paths, matching buildProject.
  // Also track unique dep bin directories so the test runtimeconfig can
  // include additionalProbingPaths — this lets dotnet exec locate stdlib
  // DLLs (e.g. Lyric.Stdlib.Testing) that live in the dep's bin dir but
  // are not merged into the main dep bundle (e.g. Lyric.Stdlib.dll).
  val restoredDlls: List[String] = newList()
  // Add workspace dependency DLLs first.
  var wi = 0
  while wi < wsDepDlls.count {
    restoredDlls.add(wsDepDlls[wi])
    wi += 1
  }
  val depBinDirs: List[String] = newList()
  val depTemplatePkgsList: List[ProjectPackage] = newList()
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Path(dir) -> {
        val depDir = if Path.isAbsolute(dir) { dir } else { Path.join(mfDir, dir) }
        val depToml = Path.join(depDir, "lyric.toml")
        if File.fileExists(depToml) {
          match resolveDepDllPath(depToml, testExt) {
            case Ok(info) -> {
              val depBinDir = Path.dirname(info.dllPath)
              if File.fileExists(info.dllPath) {
                restoredDlls.add(dep.name + "\t" + info.dllPath)
                // Collect unique dep bin directories for runtime probing.
                var alreadyHave = false
                var ddi = 0
                while ddi < depBinDirs.count {
                  if depBinDirs[ddi] == depBinDir {
                    alreadyHave = true
                  }
                  ddi += 1
                }
                if not alreadyHave {
                  depBinDirs.add(depBinDir)
                }
              } else {
                printErr("test: local dep '" + dep.name + "' could not be built")
                return 1
              }
            }
            case Err(e) -> {
              printErr("test: local dep '" + dep.name + "': " + e)
            }
          }
          // Collect source files from this path dep for cross-package aspect template
          // resolution (parity with cli_build.l; fixes lyric build vs lyric test --manifest
          // inconsistency where A0045 fired for aspects that built cleanly — #3649).
          match File.readText(depToml) {
            case Ok(depMfText) -> {
              match Mf.parseManifest(depMfText, depToml) {
                case Ok(depMf) -> {
                  match depMf.project {
                    case Some(depProj) -> {
                      var pki = 0
                      while pki < depProj.packages.count {
                        val pkgEntry = depProj.packages[pki]
                        val srcPath = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(depDir, pkgEntry.path) }
                        match File.readText(srcPath) {
                          case Ok(srcText) -> {
                            val srcList: List[String] = newList()
                            srcList.add(srcText)
                            depTemplatePkgsList.add(ProjectPackage(name = pkgEntry.name, sources = srcList))
                          }
                          case Err(e) -> {
                            printErr("test: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                          }
                        }
                        pki += 1
                      }
                    }
                    case None -> ()
                  }
                }
                case Err(_) -> ()
              }
            }
            case Err(_) -> ()
          }
        } else {
          printErr("test: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml + "'")
        }
      }
      case _ -> ()
    }
    di += 1
  }

  // Include the bootstrap CLI DLL directory in the runtime probing paths so
  // that host-shim DLLs compiled alongside it (e.g. Lyric.Session.Host.dll)
  // are locatable when the compiled test DLL runs via `dotnet exec`.
  // LYRIC_CLI_DLL is set by Program.fs when the CLI is a dotnet exec DLL
  // (the typical CI case); it is unset for native AOT binaries.
  val cliDll = Environment.getVarOrDefault("LYRIC_CLI_DLL", "")
  if cliDll.length > 0 {
    val cliDir = Path.dirname(cliDll)
    var haveCliDir = false
    var hdi = 0
    while hdi < depBinDirs.count {
      if depBinDirs[hdi] == cliDir {
        haveCliDir = true
      }
      hdi += 1
    }
    if not haveCliDir {
      depBinDirs.add(cliDir)
    }
  }

  val testOutDir = Path.join(mfDir, ".lyric-test")
  match File.createDir(testOutDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("test: cannot create '" + testOutDir + "': " + IOError.message(e))
      return 1
    }
  }

  var totalPassed = 0
  var totalFailed = 0

  var ti = 0
  while ti < proj.tests.count {
    val testEntry = proj.tests[ti]
    val abs = if Path.isAbsolute(testEntry.path) { testEntry.path } else { Path.join(mfDir, testEntry.path) }
    Console.println("== " + testEntry.name + " (" + testEntry.path + ")")

    val testSource = match File.readText(abs) {
      case Ok(t) -> t
      case Err(e) -> {
        printErr("test: " + IOError.message(e))
        totalFailed += 1
        ti += 1
        continue
      }
    }

    var synthFailed = false
    var rewritten = ""
    match TestSynth.synthesize(testSource, filterArg) {
      case Synthesised(rw, _, _) -> {
        rewritten = rw
      }
      case NoTestModule(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) + ": not a @test_module — add @test_module annotation")
        totalFailed += 1
        synthFailed = true
      }
      case UserMainExists(span) -> {
        printErr(abs + ":" + toString(span.startPos.line) + ": @test_module cannot define func main()")
        totalFailed += 1
        synthFailed = true
      }
      case ParseFailures(diags) -> {
        for d in diags.toArray() {
          printDiag(d)
        }
        totalFailed += 1
        synthFailed = true
      }
    }
    if synthFailed {
      ti += 1
      continue
    }

    // Compile the library packages together with the synthesised test package
    // via emitProject so each package declaration is a separate compilation
    // unit — concatenating sources into a single-file emit is invalid when
    // the project contains more than one `package` declaration.
    // Add the test package FIRST so its synthesized main() is recorded as the
    // entry point by the first-wins semantics in addPackageTokens (#2885).
    val allPkgs: List[ProjectPackage] = newList()
    val testSrcs: List[String] = newList()
    testSrcs.add(rewritten)
    allPkgs.add(ProjectPackage(name = testEntry.name, sources = testSrcs))
    var si = 0
    while si < libPkgs.count {
      allPkgs.add(libPkgs[si])
      si += 1
    }
    val asmStem = stemOf(Path.basename(testEntry.path), 2)
    val outPath = Path.join(testOutDir, asmStem + testExt)

    val projReq = EmitProjectRequest(
      packages = allPkgs,
      assemblyName = asmStem,
      outputPath = outPath,
      target = testTarget,
      restoredDllPaths = restoredDlls,
      activeFeatures = activeFeatures,
      declaredFeatures = mfDeclared,
      packageVersion = manifest.packageSection.version,
      depTemplateSrcs = depTemplatePkgsList
    )
    val result = Emitter.emitProject(projReq)
    var hadBuildError = false
    for d in result.diagnostics.toArray() {
      match d.severity {
        case DiagError -> {
          hadBuildError = true
        }
        case DiagWarning -> ()
      }
      printDiag(d)
    }
    if hadBuildError {
      printErr(abs + ": test build failed")
      totalFailed += 1
      ti += 1
      continue
    }
    // The self-hosted codegen references the stdlib under its split
    // per-package assembly names (`Lyric.Stdlib.Core`, `Lyric.Stdlib.Testing`,
    // …), but a manifest dependency build ships only the bundled
    // `Lyric.Stdlib.dll` in the dep's bin dir.  The split DLLs (and their host
    // shims + `FSharp.Core`) ship beside the running `lyric` binary
    // (`appBaseDirectory()` — the publish/SDK lib dir).  `additionalProbingPaths`
    // only resolves NuGet-structured layouts, not a flat lib dir, so co-locate
    // the referenced assemblies next to the test instead — mirroring the
    // single-file `cmdTest` path.  Without this `dotnet exec` fails with
    // `Could not load file or assembly 'Lyric.Stdlib.Core'` (#1468 / #1841).
    val testExitCode = if targetJvm {
      // JVM: bundled JAR is self-contained; skip .NET-specific runtime staging.
      val jvmArgs: List[String] = newList()
      jvmArgs.add("-jar")
      jvmArgs.add(outPath)
      val jvmRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("java", jvmArgs, "", 600000)
      Console.print(jvmRes.stdout)
      if jvmRes.stderr.length > 0 {
        Console.error(jvmRes.stderr)
      }
      if jvmRes.exitCode == -1 {
        printErr("test: failed to start java")
        1
      } else if jvmRes.timedOut {
        printErr("test: test binary timed out (600 s limit reached)")
        1
      } else if jvmRes.stdout.length == 0 and jvmRes.exitCode == 0 {
        printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
        1
      } else {
        jvmRes.exitCode
      }
    } else {
      copyRuntimeDepsBeside(outPath, Environment.appBaseDirectory(), pathListHasCompilerDll(restoredDlls))
      // Co-locate each local-path dependency's output DLL (e.g. a sibling
      // package's `Cache.dll`) beside the test assembly — a flat probing path
      // can't resolve the dep's non-NuGet bin layout.  This subsumes the manual
      // dep-DLL copy the CI ecosystem step used to do by hand.
      copyRestoredDepDlls(outPath, restoredDlls)
      writeRuntimeConfigWithProbing(outPath, depBinDirs)

      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      val mfDotnetRes = ProcessCapture.runCaptureWithDiagnosticsTimeout("dotnet", execArgs, "", 600000)
      Console.print(mfDotnetRes.stdout)
      if mfDotnetRes.stderr.length > 0 {
        Console.error(mfDotnetRes.stderr)
      }
      if mfDotnetRes.exitCode == -1 {
        printErr("test: failed to start dotnet")
        1
      } else if mfDotnetRes.timedOut {
        printErr("test: test binary timed out (600 s limit reached)")
        1
      } else if mfDotnetRes.stdout.length == 0 and mfDotnetRes.exitCode == 0 {
        printErr("test: compiled test binary produced no TAP output — possible silent compile or runtime failure")
        1
      } else {
        mfDotnetRes.exitCode
      }
    }
    if testExitCode == 0 {
      totalPassed += 1
    } else {
      totalFailed += 1
    }
    if failFast and totalFailed > 0 {
      Console.println("")
      Console.println(
        "== summary: " + toString(totalPassed) + " passed, " + toString(totalFailed) + " failed (stopped early)"
      )
      return 1
    }
    ti += 1
  }

  Console.println("")
  Console.println("== summary: " + toString(totalPassed) + " passed, " + toString(totalFailed) + " failed")
  if totalFailed > 0 {
    1
  } else {
    0
  }
}
