// manifest_bridge.l — text-protocol bridge for the F# SelfHostedManifest.fs shim.
// Wraps Lyric.Manifest.parse and serialises the result to a simple line-oriented
// protocol so the F# shim can reconstruct the Manifest record without CLR reflection
// on Lyric union types (Option[T], Result[T,E]).
//
// Protocol:
//   First line: "ok" or "err"
//   On "err": second line is the error message.
//   On "ok": subsequent lines are key=value pairs (value is everything after '='):
//     pkg.name=<name>
//     pkg.version=<version>
//     pkg.description=<desc>          (empty if absent)
//     pkg.license=<license>           (empty if absent)
//     pkg.author=<author>             (one per author)
//     dep=<name>=<version>            (one per version-pinned dependency; first '=' is separator)
//     dep-path=<name>=<path>          (one per local path dependency; first '=' is separator)
//     nuget=<id>=<version>            (one per nuget entry)
//     nuget.target=<tfm>
//     nuget.allow_native=true
//     project.name=<name>
//     project.output=<mode>
//     project.output_assembly=<asm>
//     project.pkg=<name>=<path>       (first '=' is separator)
//     feature=<name>
//     feature.default=<name>

package Lyric.ManifestBridge

import Std.Core
import Std.Collections
import Lyric.Manifest

pub func serializeManifest(text: in String, filePath: in String): String {
  match parseManifest(text, filePath) {
    case Err(e) -> "err\n" + ManifestError.message(e)
    case Ok(m)  -> {
      var s = "ok\n"
      s = s + "pkg.name=" + m.packageSection.name + "\n"
      s = s + "pkg.version=" + m.packageSection.version + "\n"
      s = s + "pkg.description=" + m.packageSection.description + "\n"
      s = s + "pkg.license=" + m.packageSection.license + "\n"
      var ai = 0
      while ai < m.packageSection.authors.count {
        s = s + "pkg.author=" + m.packageSection.authors[ai] + "\n"
        ai = ai + 1
      }
      var di = 0
      while di < m.deps.count {
        val dep = m.deps[di]
        match dep.localPath {
          case Some(p) -> { s = s + "dep-path=" + dep.name + "=" + p + "\n" }
          case None    -> { s = s + "dep=" + dep.name + "=" + dep.version + "\n" }
        }
        di = di + 1
      }
      match m.nuget {
        case None    -> ()
        case Some(n) -> {
          var ni = 0
          while ni < n.entries.count {
            s = s + "nuget=" + n.entries[ni].name + "=" + n.entries[ni].version + "\n"
            ni = ni + 1
          }
          match n.target {
            case None    -> ()
            case Some(t) -> { s = s + "nuget.target=" + t + "\n" }
          }
          if n.allowNative { s = s + "nuget.allow_native=true\n" }
        }
      }
      match m.project {
        case None    -> ()
        case Some(p) -> {
          s = s + "project.name=" + p.name + "\n"
          s = s + "project.output=" + p.output + "\n"
          match p.outputAssembly {
            case None     -> ()
            case Some(oa) -> { s = s + "project.output_assembly=" + oa + "\n" }
          }
          var pi = 0
          while pi < p.packages.count {
            s = s + "project.pkg=" + p.packages[pi].name + "=" + p.packages[pi].path + "\n"
            pi = pi + 1
          }
        }
      }
      match m.features {
        case None    -> ()
        case Some(f) -> {
          var fi = 0
          while fi < f.declared.count {
            s = s + "feature=" + f.declared[fi] + "\n"
            fi = fi + 1
          }
          var fdi = 0
          while fdi < f.defaults.count {
            s = s + "feature.default=" + f.defaults[fdi] + "\n"
            fdi = fdi + 1
          }
        }
      }
      s
    }
  }
}
