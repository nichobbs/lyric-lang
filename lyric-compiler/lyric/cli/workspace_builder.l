//! cli/workspace_builder.l — Build transitive workspace dependencies.
//!
//! When a project in a workspace declares a { workspace = true } dependency,
//! this module:
//! 1. Discovers the workspace root if it exists
//! 2. Resolves the dependency name to its directory
//! 3. Builds the dependency if its DLL is missing or stale
//! 4. Returns the built DLL path, plus the paths of all transitive deps
//!
//! collectTransitiveDepDlls walks a package's dependency tree and adds all
//! reachable dep DLL paths to a result list.  This ensures that synthesis
//! preambles include type declarations from transitive dependencies, fixing
//! T0010 errors on cross-DLL types in restored-package synthesis (issue #4517).
package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.Environment as Environment
import Std.Errors
import Lyric.Manifest as Mf
import Lyric.Workspace as Ws
import Lyric.Release as Release
import Lyric.Emitter as Emitter

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public API
// ─────────────────────────────────────────────────────────────────────────────
/// Resolve all { workspace = true } dependencies in a manifest, building them
/// as needed.  Returns (dllPaths, buildErrors, wsCtxOpt).
/// dllPaths is a list of "name\tdllPath" strings for all direct AND transitive
/// deps; buildErrors is True if any direct dep build failed; wsCtxOpt is the
/// discovered workspace context (None when not in a workspace).
pub func buildWorkspaceDeps(
  manifest: in Mf.Manifest, mfPath: in String, target: in Emitter.CompileTarget
): (List[String], Bool, Option[Ws.WorkspaceContext]) {
  val result: List[String] = newList()
  var hadError = false

  // Find the workspace root. If we're not in a workspace, return empty.
  val wsCtxOpt = Ws.findWorkspaceRoot(Path.dirname(mfPath))
  val wsCtx = match wsCtxOpt {
    case Some(ctx) -> ctx
    case None -> {
      // No workspace found; workspace dependencies cannot be resolved.
      // Return the already-typed wsCtxOpt, not a fresh None (#4925).
      return (result, false, wsCtxOpt)
    }
  }

  val buildStack: List[String] = newList()
  val seen: List[String] = newList()
  val mfDir = Path.dirname(mfPath)
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Mf.DepSource.Workspace(versionOpt) -> {
        // Resolve the dependency name to its directory within the workspace.
        match Ws.resolveDep(dep.name, wsCtx) {
          case Some(depDir) -> {
            val buildResult = buildWorkspaceDep(dep.name, depDir, target, versionOpt, buildStack)
            match buildResult {
              case Ok(dllPath) -> {
                if not stringListContains(seen, dep.name) {
                  result.add(dep.name + "\t" + dllPath)
                  seen.add(dep.name)
                  collectTransitiveDepDlls(depDir, wsCtxOpt, seen, result)
                }
              }
              case Err(msg) -> {
                printErr("build: workspace dep '" + dep.name + "': " + msg)
                hadError = true
              }
            }
          }
          case None -> {
            printErr("build: workspace dep '" + dep.name + "' not found; check workspace root and member list")
            hadError = true
          }
        }
      }
      case _ -> ()
    }
    di += 1
  };

  (result, hadError, wsCtxOpt)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Private helpers
// ─────────────────────────────────────────────────────────────────────────────
func stringListContains(list: in List[String], s: in String): Bool {
  var i = 0
  while i < list.count {
    if list[i] == s {
      return true
    }
    i += 1
  }
  false
}

/// Read `tDepDir`'s manifest, infer its DLL's expected output path, and — if
/// that DLL already exists on disk — record `depName -> tDllPath` in
/// `result`/`seen` and recurse into `tDepDir`'s own transitive deps.  Shared
/// by both match arms of `collectTransitiveDepDlls` below: a `Workspace` dep
/// and a `Path` dep differ only in how `tDepDir` is derived, everything after
/// that (read manifest, infer DLL name, check existence, record, recurse) was
/// duplicated between the two arms before this was extracted (#4521).
func addTransitiveDepFromDir(
  tDepDir: in String,
  depName: in String,
  wsCtxOpt: in Option[Ws.WorkspaceContext],
  seen: in List[String],
  result: in List[String],
): Unit {
  val tToml = Path.join(tDepDir, "lyric.toml")
  if File.fileExists(tToml) {
    match File.readText(tToml) {
      case Err(_) -> ()
      case Ok(tMfText) -> {
        match Mf.parseManifest(tMfText, tToml) {
          case Err(_) -> ()
          case Ok(tMf) -> {
            val dllName = match tMf.project {
              case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
              case None -> tMf.packageSection.name + ".dll"
            }
            val tDllPath = Path.join(Path.join(tDepDir, "bin"), dllName)
            if File.fileExists(tDllPath) {
              result.add(depName + "\t" + tDllPath)
              seen.add(depName)
              collectTransitiveDepDlls(tDepDir, wsCtxOpt, seen, result)
            }
          }
        }
      }
    }
  }
}

/// Walk the dependency tree of the package at depDir, adding all transitive
/// dep DLL paths to result.  seen tracks dep names already added to prevent
/// duplicates and cycles.  wsCtxOpt resolves workspace-form deps.
/// Does not build anything — only traverses already-built packages.
pub func collectTransitiveDepDlls(
  depDir: in String,
  wsCtxOpt: in Option[Ws.WorkspaceContext],
  seen: in List[String],
  result: in List[String],
): Unit {
  val tomlPath = Path.join(depDir, "lyric.toml")
  if not File.fileExists(tomlPath) {
    return
  }
  match File.readText(tomlPath) {
    case Err(_) -> ()
    case Ok(mfText) -> {
      match Mf.parseManifest(mfText, tomlPath) {
        case Err(_) -> ()
        case Ok(mf) -> {
          var ti = 0
          while ti < mf.deps.count {
            val tdep = mf.deps[ti]
            if not stringListContains(seen, tdep.name) {
              match tdep.source {
                case Mf.DepSource.Workspace(_) -> {
                  match wsCtxOpt {
                    case None -> ()
                    case Some(wsCtx) -> {
                      match Ws.resolveDep(tdep.name, wsCtx) {
                        case None -> ()
                        case Some(tDepDir) -> addTransitiveDepFromDir(tDepDir, tdep.name, wsCtxOpt, seen, result)
                      }
                    }
                  }
                }
                case Mf.DepSource.Path(dir) -> {
                  val tDepDir = if Path.isAbsolute(dir) { dir } else { Path.join(depDir, dir) }
                  addTransitiveDepFromDir(tDepDir, tdep.name, wsCtxOpt, seen, result)
                }
                case _ -> ()
              }
            }
            ti += 1
          }
        }
      }
    }
  }
}

/// Build a single workspace dependency and return its DLL path.
/// Returns Err(error) on any failure.
/// buildStack tracks the dependency chain to detect circular dependencies.
/// versionConstraint (if Some) is checked against the actual package version.
func buildWorkspaceDep(
  depName: in String,
  depDir: in String,
  target: in Emitter.CompileTarget,
  versionConstraint: in Option[String],
  buildStack: in List[String],
): Result[String, String] {
  // Check for circular dependencies: is depName already being built?
  var isCycle = false
  var ci = 0
  while ci < buildStack.count {
    if buildStack[ci] == depName {
      isCycle = true
    }
    ci += 1
  }
  if isCycle {
    return Err(error = "circular dependency detected: " + depName + " is already being built")
  }

  val depToml = Path.join(depDir, "lyric.toml")

  // Check that the manifest exists.
  if not File.fileExists(depToml) {
    return Err(error = "no lyric.toml found at " + depToml)
  }

  val depMfText = match File.readText(depToml) {
    case Err(e) -> return Err(error = "cannot read " + depToml + ": " + IOError.message(e))
    case Ok(text) -> text
  }

  val depMf = match Mf.parseManifest(depMfText, depToml) {
    case Err(e) -> return Err(error = "malformed lyric.toml: " + ManifestError.message(e))
    case Ok(m) -> m
  }

  // Validate version constraint if specified.
  match versionConstraint {
    case Some(expectedVersion) -> {
      val actualVersion = depMf.packageSection.version
      if actualVersion != expectedVersion {
        return Err(error = "version mismatch: expected " + expectedVersion + ", found " + actualVersion)
      }
    }
    case None -> ()
  }

  // Determine the DLL filename and path.
  val dllName: String = match depMf.project {
    case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
    case None -> depMf.packageSection.name + ".dll"
  }
  val depBinDir = Path.join(depDir, "bin")
  val dllPath = Path.join(depBinDir, dllName)

  // Check if DLL exists and is up-to-date (not stale).
  val dllExists = File.fileExists(dllPath)
  if dllExists {
    val dllIsStale = checkDllIsStale(dllPath, depToml, depDir)
    if not dllIsStale {
      return Ok(value = dllPath)
    }
  }

  // The DLL is missing or stale. Recursively build this dependency and any of
  // its transitive dependencies. Add depName to the build stack to detect cycles.
  buildStack.add(depName)
  Console.println("build: building workspace dep '" + depName + "' (" + depDir + ") ...")

  val buildExit = buildProject(
    depToml,
    None,
    // use the manifest's default output location
    target,
    newList(),
    // no CLI features
    false,
    // use defaults
    false,
    // no --all-features
    false,
    // allow restore
    // packageVersionOverride: always None here, intentionally — a workspace
    // dep built transitively is a standalone artifact resolved from its own
    // lyric.toml (its version comes from [package].version, not from
    // whatever --package-version the top-level build was invoked with).
    // Every current caller of buildWorkspaceDeps (the publish pipeline)
    // pre-builds each tier's DLL before the next tier runs, so this dep is
    // already on disk with its own manifest version by the time it would be
    // consulted here. Passing the top-level override through would only
    // matter for the out-of-workflow case of a clean-tree `lyric build
    // --package-version X` that also needs to rebuild a stale workspace dep
    // (#4428) — not a regression, since that was always the emitted-version
    // behaviour before --package-version existed.
    None
  )

  buildStack.removeAt(buildStack.count - 1)

  if buildExit != 0 {
    return Err(error = "build failed (exit code " + toString(buildExit) + ")")
  }

  // After a successful build, the DLL should exist.
  if File.fileExists(dllPath) {
    Ok(value = dllPath)
  } else {
    Err(error = "build succeeded but DLL not found at " + dllPath)
  }
}

/// Check if a DLL is stale by comparing its modification time to source files.
/// Returns true if the DLL is older than the manifest or any source files.
func checkDllIsStale(dllPath: in String, manifestPath: in String, sourceDir: in String): Bool {
  // Check if DLL exists.
  if not File.fileExists(dllPath) {
    return true
  }

  // Try to get DLL and manifest modification times.
  val dllStatRes = File.stat(dllPath)
  val manifestStatRes = File.stat(manifestPath)
  val filesRes = File.listFilesRecursive(sourceDir)

  // Check DLL stat for errors.
  match dllStatRes {
    case Err(e) -> return true
    case Ok(dllStat) -> {
      // Check manifest stat for errors.
      match manifestStatRes {
        case Err(e) -> return true
        case Ok(manifestStat) -> {
          // If manifest is newer than DLL, it's stale.
          if File.fileStatIsNewer(manifestStat, dllStat) {
            return true
          }

          // Check if any .l source files are newer than the DLL.
          match filesRes {
            case Err(e) -> return true
            case Ok(files) -> {
              for f in files.toArray() {
                if Str.endsWith(f, ".l") {
                  val fstatRes = File.stat(f)
                  match fstatRes {
                    case Err(e) -> return true
                    case Ok(fstat) -> {
                      if File.fileStatIsNewer(fstat, dllStat) {
                        return true
                      }
                    }
                  }
                }
              }
              false
            }
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Shared manifest dependency/feature resolution (D123)
// ─────────────────────────────────────────────────────────────────────────────
// The following three groups back BOTH `buildProject`'s `[project.packages]`
// compiles and `buildOneNative`'s single-file synthetic one-package request
// (`cli_build.l::emitSingleFileOrProject`), so a bare `.l` file sitting near a
// lyric.toml resolves dependencies/features/Maven classpath identically to a
// project build of the same manifest, instead of maintaining two copies of
// this logic.
/// Resolve a manifest's active/declared feature sets for `@cfg` erasure:
/// the manifest's `[features].default` set unless `--no-default-features`,
/// `--all-features` selecting every declared feature, else CLI `--features`
/// layered on top of the defaults.  Single-file builds have no
/// `--features`/`--no-default-features`/`--all-features` CLI flags of their
/// own, so their caller always passes an empty `cliFeatures` and
/// `false`/`false`, which resolves to exactly the manifest's own defaults.
pub func resolveManifestFeatures(
  mfText: in String,
  mfPath: in String,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
): (List[String], List[String]) {
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
  };
  (activeFeatures, mfDeclared)
}

/// Aggregated result of `resolveManifestDependencies`.
pub record ResolvedManifestDeps {
  /// "depName\tdllPath" entries, appendable directly to
  /// `EmitProjectRequest.restoredDllPaths`.
  restoredDlls: List[String]
  /// Source packages from path dependencies, for cross-package aspect
  /// template resolution (#3498) — appendable directly to
  /// `EmitProjectRequest.depTemplateSrcs`.
  depTemplateSrcs: List[ProjectPackage]
  /// Genuine third-party NuGet assembly paths (not Lyric packages) —
  /// appendable directly to `EmitProjectRequest.nugetAssemblyPaths`.
  nugetThirdPartyPaths: List[String]
  /// True when a `{ workspace = true }` dependency failed to build.
  /// `buildProject` has always treated this as an immediate `return 1`
  /// (mirrors `buildWorkspaceDeps`'s own fatal signal); callers that want
  /// the same behavior should check this first.
  hadWorkspaceError: Bool
  /// True when a local `path = "..."` dependency could not be resolved to a
  /// usable DLL for any reason: its DLL was not found on disk (not yet
  /// built), the dependency directory has no `lyric.toml` at all, its
  /// `lyric.toml` could not be read, or its `lyric.toml` failed to parse.
  /// `buildProject` has historically treated this as a non-fatal warning
  /// (the downstream typecheck surfaces the real error); `buildOneNative`'s
  /// single-file synthetic project request treats it as fatal per D123's
  /// "fail loud instead of silently degrading" conservative default.
  hadUnbuiltLocalDep: Bool
}

/// Resolve every dependency a manifest declares — workspace deps (built
/// recursively via `buildWorkspaceDeps`), local `path = "..."` deps, and
/// `[nuget]` assets that are themselves Lyric packages — into the
/// `restoredDllPaths` / `nugetAssemblyPaths` / `depTemplateSrcs` shape
/// `Emitter.EmitProjectRequest` expects.  Does NOT resolve feature sets (see
/// `resolveManifestFeatures`) or `[maven]` classpath injection (see
/// `injectMavenClasspathForJvm`) — those are independent concerns with
/// their own callers.  Never triggers a restore: a dependency that isn't
/// already built is reported via `hadUnbuiltLocalDep` / the printed
/// message, not fetched.
pub func resolveManifestDependencies(
  manifest: in Manifest, mfPath: in String, target: in Emitter.CompileTarget
): ResolvedManifestDeps {
  val mfDir = Path.dirname(mfPath)
  val restoredDlls: List[String] = newList()
  val depTemplatePkgsList: List[ProjectPackage] = newList()
  val seenDeps: List[String] = newList()
  var hadUnbuiltLocalDep = false

  val (wsDepDlls, wsHadError, wsCtxOpt) = buildWorkspaceDeps(manifest, mfPath, target)
  if wsHadError {
    return ResolvedManifestDeps(
      restoredDlls = restoredDlls,
      depTemplateSrcs = depTemplatePkgsList,
      nugetThirdPartyPaths = newList(),
      hadWorkspaceError = true,
      hadUnbuiltLocalDep = false
    )
  }
  var wdi = 0
  while wdi < wsDepDlls.count {
    val wsEntry = wsDepDlls[wdi]
    restoredDlls.add(wsEntry)
    val wsTab = wsEntry.indexOf("\t")
    val wsName = if wsTab >= 0 { wsEntry.substring(0, wsTab) } else { wsEntry }
    seenDeps.add(wsName)
    wdi += 1
  }

  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Mf.DepSource.Path(dir) -> {
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
                    if not stringListContains(seenDeps, dep.name) {
                      restoredDlls.add(dep.name + "\t" + dllPath)
                      seenDeps.add(dep.name)
                      collectTransitiveDepDlls(depDir, wsCtxOpt, seenDeps, restoredDlls)
                    }
                  } else {
                    printErr("build: " + Release.localDepNotBuiltMessage(dep.name, dllPath, depToml))
                    hadUnbuiltLocalDep = true
                  }
                  // Collect source files from this path dependency so the weaver can
                  // resolve cross-package `from`-instance aspect templates (#3498).
                  match depMf.project {
                    case Some(proj) -> {
                      var pki = 0
                      while pki < proj.packages.count {
                        val pkgEntry = proj.packages[pki]
                        val srcList: List[String] = newList()
                        if pkgEntry.paths.count > 0 {
                          var fi = 0
                          while fi < pkgEntry.paths.count {
                            val srcPath = Path.join(depDir, pkgEntry.paths[fi])
                            match File.readText(srcPath) {
                              case Ok(srcText) -> srcList.add(srcText)
                              case Err(e) -> {
                                printErr("build: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                              }
                            }
                            fi += 1
                          }
                        } else {
                          val srcPath = Path.join(depDir, pkgEntry.path)
                          match File.readText(srcPath) {
                            case Ok(srcText) -> srcList.add(srcText)
                            case Err(e) -> {
                              printErr("build: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                            }
                          }
                        }
                        if srcList.count > 0 {
                          depTemplatePkgsList.add(ProjectPackage(name = pkgEntry.name, sources = srcList))
                        }
                        pki += 1
                      }
                    }
                    case None -> ()
                  }
                }
                case Err(e) -> {
                  printErr("build: local dep '" + dep.name + "': malformed lyric.toml: " + ManifestError.message(e))
                  hadUnbuiltLocalDep = true
                }
              }
            }
            case Err(e) -> {
              printErr("build: local dep '" + dep.name + "': cannot read " + depToml + ": " + IOError.message(e))
              hadUnbuiltLocalDep = true
            }
          }
        } else {
          printErr(
            "build: local dep '" + dep.name + "' — no lyric.toml found at '" + depToml +
              "'; check the path = \"...\" entry in your lyric.toml"
          )
          hadUnbuiltLocalDep = true
        }
      }
      case Mf.DepSource.Workspace(_) -> ()
      case _ -> ()
    }
    di += 1
  }

  val nugetPaths = resolveNugetAssets(mfDir)
  warnIfNugetUnresolved(mfDir, manifest.nuget, nugetPaths)
  val (nugetLyricEntries, nugetThirdPartyPaths) = partitionNugetLyricDeps(nugetPaths)
  var nli = 0
  while nli < nugetLyricEntries.count {
    restoredDlls.add(nugetLyricEntries[nli])
    nli += 1
  }

  ResolvedManifestDeps(
    restoredDlls = restoredDlls,
    depTemplateSrcs = depTemplatePkgsList,
    nugetThirdPartyPaths = nugetThirdPartyPaths,
    hadWorkspaceError = false,
    hadUnbuiltLocalDep = hadUnbuiltLocalDep
  )
}

/// Result of `injectMavenClasspathForJvm`: the previous `LYRIC_FFI_JARS`
/// value (restore via `restoreMavenClasspath` once the compile finishes;
/// `None` when nothing was injected) alongside the colon-joined classpath
/// string (`buildProject` reuses this to write `bin/module-path.txt`).
pub record MavenClasspathInjection {
  savedFfiJars: Option[String]
  classpathColonSep: String
}

/// For a JVM build, read the manifest's resolved Maven classpath
/// (`target/restore/jvm-classpath.txt`, written by `lyric restore`) and
/// inject it into `LYRIC_FFI_JARS` so the JVM auto-FFI resolver can locate
/// downloaded Maven JARs at compile time.  A missing classpath file is a
/// non-fatal warning when the manifest actually declares `[maven]` entries
/// (mirroring the historical `buildProject` behavior — an unrestored Maven
/// dependency surfaces as a normal downstream typecheck/link error, not a
/// hard stop here) and silent when it doesn't.
pub func injectMavenClasspathForJvm(mfDir: in String, manifest: in Manifest): MavenClasspathInjection {
  var mavenJarColonSep = ""
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
  var savedFfiJars: Option[String] = None
  if mavenJarColonSep.length > 0 {
    val prevFfi = match Environment.getVar("LYRIC_FFI_JARS") { case Ok(v) -> v; case Err(_) -> "" }
    savedFfiJars = Some(value = prevFfi)
    val injected = if prevFfi.length > 0 { prevFfi + ":" + mavenJarColonSep } else { mavenJarColonSep }
    Environment.setVar("LYRIC_FFI_JARS", injected)
  }
  MavenClasspathInjection(savedFfiJars = savedFfiJars, classpathColonSep = mavenJarColonSep)
}

/// Restore `LYRIC_FFI_JARS` to the value `injectMavenClasspathForJvm`
/// captured, undoing its injection once a compile finishes.  A no-op when
/// nothing was injected (`None`).
pub func restoreMavenClasspath(saved: in Option[String]): Unit {
  match saved {
    case Some(prev) -> Environment.setVar("LYRIC_FFI_JARS", prev)
    case None -> ()
  }
}
