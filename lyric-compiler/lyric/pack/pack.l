//! pack/pack.l — self-hosted csproj XML generator for `lyric restore`.
//! (`lyric publish` packs from a hand-authored .nuspec built in
//! cli/cli_publish.l since #5644, so its csproj generator was removed here.)
//!
//! Only Registry(version) deps emit <PackageReference>; Workspace/Path/Git deps
//! are resolved locally by Lyric.Workspace and never expressed as NuGet refs.
package Lyric.Pack

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Manifest

// ─── Character helpers ────────────────────────────────────────────────────────
pub func xmlEscape(s: in String): String {
  var r = Str.replace(s, "&", "&amp;")
  r = Str.replace(r, "<", "&lt;")
  r = Str.replace(r, ">", "&gt;")
  r = Str.replace(r, "\"", "&quot;")
  r = Str.replace(r, "'", "&apos;")
  r
}

pub func sanitisedPackageName(raw: in String): String {
  var s = ""
  var i = 0
  while i < raw.length {
    val c = raw[i]
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-' {
      s = s + ("" + c)
    }
    i = i + 1
  }
  s
}

// ─── Restore csproj ───────────────────────────────────────────────────────────
/// Generate the `.csproj` content for `lyric restore`.
pub func restoreCsproj(m: in Manifest): String {
  val pkg = m.packageSection

  var lyricDepsXml = ""
  var di = 0
  while di < m.deps.count {
    val d = m.deps[di]
    match d.source {
      case Registry(version) -> {
        lyricDepsXml = lyricDepsXml + "    <PackageReference Include=\"" + xmlEscape(d.name) + "\" Version=\"" +
          xmlEscape(version) +
          "\" />\n"
      }
      case _ -> ()
    }
    di = di + 1
  }

  var nugetDepsXml = ""
  match m.nuget {
    case None -> ()
    case Some(n) -> {
      var ni = 0
      while ni < n.entries.count {
        val e = n.entries[ni]
        nugetDepsXml = nugetDepsXml + "    <PackageReference Include=\"" + xmlEscape(e.name) + "\" Version=\"" +
          xmlEscape(e.version) +
          "\" />\n"
        ni = ni + 1
      }
    }
  }

  val target = match m.nuget {
    case Some(n) -> match n.target { case Some(t) -> t; case None -> "net10.0" }
    case None -> "net10.0"
  }

  val combined = lyricDepsXml + nugetDepsXml

  var xml = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  xml = xml + "  <PropertyGroup>\n"
  xml = xml + "    <TargetFramework>" + xmlEscape(target) + "</TargetFramework>\n"
  xml = xml + "    <PackageId>" + xmlEscape(sanitisedPackageName(pkg.name)) + "</PackageId>\n"
  xml = xml + "    <Version>" + xmlEscape(pkg.version) + "</Version>\n"
  xml = xml + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  xml = xml + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  xml = xml + "  </PropertyGroup>\n"
  xml = xml + "  <ItemGroup>\n"
  if not Str.isEmpty(combined) {
    xml = xml + combined
  }
  xml = xml + "  </ItemGroup>\n"
  xml + "</Project>\n"
}
