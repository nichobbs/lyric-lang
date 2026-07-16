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
///
/// `cliFeatures` / `noDefaultFeatures` are the ROOT build's explicit CLI
/// feature selection (`--features` / `--no-default-features`), forwarded
/// verbatim into every workspace dependency's own build (#5571).  Each
/// dependency then resolves its feature set exactly the way the root
/// package does: its own `[features].default` (unless the root passed
/// `--no-default-features`) plus the root's explicit `--features`, followed
/// by `resolveManifestFeatures`'s target normalization against the
/// dependency's own declared table — so a `--target jvm` build selects a
/// `default = ["dotnet"]` dependency's `@cfg(feature = "jvm")` kernel
/// instead of compiling the .NET kernel into JVM bytecode.  Before this,
/// the CONSUMER's fully-resolved active set was forced onto dependencies
/// (and the single-file build path dropped CLI feature flags entirely), so
/// the root manifest's `default = ["dotnet"]` leaked into every dependency
/// of a `--target jvm` build regardless of `--features`.
///
/// `--all-features` is deliberately NOT forwarded: its meaning — "every
/// feature THIS manifest declares" — is root-manifest-scoped and would
/// activate mutually-exclusive platform kernels in dependencies whose
/// feature tables the root knows nothing about.
pub func buildWorkspaceDeps(
  manifest: in Mf.Manifest,
  mfPath: in String,
  target: in Emitter.CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
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

  // The JVM bundled compile consumes cross-package code from SOURCE
  // (`depTemplateSrcs` + the stdlib-closure bundling model);
  // `emitProjectJvmInProcess` never reads `restoredDllPaths`.  Building
  // workspace dep DLLs for a `--target jvm` consumer is therefore pure
  // waste — and actively harmful: the dep's `[project].output_assembly`
  // names a `.dll`, so the JVM dep build wrote a JAR to `bin/<name>.dll`,
  // which the next `--target dotnet` build of any consumer then failed to
  // load as a restored dep ("no Lyric.Contract resource") until the file
  // was deleted by hand (#5571).
  match target {
    case Jvm -> {
      return (result, false, wsCtxOpt)
    }
    case _ -> ()
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
            val buildResult = buildWorkspaceDep(dep.name, depDir, target, cliFeatures, noDefaultFeatures, versionOpt, buildStack)
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
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
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

  // The dependency resolves features the same way the root does: its own
  // `[features].default` (unless the root's `--no-default-features`), plus
  // the root's explicit `--features`, then `resolveManifestFeatures`'s
  // target normalization against the dependency's OWN declared table
  // (#5571).  The root's resolved active set is deliberately not forced
  // through: it carries the root manifest's defaults (e.g. lyric-web's
  // `default = ["dotnet"]`), which are that manifest's choice, not a user
  // selection, and forcing them made every `--target jvm` build compile
  // dependencies' .NET kernels into JVM bytecode.
  val buildExit = buildProject(
    depToml,
    None,
    // use the manifest's default output location
    target,
    cliFeatures,
    noDefaultFeatures,
    // no --all-features
    false,
    // allow restore
    false,
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
    None,
    // preResolvedDeps: this dep's own manifest hasn't been resolved yet by
    // this call site, so let buildProject resolve it internally as before.
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
/// The plain feature name conventionally paired with a compile target by
/// the ecosystem's `[features]` tables (`default = ["dotnet"]`, `dotnet =
/// []`, `jvm = []`): every platform-split library gates its kernels on
/// `@cfg(feature = "dotnet")` / `@cfg(feature = "jvm")`.  Distinct from
/// the D-N-013 `target.<name>` pseudo-feature (which backs `@cfg(target =
/// "X")` and is injected by each backend bridge, never declared in a
/// manifest).
pub func targetFeatureName(target: in Emitter.CompileTarget): String {
  // var-mutation shape (stage-0 value-position-match lowering gap, #4631;
  // see cli_run.l's runTarget note).
  var name = "dotnet"
  match target {
    case Jvm -> {
      name = "jvm"
    }
    case Native -> {
      name = "native"
    }
    case Dotnet -> ()
  }
  name
}

func isTargetFeatureName(name: in String): Bool {
  name == "dotnet" or name == "jvm" or name == "native"
}

/// Resolve a manifest's active/declared feature sets for `@cfg` erasure:
/// the manifest's `[features].default` set unless `--no-default-features`,
/// `--all-features` selecting every declared feature, else CLI `--features`
/// layered on top of the defaults.
///
/// The composed set is then TARGET-NORMALIZED (#5571): features named
/// after a NON-active target (`dotnet` / `jvm` / `native`) are deactivated
/// unless the user asked for them explicitly (via `--features` or
/// `--all-features`), and — only when such a mismatched platform default
/// was removed — the active target's own feature name is swapped in if the
/// manifest declares it.  Without this, every platform-split manifest
/// (`default = ["dotnet"]`, kernels gated on `@cfg(feature = "dotnet")` /
/// `@cfg(feature = "jvm")`) compiled its .NET kernel into `--target jvm`
/// builds unless the caller remembered to pass `--no-default-features
/// --features jvm` on every invocation.
///
/// The swap fires ONLY on a removed mismatch — a target-named feature is
/// never introduced into a composed set that contained none.  A manifest
/// with an empty default set is a deliberate opt-out, not an omission:
/// lyric-session documents that defaulting either target feature on would
/// make every transitive build compile a kernel with a mandatory
/// NuGet/Maven dependency the builder may not have restored.  Manifests
/// that declare no target-named features at all are likewise unaffected in
/// both directions.
pub func resolveManifestFeatures(
  mfText: in String,
  mfPath: in String,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
  allFeatures: in Bool,
  target: in Emitter.CompileTarget,
): (List[String], List[String]) {
  val mfDefaults = Mf.readFeatureDefaultsFromToml(mfText, mfPath)
  val mfDeclared = Mf.readFeatureDeclaredFromToml(mfText, mfPath)
  val composed: List[String] = newList()
  if allFeatures {
    var ai = 0
    while ai < mfDeclared.count {
      composed.add(mfDeclared[ai])
      ai += 1
    }
  } else {
    if not noDefaultFeatures {
      var ai = 0
      while ai < mfDefaults.count {
        composed.add(mfDefaults[ai])
        ai += 1
      }
    }
    var ci = 0
    while ci < cliFeatures.count {
      composed.add(cliFeatures[ci])
      ci += 1
    }
  }

  val tName = targetFeatureName(target)
  val activeFeatures: List[String] = newList()
  var removedMismatch = false
  var fi = 0
  while fi < composed.count {
    val f = composed[fi]
    val explicitlyRequested = allFeatures or stringListContains(cliFeatures, f)
    if isTargetFeatureName(f) and f != tName and not explicitlyRequested {
      removedMismatch = true
    } else {
      if not stringListContains(activeFeatures, f) {
        activeFeatures.add(f)
      }
    }
    fi += 1
  }
  if removedMismatch and stringListContains(mfDeclared, tName) and not stringListContains(activeFeatures, tName) {
    activeFeatures.add(tName)
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
  /// NuGet-restored native runtime assets for the current host RID (e.g.
  /// `runtimes/linux-x64/native/libe_sqlite3.so`) — co-located beside the
  /// build output by `copyNugetNativeAssetsBeside` so a package like
  /// `SQLitePCLRaw.provider.e_sqlite3` actually loads at runtime (#5573).
  nativeAssetPaths: List[String]
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
/// `Emitter.EmitProjectRequest` expects.  `cliFeatures` /
/// `noDefaultFeatures` (the root build's explicit CLI feature selection)
/// are forwarded into every workspace dependency's build — see
/// `buildWorkspaceDeps`'s doc comment for the composition rule (#5571).
/// Does NOT itself resolve feature sets (see `resolveManifestFeatures`) or
/// `[maven]` classpath injection (see `injectMavenClasspathForJvm`) —
/// those are independent concerns with their own callers.  Never triggers
/// a restore: a dependency that isn't already built is reported via
/// `hadUnbuiltLocalDep` / the printed message, not fetched.
pub func resolveManifestDependencies(
  manifest: in Manifest,
  mfPath: in String,
  target: in Emitter.CompileTarget,
  cliFeatures: in List[String],
  noDefaultFeatures: in Bool,
): ResolvedManifestDeps {
  val mfDir = Path.dirname(mfPath)
  val restoredDlls: List[String] = newList()
  val depTemplatePkgsList: List[ProjectPackage] = newList()
  val seenDeps: List[String] = newList()
  var hadUnbuiltLocalDep = false

  val (wsDepDlls, wsHadError, wsCtxOpt) = buildWorkspaceDeps(manifest, mfPath, target, cliFeatures, noDefaultFeatures)
  if wsHadError {
    return ResolvedManifestDeps(
      restoredDlls = restoredDlls,
      depTemplateSrcs = depTemplatePkgsList,
      nugetThirdPartyPaths = newList(),
      nativeAssetPaths = newList(),
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

  val allNugetAssets = resolveAllNugetAssets(mfDir)
  val nugetPaths = allNugetAssets.dllPaths
  warnIfNugetUnresolved(mfDir, manifest.nuget, nugetPaths)
  val (nugetLyricEntries, nugetThirdPartyPaths) = partitionNugetLyricDeps(nugetPaths)
  for entry in nugetLyricEntries {
    restoredDlls.add(entry)
  }
  val nativeAssetPaths = allNugetAssets.nativePaths

  ResolvedManifestDeps(
    restoredDlls = restoredDlls,
    depTemplateSrcs = depTemplatePkgsList,
    nugetThirdPartyPaths = nugetThirdPartyPaths,
    nativeAssetPaths = nativeAssetPaths,
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
