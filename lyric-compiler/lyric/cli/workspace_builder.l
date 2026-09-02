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
  // (`depTemplateSrcs` + the stdlib-closure bundling model); nothing this
  // function returns for a workspace dep ever reaches
  // `EmitProjectRequest.restoredDllPaths` on Jvm (#6697 closed the one
  // caller — `resolveManifestDependencies`'s Path/NuGet branches — that
  // used to leak an existing `.dll` in there anyway). Building workspace
  // dep DLLs for a `--target jvm` consumer is therefore pure waste — and
  // actively harmful: the dep's `[project].output_assembly` names a `.dll`,
  // so the JVM dep build wrote a JAR to `bin/<name>.dll`, which the next
  // `--target dotnet` build of any consumer then failed to load as a
  // restored dep ("no Lyric.Contract resource") until the file was deleted
  // by hand (#5571).
  //
  // `--target native` has no restored-binary concept at all (#6809/#6818's
  // decision-log entry) — `Emitter.emitNativeProject` never consumes
  // `restoredDlls`/`depTemplateSrcs` either, so a workspace dep built here
  // for a native consumer is the same pure-waste JVM case, PLUS a real
  // crash risk: `buildWorkspaceDep` drives a genuine native compile of the
  // dependency's own source, and any not-yet-lowered construct in it
  // surfaces as an unhandled CLI panic rather than a clean diagnostic
  // (#6820) — worse than JVM's mere DLL/JAR-naming collision. Skip
  // unconditionally, matching Jvm, until resolving dependency source into
  // the native bundle is designed (tracked in #6815 item 1).
  match target {
    case Jvm -> {
      return (result, false, wsCtxOpt)
    }
    case Native -> {
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

/// Read every `[project.packages]` source file under `depDir`'s manifest and
/// append it to `depTemplatePkgsList` as a `ProjectPackage`, tagged with
/// `depName`.  Shared by `resolveManifestDependencies`'s workspace-dep branch
/// (a `path = "..."` dep has always inlined this same read-and-collect logic
/// directly; this extraction only exists so the workspace-dep branch doesn't
/// duplicate it a third time — see `cmdTestManifest`'s own copy in cli_test.l).
/// Read failures print a warning and are otherwise non-fatal: a workspace
/// dep's DLL-based restored-dependency resolution (dotnet) or the caller's own
/// unbuilt-dep diagnostics already cover the fatal cases; this is purely an
/// additive source of symbols/templates for cross-package resolution.
func collectDepTemplateSources(
  depDir: in String, depName: in String, depTemplatePkgsList: in List[ProjectPackage]
): Unit {
  val depToml = Path.join(depDir, "lyric.toml")
  match File.readText(depToml) {
    case Err(_) -> ()
    case Ok(depMfText) -> {
      match Mf.parseManifest(depMfText, depToml) {
        case Err(_) -> ()
        case Ok(depMf) -> {
          match depMf.project {
            case None -> ()
            case Some(proj) -> {
              var pki = 0
              while pki < proj.packages.count {
                val pkgEntry = proj.packages[pki]
                val srcList: List[String] = newList()
                val pathList: List[String] = newList()
                if pkgEntry.paths.count > 0 {
                  var fi = 0
                  while fi < pkgEntry.paths.count {
                    val srcPath = if Path.isAbsolute(pkgEntry.paths[fi]) {
                      pkgEntry.paths[fi]
                    } else {
                      Path.join(depDir, pkgEntry.paths[fi])
                    }
                    match File.readText(srcPath) {
                      case Ok(srcText) -> {
                        srcList.add(srcText)
                        pathList.add(srcPath)
                      }
                      case Err(e) -> printErr("build: workspace dep '" + depName + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                    }
                    fi += 1
                  }
                } else {
                  val srcPath = if Path.isAbsolute(pkgEntry.path) { pkgEntry.path } else { Path.join(depDir, pkgEntry.path) }
                  match File.readText(srcPath) {
                    case Ok(srcText) -> {
                      srcList.add(srcText)
                      pathList.add(srcPath)
                    }
                    case Err(e) -> printErr("build: workspace dep '" + depName + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                  }
                }
                if srcList.count > 0 {
                  depTemplatePkgsList.add(ProjectPackage(name = pkgEntry.name, sources = srcList, paths = pathList))
                }
                pki += 1
              }
            }
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
    None,
    // no user --define for a transitively-built workspace dep
    newList()
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
    val wsTab = Str.indexOfRaw(wsEntry, "\t")
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
                  // A missing DLL only blocks Dotnet: that's the target whose
                  // restored-dependency resolution actually reads `dllPath`
                  // (`restoredDlls`). On Jvm the dep's SOURCE (collected right
                  // below into `depTemplatePkgsList`, then compiled as an
                  // ordinary bundle package by `buildProjectFromManifest` /
                  // `emitSingleFileOrProject`) is what matters — treating an
                  // absent `.dll` as fatal here made a `--target jvm` build of
                  // a fresh checkout's path dependency fail before it ever
                  // reached codegen, even though nothing on that path needs
                  // the DLL to exist (#6264).
                  // Explicit `Native` arm (rather than folding it into the
                  // wildcard) so this reads as a deliberate choice, not an
                  // accident of the wildcard: a `path`/`workspace` dependency
                  // on `--target native` is out of scope (#6809 — native has
                  // no restored-binary concept, so `Emitter.emitNativeProject`
                  // never reads `restoredDlls`/`depTemplateSrcs` at all; only
                  // a project's OWN `[project.packages]` compiles for
                  // native), so Native inherits Dotnet's "DLL matters"
                  // behavior rather than silently absorbing whatever the Jvm
                  // case does as targets are added later.
                  val dllMatters = match target { case Jvm -> false; case Native -> true; case _ -> true }
                  // #6697: `dllMatters` also gates whether an EXISTING `.dll`
                  // is added to `restoredDlls` at all — not just whether a
                  // MISSING one is fatal. `bin/<name>.dll` here is always an
                  // MSIL PE (path deps are never built for a specific target
                  // by this resolver; `[project].output_assembly` names a
                  // plain `.dll` regardless of what built it) — never a
                  // JVM-compatible JAR. Before this fix, a stray leftover from
                  // an earlier `--target dotnet` build of the SAME dependency
                  // directory (a common real-world sequence: build the dep for
                  // dotnet once, then build a consumer for `--target jvm`)
                  // flowed straight into `EmitProjectRequest.restoredDllPaths`,
                  // where the JVM restored-dep loader
                  // (`Lyric.RestoredPackages.loadRestoredPackageJvm`, #3094)
                  // tried to read it as a JAR's ZIP central directory and
                  // hard-failed the whole build ("restored JVM dep '...'
                  // failed to load: ..."). Jvm never needs this path — the
                  // dep's source is already compiled directly into the bundle
                  // below — so skip the add entirely on Jvm, mirroring
                  // `buildWorkspaceDeps`'s early return for the same target.
                  if File.fileExists(dllPath) {
                    if dllMatters and not stringListContains(seenDeps, dep.name) {
                      restoredDlls.add(dep.name + "\t" + dllPath)
                      seenDeps.add(dep.name)
                      collectTransitiveDepDlls(depDir, wsCtxOpt, seenDeps, restoredDlls)
                    }
                  } else if dllMatters {
                    printErr("build: " + Release.localDepNotBuiltMessage(dep.name, dllPath, depToml))
                    hadUnbuiltLocalDep = true
                  }
                  // Collect source files from this path dependency so the weaver can
                  // resolve cross-package `from`-instance aspect templates (#3498) and
                  // — on Jvm — so the dependency's actual code (not just its templates)
                  // compiles into the bundle (#6264). A source-read failure has always
                  // been a non-fatal warning here because the pre-#6264 Jvm path never
                  // consumed these sources for anything but template extraction; now
                  // that Jvm compiles them as real packages, a dep whose source can't
                  // be read means its symbols are simply absent from the Jvm bundle —
                  // matching the project's own "sibling packages are FATAL" policy
                  // (the issue's suggested diagnostic severity), this now sets
                  // `hadUnbuiltLocalDep = true` on Jvm too (`if not dllMatters`, below).
                  // "Fatal" cashes out differently per caller, same as the DLL-missing
                  // case above: `emitSingleFileOrProject` reads the flag directly and
                  // returns early with a clear message (cli_build.l:hadUnbuiltLocalDep
                  // check); `buildProjectFromManifest` (the `--manifest` path) never
                  // reads this flag at all (by design — see
                  // `ResolvedManifestDeps.hadUnbuiltLocalDep`'s doc comment) and instead
                  // fails downstream, when the consumer package that imports the
                  // now-symbol-less dependency hits an unresolved-reference type error.
                  // Both are exercised by
                  // `jvm_path_dependency_self_test.l`'s "unreadable source" tests.
                  match depMf.project {
                    case Some(proj) -> {
                      var pki = 0
                      while pki < proj.packages.count {
                        val pkgEntry = proj.packages[pki]
                        val srcList: List[String] = newList()
                        val pathList: List[String] = newList()
                        if pkgEntry.paths.count > 0 {
                          var fi = 0
                          while fi < pkgEntry.paths.count {
                            val srcPath = Path.join(depDir, pkgEntry.paths[fi])
                            match File.readText(srcPath) {
                              case Ok(srcText) -> {
                                srcList.add(srcText)
                                pathList.add(srcPath)
                              }
                              case Err(e) -> {
                                printErr("build: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                                if not dllMatters {
                                  hadUnbuiltLocalDep = true
                                }
                              }
                            }
                            fi += 1
                          }
                        } else {
                          val srcPath = Path.join(depDir, pkgEntry.path)
                          match File.readText(srcPath) {
                            case Ok(srcText) -> {
                              srcList.add(srcText)
                              pathList.add(srcPath)
                            }
                            case Err(e) -> {
                              printErr("build: dep '" + dep.name + "': cannot read source '" + srcPath + "': " + IOError.message(e))
                              if not dllMatters {
                                hadUnbuiltLocalDep = true
                              }
                            }
                          }
                        }
                        if srcList.count > 0 {
                          depTemplatePkgsList.add(ProjectPackage(name = pkgEntry.name, sources = srcList, paths = pathList))
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
      case Mf.DepSource.Workspace(_) -> {
        // Unlike a `path = "..."` dep (handled above), a `{ workspace = true }`
        // dep's DLL is only built here for the Dotnet target — `buildWorkspaceDeps`
        // deliberately skips building it for Jvm (the JVM bundled compile consumes
        // cross-package code from source via `depTemplateSrcs`, never
        // `restoredDllPaths`; see `buildWorkspaceDeps`'s header comment). Without
        // this branch, a workspace dep's source never reached `depTemplateSrcs` on
        // ANY target, so a `--target jvm` build/test of a workspace-dep consumer
        // saw every cross-package symbol as unknown even though the identical
        // `--target dotnet` build passed via the restored-DLL path (#6136).
        match wsCtxOpt {
          case None -> ()
          case Some(wsCtx) -> {
            match Ws.resolveDep(dep.name, wsCtx) {
              case None -> ()
              case Some(depDir) -> collectDepTemplateSources(depDir, dep.name, depTemplatePkgsList)
            }
          }
        }
      }
      case _ -> ()
    }
    di += 1
  }

  val allNugetAssets = resolveAllNugetAssets(mfDir)
  val nugetPaths = allNugetAssets.dllPaths
  warnIfNugetUnresolved(mfDir, manifest.nuget, nugetPaths)
  val (nugetLyricEntries, nugetThirdPartyPaths) = partitionNugetLyricDeps(nugetPaths)
  // #6697: NuGet is the dotnet-only package channel
  // (docs/39-package-registry.md §"NuGet.org as the .NET channel"; Maven is
  // the JVM channel). A NuGet-restored Lyric package ships an MSIL .dll with
  // no JVM artifact, so on `--target jvm` it cannot satisfy the JVM
  // restored-dep JAR loader (`Lyric.RestoredPackages.loadRestoredPackageJvm`,
  // #3094) any more than a path dependency's stray dotnet-built `.dll` can
  // (see the Path branch above) — feeding it in used to hard-fail the whole
  // build ("restored JVM dep '...' failed to load: ..."). Route it through
  // `nugetThirdPartyPaths` instead so it surfaces via the existing "NuGet
  // assembly resolution is not yet supported on the JVM target" W0006
  // warning (`Lyric.Emitter`) rather than silently vanishing or crashing.
  match target {
    case Jvm -> {
      for entry in nugetLyricEntries {
        val tabPos = Str.indexOfRaw(entry, "\t")
        val entryPath = if tabPos >= 0 { entry.substring(tabPos + 1, entry.length - tabPos - 1) } else { entry }
        nugetThirdPartyPaths.add(entryPath)
      }
    }
    case _ -> {
      for entry in nugetLyricEntries {
        restoredDlls.add(entry)
      }
    }
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
///
/// #6301: every call site gates `injectMavenClasspathForJvm` behind
/// `case Jvm -> ...` (`cli_build.l`'s `buildOneNative` and
/// `buildProjectFromManifest`), so a `--target dotnet` build always passes
/// `None` here and this function is a pure no-op — it touches no file, no
/// environment variable, nothing that can throw.  A `BadImageFormatException`
/// / `MissingFieldException` observed on a `--target dotnet` build cannot
/// originate here; look at the concurrent DLL read/write paths instead
/// (`Msil.Bridge`'s `writeBytesAtomic` and `cli_shared.l`'s
/// `writeBytesAtomicBeside`, both fixed for exactly this symptom).
pub func restoreMavenClasspath(saved: in Option[String]): Unit {
  match saved {
    case Some(prev) -> Environment.setVar("LYRIC_FFI_JARS", prev)
    case None -> ()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Workspace-member import resolution for single-file builds (#6503).
// ─────────────────────────────────────────────────────────────────────────────
/// Result of `resolveWorkspaceImportDeps` — the workspace members a
/// single-file build's imports name, resolved to already-built DLLs.
pub record WorkspaceImportDeps {
  /// "memberName\tdllPath" entries (same shape as
  /// `ResolvedManifestDeps.restoredDlls`).
  restoredDlls: List[String]
  /// The matched members' source packages, for cross-package aspect/wire
  /// template collection (same shape as `ResolvedManifestDeps.depTemplateSrcs`).
  depTemplateSrcs: List[ProjectPackage]
  /// True when an import matched a workspace member whose DLL is not built —
  /// the build must fail loudly (with the member named in stderr) rather than
  /// compile the import leniently into runtime-invalid code.
  hadUnbuiltMember: Bool
}

func emptyWorkspaceImportDeps(): WorkspaceImportDeps {
  WorkspaceImportDeps(restoredDlls = newList(), depTemplateSrcs = newList(), hadUnbuiltMember = false)
}

/// True for package heads that resolve through the compiler / stdlib
/// bundles, never through workspace members — skipped by the
/// package-key fallback below.  (An EXACT member-name match still wins for
/// `Lyric.*` ecosystem members like `Lyric.Docker` / `Lyric.Web`.)
func isBundleResolvedHead(name: in String): Bool {
  name == "Std" or Str.startsWith(name, "Std.") or name == "Lyric" or Str.startsWith(name, "Lyric.") or name == "Msil" or
    Str.startsWith(name, "Msil.") or
    name == "Jvm" or
    Str.startsWith(name, "Jvm.")
}

/// Build the package-name → member index for the fallback matching: each
/// member manifest's `[project.packages]` keys, read ONCE per resolution
/// call (a per-import scan would re-read every member manifest per
/// unresolvable import).  Entries are "packageName\tmemberIndex".
func buildMemberPackageIndex(ctx: in Ws.WorkspaceContext): Map[String, Int] {
  val index: Map[String, Int] = newMap()
  var mi = 0
  while mi < ctx.members.count {
    val member = ctx.members[mi]
    val mToml = Path.join(member.dir, "lyric.toml")
    match File.readText(mToml) {
      case Err(_) -> ()
      case Ok(mText) -> {
        match Mf.parseManifest(mText, mToml) {
          case Err(_) -> ()
          case Ok(mMf) -> {
            match mMf.project {
              case None -> ()
              case Some(proj) -> {
                var pi = 0
                while pi < proj.packages.count {
                  if not index.containsKey(proj.packages[pi].name) {
                    index.add(proj.packages[pi].name, mi)
                  }
                  pi += 1
                }
              }
            }
          }
        }
      }
    }
    mi += 1
  }
  index
}

/// #6503: resolve a single-file build's imports against the enclosing
/// workspace's MEMBERS, using already-built member DLLs only.
///
/// Before this, a single file inside the workspace importing a member
/// library (`examples/docker_client.l` → `import Lyric.Docker`) compiled
/// with NO dependency contribution at all: the checker typed every
/// `Docker.*` reference leniently, codegen emitted unresolved-call
/// fallbacks, and the "successful" build crashed with
/// `InvalidProgramException` at runtime — the silent-miscompile class
/// #6503 documents.  Matching imports to members makes such builds
/// compile against the real restored types (annotations included).
///
/// Deliberately does NOT build members implicitly: D123's single-file
/// contract ("single-file mode never triggers an implicit restore") is
/// preserved by requiring the member DLL to already exist — an unbuilt
/// matched member fails the build loudly with the exact command to run,
/// which is strictly better than the silent runtime-invalid output it
/// replaces.  `alreadySeen` carries dep names the nearby manifest already
/// resolved so a declared dependency is never double-restored.
///
/// `target` gates the DLL bookkeeping the same way `resolveManifestDependencies`'s
/// `dllMatters` does (#6697/#6750/#6771): a matched member's `bin/<name>.dll`
/// is always an MSIL PE, never a JVM-compatible JAR, so on Jvm it is never
/// added to `restoredDlls` and its absence (or dotnet-only staleness) is not
/// fatal — the member's SOURCE (collected into `depTemplateSrcs` unconditionally)
/// is compiled straight into the bundle instead, matching the manifest leg.
pub func resolveWorkspaceImportDeps(
  sourceText: in String,
  sourceDir: in String,
  alreadySeen: in List[String],
  target: in Emitter.CompileTarget,
): WorkspaceImportDeps {
  val ctx = match Ws.findWorkspaceRoot(sourceDir) { case None -> return emptyWorkspaceImportDeps(); case Some(c) -> c }
  val restored: List[String] = newList()
  val templates: List[ProjectPackage] = newList()
  var hadUnbuilt = false
  val seen: List[String] = newList()
  var ai = 0
  while ai < alreadySeen.count {
    seen.add(alreadySeen[ai])
    ai += 1
  }
  val dllMatters = match target { case Jvm -> false; case _ -> true }
  val importNames = importedPackageNames(sourceText)
  // Lazily built on the first fallback-eligible import: exact member-name
  // matches never need it, and most single-file builds import nothing that
  // reaches the fallback.
  var pkgIndexBuilt = false
  var pkgIndex: Map[String, Int] = newMap()
  var ii = 0
  while ii < importNames.count {
    val name = importNames[ii]
    if not (name == "Std" or Str.startsWith(name, "Std.")) {
      var memberOpt: Option[Ws.WorkspaceMember] = Ws.findMember(ctx.members, name)
      match memberOpt {
        case Some(_) -> ()
        case None -> {
          if not isBundleResolvedHead(name) {
            if not pkgIndexBuilt {
              pkgIndex = buildMemberPackageIndex(ctx)
              pkgIndexBuilt = true
            }
            match mapGet(pkgIndex, name) {
              case Some(midx) -> {
                memberOpt = Some(value = ctx.members[midx])
              }
              case None -> ()
            }
          }
        }
      }
      match memberOpt {
        case None -> ()
        case Some(member) -> {
          if not stringListContains(seen, member.name) {
            if dllMatters {
              val mToml = Path.join(member.dir, "lyric.toml")
              val dllName = match File.readText(mToml) {
                case Err(_) -> member.name + ".dll"
                case Ok(mText) -> match Mf.parseManifest(mText, mToml) { case Err(_) -> member.name + ".dll"; case Ok(mMf) -> match mMf.project { case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }; case None -> mMf.packageSection.name + ".dll" } }
              }
              val dllPath = Path.join(Path.join(member.dir, "bin"), dllName)
              if File.fileExists(dllPath) {
                restored.add(member.name + "\t" + dllPath)
                seen.add(member.name)
                collectTransitiveDepDlls(member.dir, Some(value = ctx), seen, restored)
                collectDepTemplateSources(member.dir, member.name, templates)
              } else {
                printErr(
                  "build: import '" + name + "' names workspace member '" + member.name + "' but its DLL is not built (" + dllPath +
                    "). Run `lyric build --manifest " +
                    mToml +
                    "` first — single-file builds never build members implicitly (D123)."
                )
                hadUnbuilt = true
              }
            } else {
              // Jvm: the member's `bin/<name>.dll` (if any) is an MSIL PE,
              // never a JVM-compatible artifact, so it is neither restored
              // nor required to exist — only the member's SOURCE matters,
              // compiled straight into the bundle by the caller (#6771).
              seen.add(member.name)
              collectDepTemplateSources(member.dir, member.name, templates)
            }
          }
        }
      }
    }
    ii += 1
  }
  WorkspaceImportDeps(restoredDlls = restored, depTemplateSrcs = templates, hadUnbuiltMember = hadUnbuilt)
}
