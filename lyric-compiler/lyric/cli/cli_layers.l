package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser as Parser
import Lyric.Cfg as Cfg
import Lyric.Manifest as Mf
import Lyric.Emitter as Emitter
import Lyric.Layers as Layers
import Lyric.RestoredPackages as RP
import Lyric.DiagnosticUtil as DiagUtil

/// Runs the `[layers]` check (docs/65 §5, D149) over a project's own
/// packages, before any backend, so it behaves the same on every target.
/// A manifest with no layers table passes without work.  Imported
/// packages outside the project are classified from the stdlib sources,
/// dependency sources and restored packages' contract metadata.  Prints
/// every diagnostic and returns None when there is an error; otherwise
/// `pkgs` with each package's `ioForbiddenReason` set for the backends.
func checkProjectLayers(
  manifest: in Mf.Manifest,
  mfPath: in String,
  pkgs: in List[Emitter.ProjectPackage],
  depSrcs: in List[Emitter.ProjectPackage],
  restoredDlls: in List[String],
  target: in Emitter.CompileTarget,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
): Option[List[Emitter.ProjectPackage]] {
  val section = match manifest.layers {
    case Some(s) -> s
    case None -> {
      val same: List[Emitter.ProjectPackage] = newList()
      for pkg in pkgs {
        same.add(pkg)
      }
      return Some(value = same)
    }
  }
  val cfg = match Layers.resolveLayerConfig(section) {
    case Ok(c) -> c
    case Err(ds) -> {
      reportLayerDiagnostics(mfPath, ds)
      return None
    }
  }
  // Erase `@cfg`-gated items as the build will, target pseudo-feature
  // included, so a gated-out `async func` is not reported.
  val active = Cfg.withTargetFeature(activeFeatures, targetFeatureName(target))
  val files = match parseLayerFiles(pkgs, active, declaredFeatures) {
    case Ok(fs) -> fs
    case Err(ds) -> {
      reportLayerDiagnostics(mfPath, ds)
      return None
    }
  }
  val classes: Map[String, String] = newMap()
  for dep in depSrcs {
    Layers.addSourceClasses(dep.sources, classes)
  }
  for entry in restoredDlls {
    val tab = Str.indexOfRaw(entry, "\t")
    val dllPath = if tab >= 0 { Str.substring(entry, tab + 1, entry.length - tab - 1) } else { entry }
    match RP.loadRestoredPackage(dllPath) {
      case Ok(artifacts) -> {
        for a in artifacts {
          if a.contract.purity != "" and not classes.containsKey(a.packageName) {
            classes[a.packageName] = a.contract.purity
          }
        }
      }
      case Err(_) -> ()
    }
  }
  Layers.addSourceClasses(Emitter.findStdlibSources(), classes)
  val ds = Layers.checkLayers(cfg, files, classes)
  reportLayerDiagnostics(mfPath, ds)
  for d in ds {
    if d.diag.severity == DiagError {
      return None
    }
  }
  val reasons = Layers.ioForbiddenReasons(cfg, files)
  val withReasons: List[Emitter.ProjectPackage] = newList()
  for pkg in pkgs {
    withReasons.add(
      Emitter.ProjectPackage(
        name = pkg.name,
        sources = pkg.sources,
        paths = pkg.paths,
        ioForbiddenReason = unwrapOr(mapGet(reasons, pkg.name), ""),
        nameFromManifest = pkg.nameFromManifest
      )
    )
  }
  Some(value = withReasons)
}

/// Parses and `@cfg`-erases every project file for the layer check.
/// Returns the parse diagnostics of each file that has a parse error
/// instead: checking layers without that file would report its package as
/// missing (Y0009) and its importers as breaking rules (Y0002), and those
/// errors would stop the build before the parse error was ever shown.
/// Warnings alone do not exclude a file; the build reports them later.
pub func parseLayerFiles(
  pkgs: in List[Emitter.ProjectPackage],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
): Result[List[Layers.LayerPackage], List[Layers.LayerDiagnostic]] {
  val files: List[Layers.LayerPackage] = newList()
  val parseErrors: List[Layers.LayerDiagnostic] = newList()
  for pkg in pkgs {
    var i = 0
    while i < pkg.sources.count {
      val path = if i < pkg.paths.count and pkg.paths[i] != "" { pkg.paths[i] } else { pkg.name }
      val pr = Parser.parse(pkg.sources[i])
      var hasError = false
      for d in pr.diagnostics {
        if d.severity == DiagError {
          hasError = true
        }
      }
      if hasError {
        for d in pr.diagnostics {
          parseErrors.add(Layers.LayerDiagnostic(path = path, diag = d))
        }
      } else {
        val erased = Cfg.applyCfgErasure(activeFeatures, declaredFeatures, pr.file)
        files.add(Layers.LayerPackage(name = pkg.name, path = path, file = erased.file))
      }
      i = i + 1
    }
  }
  if parseErrors.count > 0 {
    return Err(error = parseErrors)
  }
  Ok(value = files)
}

func reportLayerDiagnostics(mfPath: in String, ds: in List[Layers.LayerDiagnostic]): Unit {
  for d in ds {
    if d.path == "" {
      Console.error(mfPath + ": error[" + d.diag.code + "] " + d.diag.message)
    } else {
      Console.error(d.path + ": " + DiagUtil.diagFormat(d.diag))
    }
  }
}
