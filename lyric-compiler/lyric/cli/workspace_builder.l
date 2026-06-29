//! cli/workspace_builder.l — Build transitive workspace dependencies.
//!
//! When a project in a workspace declares a { workspace = true } dependency,
//! this module:
//! 1. Discovers the workspace root if it exists
//! 2. Resolves the dependency name to its directory
//! 3. Builds the dependency if its DLL is missing or stale
//! 4. Returns the built DLL path
//!
//! This ensures that `lyric build` in a workspace automatically builds all
//! transitive dependencies in correct order, eliminating the manual burden
//! of building dependencies upfront.
package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.Errors
import Lyric.Manifest as Mf
import Lyric.Workspace as Ws
import Lyric.Emitter as Emitter

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public API
// ─────────────────────────────────────────────────────────────────────────────
/// Resolve all { workspace = true } dependencies in a manifest, building them
/// as needed.  Returns (dllPaths, buildErrors).
/// dllPaths is a list of "name\tdllPath" strings, matching the format used for
/// path dependencies.  buildErrors is True if any build failed.
pub func buildWorkspaceDeps(
  manifest: in Mf.Manifest, mfPath: in String, target: in Emitter.CompileTarget
): (List[String], Bool) {
  val result: List[String] = newList()
  var hadError = false

  // Find the workspace root. If we're not in a workspace, return empty.
  val wsCtxOpt = Ws.findWorkspaceRoot(Path.dirname(mfPath))
  val wsCtx = match wsCtxOpt {
    case Some(ctx) -> ctx
    case None -> {
      // No workspace found; workspace dependencies cannot be resolved.
      // The caller will diagnose this as an unresolved dependency.
      return (result, false)
    }
  }

  val buildStack: List[String] = newList()
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
                result.add(dep.name + "\t" + dllPath)
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

  (result, hadError)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Private helpers
// ─────────────────────────────────────────────────────────────────────────────
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
    None
  )       // allow restore

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
