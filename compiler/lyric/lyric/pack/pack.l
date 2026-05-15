// pack/pack.l — self-hosted csproj XML generator for `lyric publish` / `lyric restore`.
// Mirrors the XML-generation portion of compiler/src/Lyric.Cli/Pack.fs
// (Phase 5 §M5.3 shim elimination).  Process invocation (dotnet pack/restore)
// stays in the F# Pack.fs.
package Lyric.Pack

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Manifest

// ─── Character helpers ────────────────────────────────────────────────────────

func xmlEscape(s: in String): String {
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
    if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
       (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-' {
      s = s + ("" + c)
    }
    i = i + 1
  }
  s
}

// Extract the filename component from a path (handles both / and \).
pub func getFileName(path: in String): String {
  var best = 0
  var i = 0
  while i < path.length {
    val c = path[i]
    if c == '/' or c == '\\' {
      best = i + 1
    }
    i = i + 1
  }
  if best >= path.length { path } else { Str.substring(path, best, path.length - best) }
}

// ─── Publish csproj ───────────────────────────────────────────────────────────

/// Generate the `.csproj` content for `lyric publish`.
/// `dllAbsPath` must be an absolute path (the F# caller resolves it before
/// passing it here via the bridge).
pub func publishCsproj(m: in Manifest, dllAbsPath: in String): String {
  val pkg = m.packageSection
  val sanitisedId = sanitisedPackageName(pkg.name)
  val assemblyFile = getFileName(dllAbsPath)

  var authorsXml = ""
  if pkg.authors.count > 0 {
    var authorStr = ""
    var ai = 0
    while ai < pkg.authors.count {
      if ai > 0 { authorStr = authorStr + ";" }
      authorStr = authorStr + xmlEscape(pkg.authors[ai])
      ai = ai + 1
    }
    authorsXml = "    <Authors>" + authorStr + "</Authors>"
  }

  val descXml =
    if Str.isEmpty(pkg.description) { "" }
    else { "    <Description>" + xmlEscape(pkg.description) + "</Description>" }

  val licXml =
    if Str.isEmpty(pkg.license) { "" }
    else { "    <PackageLicenseExpression>" + xmlEscape(pkg.license) + "</PackageLicenseExpression>" }

  var depsXml = ""
  var di = 0
  while di < m.deps.count {
    val d = m.deps[di]
    depsXml = depsXml +
      "    <PackageReference Include=\"" + xmlEscape(d.name) +
      "\" Version=\"" + xmlEscape(d.version) + "\" />\n"
    di = di + 1
  }

  var xml = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  xml = xml + "  <PropertyGroup>\n"
  xml = xml + "    <TargetFramework>net10.0</TargetFramework>\n"
  xml = xml + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  xml = xml + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  xml = xml + "    <NoWarn>$(NoWarn);NU5128</NoWarn>\n"
  xml = xml + "    <PackageId>" + xmlEscape(sanitisedId) + "</PackageId>\n"
  xml = xml + "    <Version>" + xmlEscape(pkg.version) + "</Version>\n"
  if not Str.isEmpty(authorsXml) { xml = xml + authorsXml + "\n" }
  if not Str.isEmpty(descXml)    { xml = xml + descXml    + "\n" }
  if not Str.isEmpty(licXml)     { xml = xml + licXml     + "\n" }
  xml = xml + "  </PropertyGroup>\n"
  xml = xml + "  <ItemGroup>\n"
  xml = xml +
    "    <None Include=\"" + xmlEscape(dllAbsPath) +
    "\" Pack=\"true\" PackagePath=\"lib/net10.0/" + xmlEscape(assemblyFile) + "\" />\n"
  xml = xml + "  </ItemGroup>\n"
  if not Str.isEmpty(depsXml) {
    xml = xml + "  <ItemGroup>\n"
    xml = xml + depsXml
    xml = xml + "  </ItemGroup>\n"
  }
  xml + "</Project>\n"
}

// ─── Restore csproj ───────────────────────────────────────────────────────────

/// Generate the `.csproj` content for `lyric restore`.
pub func restoreCsproj(m: in Manifest): String {
  val pkg = m.packageSection

  var lyricDepsXml = ""
  var di = 0
  while di < m.deps.count {
    val d = m.deps[di]
    lyricDepsXml = lyricDepsXml +
      "    <PackageReference Include=\"" + xmlEscape(d.name) +
      "\" Version=\"" + xmlEscape(d.version) + "\" />\n"
    di = di + 1
  }

  var nugetDepsXml = ""
  match m.nuget {
    case None    -> ()
    case Some(n) -> {
      var ni = 0
      while ni < n.entries.count {
        val e = n.entries[ni]
        nugetDepsXml = nugetDepsXml +
          "    <PackageReference Include=\"" + xmlEscape(e.name) +
          "\" Version=\"" + xmlEscape(e.version) + "\" />\n"
        ni = ni + 1
      }
    }
  }

  val target = match m.nuget {
    case Some(n) -> match n.target {
      case Some(t) -> t
      case None    -> "net10.0"
    }
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
  if not Str.isEmpty(combined) { xml = xml + combined }
  xml = xml + "  </ItemGroup>\n"
  xml + "</Project>\n"
}
