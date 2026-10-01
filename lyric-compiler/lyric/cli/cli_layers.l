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
  val files: List[Layers.LayerPackage] = newList()
  for pkg in pkgs {
    var i = 0
    while i < pkg.sources.count {
      val path = if i < pkg.paths.count and pkg.paths[i] != "" { pkg.paths[i] } else { pkg.name }
      val pr = Parser.parse(pkg.sources[i])
      // A file that does not parse is reported by the build that follows;
      // checking its layers here would only add noise.
      if pr.diagnostics.count == 0 {
        val erased = Cfg.applyCfgErasure(active, declaredFeatures, pr.file)
        files.add(Layers.LayerPackage(name = pkg.name, path = path, file = erased.file))
      }
      i = i + 1
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
        ioForbiddenReason = unwrapOr(mapGet(reasons, pkg.name), "")
      )
    )
  }
  Some(value = withReasons)
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
