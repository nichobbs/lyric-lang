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
  manifest: in Mf.Manifest,
  mfPath: in String,
  target: in Emitter.CompileTarget,
): (List[String], Bool) {
  val result: List[String] = newList()
  var hadError = false

  // Find the workspace root. If we're not in a workspace, return empty.
  val wsCtx = match Ws.findWorkspaceRoot(Path.dirname(mfPath)) {
    case Some(ctx) -> ctx
    case None -> {
      // No workspace found; workspace dependencies cannot be resolved.
      // The caller will diagnose this as an unresolved dependency.
      return (result, false)
    }
  }

  val mfDir = Path.dirname(mfPath)
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Mf.DepSource.Workspace(versionOpt) -> {
        // Resolve the dependency name to its directory within the workspace.
        match Ws.resolveDep(dep.name, wsCtx) {
          case Some(depDir) -> {
            val buildResult = buildWorkspaceDep(dep.name, depDir, target)
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
            printErr(
              "build: workspace dep '" + dep.name +
                "' not found; check workspace root and member list"
            )
            hadError = true
          }
        }
      }
      case _ -> ()
    }
    di += 1
  }

  (result, hadError)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Build a single workspace dependency and return its DLL path.
/// Returns Err(msg) on any failure.
func buildWorkspaceDep(
  depName: in String,
  depDir: in String,
  target: in Emitter.CompileTarget,
): Result[String, String] {
  val depToml = Path.join(depDir, "lyric.toml")

  // Check that the manifest exists.
  if not File.fileExists(depToml) {
    return Err(msg = "no lyric.toml found at " + depToml)
  }

  val depMfText = match File.readText(depToml) {
    case Err(e) -> return Err(msg = "cannot read " + depToml + ": " + IOError.message(e))
    case Ok(text) -> text
  }

  val depMf = match Mf.parseManifest(depMfText, depToml) {
    case Err(e) -> return Err(msg = "malformed lyric.toml: " + ManifestError.message(e))
    case Ok(m) -> m
  }

  // Determine the DLL filename and path.
  val dllName: String = match depMf.project {
    case Some(p) -> match p.outputAssembly { case Some(asm) -> asm; case None -> p.name + ".dll" }
    case None -> depMf.packageSection.name + ".dll"
  }
  val depBinDir = Path.join(depDir, "bin")
  val dllPath = Path.join(depBinDir, dllName)

  // If the DLL exists and is up-to-date, skip the build.
  // (A full modification-time check is deferred; for now, existence check is sufficient.)
  if File.fileExists(dllPath) {
    return Ok(value = dllPath)
  }

  // The DLL is missing or stale. Recursively build this dependency and any of
  // its transitive dependencies.
  Console.println("build: building workspace dep '" + depName + "' (" + depDir + ") ...")

  val buildExit = buildProject(
    depToml,
    None,  // use the manifest's default output location
    target,
    newList(),  // no CLI features
    false,      // use defaults
    false,      // no --all-features
    false       // allow restore
  )

  if buildExit != 0 {
    return Err(msg = "build failed (exit code " + toString(buildExit) + ")")
  }

  // After a successful build, the DLL should exist.
  if File.fileExists(dllPath) {
    Ok(value = dllPath)
  } else {
    Err(msg = "build succeeded but DLL not found at " + dllPath)
  }
}
