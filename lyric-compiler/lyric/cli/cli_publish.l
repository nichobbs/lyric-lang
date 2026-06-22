package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Hash as Hash
import Std.Char as Ch
import Std.ProcessCapture as ProcessCapture
import Lyric.Manifest as Mf
import Lyric.Pack as Pack
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11. Publish command
// ─────────────────────────────────────────────────────────────────────────────
func cmdPublish(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var dllOverride: Option[String] = None
  var outputDir: Option[String] = None
  var registryUrl: Option[String] = None
  var apiKey: Option[String] = None
  var skipDuplicate = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --manifest requires an argument")
        return 1
      }
    } else if arg == "--dll" {
      if i + 1 < argv.length {
        dllOverride = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --dll requires an argument")
        return 1
      }
    } else if arg == "-o" {
      if i + 1 < argv.length {
        outputDir = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: -o requires an argument")
        return 1
      }
    } else if arg == "--registry" {
      if i + 1 < argv.length {
        registryUrl = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --registry requires an argument")
        return 1
      }
    } else if arg == "--api-key" {
      if i + 1 < argv.length {
        apiKey = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --api-key requires an argument")
        return 1
      }
    } else if arg == "--skip-duplicate" {
      skipDuplicate = true
      i += 1
    } else {
      printErr("publish: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match manifestArg { case Some(p) -> p; case None -> "lyric.toml" }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("publish: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("publish: " + ManifestError.message(e))
      return 1
    }
  }

  // Warn when [workspace.overrides] are present — these should not ship.
  match manifest.workspace {
    case Some(ws) -> if ws.overrides.count > 0 { printErr("publish: warning: [workspace.overrides] is non-empty — override entries should not be committed") }
    case None -> ()
  }

  // Reject branch-form git deps — mutable refs cannot appear in a published manifest.
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Git(_, refKind, refValue, _) -> if refKind == "branch" { printErr("publish: dep '" + dep.name + "' uses git branch '" + refValue + "' — mutable refs are not allowed in published packages"); return 1 }
      case _ -> ()
    }
    di += 1
  }

  val pkg: PackageSection = manifest.packageSection
  val mfDir = Path.dirname(mfPath)
  val dllPath = match dllOverride {
    case Some(d) -> d
    case None -> Path.join(Path.join(mfDir, "bin"), pkg.name + ".dll")
  }

  if not File.fileExists(dllPath) {
    printErr("publish: DLL not found: " + dllPath + " — run `lyric build` first")
    return 1
  }

  val outDir = match outputDir { case Some(d) -> d; case None -> Path.join(Path.join(mfDir, "bin"), "nupkg") }
  match File.createDir(outDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("publish: cannot create output dir: " + IOError.message(e))
      return 1
    }
  }

  // Build the .nuspec for dotnet pack.  All Lyric deps must be published at
  // their declared Registry version — workspace deps are substituted.
  var nuspecDeps = ""
  var si = 0
  while si < manifest.deps.count {
    val dep = manifest.deps[si]
    val version = match dep.source {
      case Registry(v) -> v
      case Workspace(_) -> {
        // Substitute workspace dep with registry ref at member's declared version.
        val publishWsCtx = match Ws.findWorkspaceRoot(mfDir) {
          case Some(ctx) -> ctx
          case None -> {
            printErr("publish: workspace dep '" + dep.name + "' cannot be resolved — no workspace root")
            return 1
          }
        }
        val memberDir = match Ws.resolveDep(dep.name, publishWsCtx) {
          case Some(dir) -> dir
          case None -> {
            printErr("publish: workspace dep '" + dep.name + "' not found in workspace")
            return 1
          }
        }
        val memberToml = Path.join(memberDir, "lyric.toml")
        val memberText = match File.readText(memberToml) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("publish: cannot read workspace member manifest: " + IOError.message(e))
            return 1
          }
        }
        match Mf.parseManifest(memberText, memberToml) {
          case Err(e) -> {
            printErr("publish: cannot parse workspace member manifest: " + ManifestError.message(e))
            return 1
          }
          case Ok(mf) -> mf.packageSection.version
        }
      }
      case Path(_) -> {
        printErr("publish: dep '" + dep.name + "' uses path source — not allowed in published packages")
        return 1
      }
      case Git(_, _, refValue, _) -> refValue  // tag name / SHA / branch (branch rejected above)
    }
    nuspecDeps = nuspecDeps + "    <PackageReference Include=\"" + dep.name + "\" Version=\"" + version + "\" />\n"
    si += 1
  }

  val absDllPath = if Path.isAbsolute(dllPath) { dllPath } else { Path.join(mfDir, dllPath) }
  val dllBase = Path.basename(absDllPath)
  var csproj = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  csproj = csproj + "  <PropertyGroup>\n"
  csproj = csproj + "    <TargetFramework>net10.0</TargetFramework>\n"
  csproj = csproj + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  csproj = csproj + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  csproj = csproj + "    <NoWarn>$(NoWarn);NU5128</NoWarn>\n"
  csproj = csproj + "    <PackageId>" + Pack.xmlEscape(pkg.name) + "</PackageId>\n"
  csproj = csproj + "    <Version>" + Pack.xmlEscape(pkg.version) + "</Version>\n"
  if not Str.isEmpty(pkg.description) {
    csproj = csproj + "    <Description>" + Pack.xmlEscape(pkg.description) + "</Description>\n"
  }
  if not Str.isEmpty(pkg.license) {
    csproj = csproj + "    <PackageLicenseExpression>" + Pack.xmlEscape(pkg.license) + "</PackageLicenseExpression>\n"
  }
  match pkg.repository {
    case Some(r) -> {
      csproj = csproj + "    <RepositoryUrl>" + Pack.xmlEscape(r) + "</RepositoryUrl>\n"
    }
    case None -> ()
  }
  csproj = csproj + "    <PackageTags>lyric-package</PackageTags>\n"
  csproj = csproj + "  </PropertyGroup>\n"
  csproj = csproj + "  <ItemGroup>\n"
  csproj = csproj + "    <None Include=\"" + Pack.xmlEscape(absDllPath) + "\" Pack=\"true\" PackagePath=\"lib/net10.0/" +
    Pack.xmlEscape(dllBase) +
    "\" />\n"
  csproj = csproj + "  </ItemGroup>\n"
  if not Str.isEmpty(nuspecDeps) {
    csproj = csproj + "  <ItemGroup>\n"
    csproj = csproj + nuspecDeps
    csproj = csproj + "  </ItemGroup>\n"
  }
  csproj = csproj + "</Project>\n"

  val tmpCsproj = Path.join(mfDir, pkg.name + "-publish.csproj")
  match File.writeText(tmpCsproj, csproj) {
    case Err(e) -> {
      printErr("publish: cannot write temp csproj: " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }

  // Run `dotnet pack`.
  val packArgs: List[String] = newList()
  packArgs.add("pack")
  packArgs.add(tmpCsproj)
  packArgs.add("-o")
  packArgs.add(outDir)
  packArgs.add("--no-build")
  val packExit = match Process.run("dotnet", packArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("publish: dotnet pack failed: " + IOError.message(e))
      return 1
    }
  }
  if packExit != 0 {
    return packExit
  }

  val nupkgPath = Path.join(outDir, pkg.name + "." + pkg.version + ".nupkg")
  Console.println("publish: packed " + nupkgPath)

  // Determine push registry and API key.
  val pushRegistry = match registryUrl {
    case Some(url) -> url
    case None -> match manifest.registry { case Some(rc) -> match rc.dotnet { case Some(url) -> url; case None -> "https://api.nuget.org/v3/index.json" }; case None -> "https://api.nuget.org/v3/index.json" }
  }

  val pushKey = match apiKey {
    case Some(k) -> k
    case None -> match Environment.getVar("LYRIC_NUGET_API_KEY") { case Ok(k) -> k; case Err(_) -> "" }
  }

  if Str.isEmpty(pushKey) {
    printErr("publish: no API key — set --api-key or LYRIC_NUGET_API_KEY")
    return 1
  }

  // Run `dotnet nuget push`.
  val pushArgs: List[String] = newList()
  pushArgs.add("nuget")
  pushArgs.add("push")
  pushArgs.add(nupkgPath)
  pushArgs.add("--source")
  pushArgs.add(pushRegistry)
  pushArgs.add("--api-key")
  pushArgs.add(pushKey)
  if skipDuplicate {
    pushArgs.add("--skip-duplicate")
  }
  val pushExit = match Process.run("dotnet", pushArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("publish: dotnet nuget push failed: " + IOError.message(e))
      return 1
    }
  }
  if pushExit != 0 {
    return pushExit
  }

  Console.println("publish: pushed " + pkg.name + " " + pkg.version + " to " + pushRegistry)
  0
}

// ─────────────────────────────────────────────────────────────────────────────
// §11a. Search command
// ─────────────────────────────────────────────────────────────────────────────
func cmdSearch(argv: in slice[String]): Int {
  val positional: List[String] = newList()
  var allMode = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--all" {
      allMode = true
      i += 1
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Statement form rather than a `val x = if ... else { return 1 }`
  // expression: the F# stage-0 emitter miscompiles an if-expression
  // initializer whose else-arm diverges via `return` (stack underflow at
  // the merge point — caught by ILC during the Native AOT publish, #1494).
  var query = ""
  if allMode {
    query = ""
  } else if positional.count > 0 {
    query = positional[0]
  } else {
    printErr("search: provide a search term or use --all")
    printUsage()
    return 1
  }

  // Percent-encode the query to prevent injection through & # % characters.
  val encodedQuery = percentEncodeQuery(query)

  // Query the NuGet.org search API, filtered by the lyric-package tag.
  val searchUrl = "https://azuresearch-usnc.nuget.org/query?q=" + encodedQuery + "&packageType=lyric-package&take=20"
  val curlArgs: List[String] = newList()
  curlArgs.add("-fsSL")
  curlArgs.add(searchUrl)
  val raw = ProcessCapture.runCapture("curl", curlArgs, "")
  if Str.isEmpty(raw) {
    printErr("search: no response from NuGet search API (is curl available?)")
    return 1
  }

  // Scan the JSON for "id":"…" / "version":"…" / "description":"…" patterns.
  // We do NOT split on commas; instead we locate each key needle and extract
  // the string value character-by-character so commas inside descriptions
  // are handled correctly.
  val results: List[String] = newList()
  val idNeedle = "\"id\":\""
  val verNeedle = "\"version\":\""
  val descNeedle = "\"description\":\""
  var pos = 0
  while pos < raw.length {
    val tail = Str.substring(raw, pos, raw.length - pos)
    match Str.indexOf(tail, idNeedle) {
      case None -> {
        pos = raw.length
      }
      case Some(rel) -> {
        val idStart = pos + rel + idNeedle.length
        val (idVal, afterId) = jsonStringAt(raw, idStart)
        if idVal == "" {
          pos = pos + rel + 1
        } else {
          // Look for "version" and "description" in the remainder of this entry.
          val rest = Str.substring(raw, afterId, raw.length - afterId)
          val versionVal = match Str.indexOf(rest, verNeedle) {
            case None -> ""
            case Some(rv) -> {
              val (v, _) = jsonStringAt(raw, afterId + rv + verNeedle.length)
              v
            }
          }
          val descVal = match Str.indexOf(rest, descNeedle) {
            case None -> ""
            case Some(rd) -> {
              val (d, _) = jsonStringAt(raw, afterId + rd + descNeedle.length)
              d
            }
          }
          if versionVal != "" {
            results.add(idVal + "\t" + versionVal + "\t" + descVal)
          }
          pos = pos + rel + idNeedle.length + 1
        }
      }
    }
  }

  if results.count == 0 {
    Console.println("No packages found matching '" + query + "'.")
    return 0
  }

  for line in results.toArray() {
    Console.println(line)
  }
  0
}

// Percent-encode characters unsafe in a URL query string.
func percentEncodeQuery(q: in String): String {
  var r = ""
  var qi = 0
  while qi < q.length {
    val c = q[qi]
    if c == ' ' {
      r = r + "%20"
    } else if c == '%' {
      r = r + "%25"
    } else if c == '&' {
      r = r + "%26"
    } else if c == '+' {
      r = r + "%2B"
    } else if c == '#' {
      r = r + "%23"
    } else if c == '=' {
      r = r + "%3D"
    } else if c == '?' {
      r = r + "%3F"
    } else {
      r = r + ("" + c)
    }
    qi += 1
  }
  r
}

// Extract a JSON string value starting at `startPos` (position right after the
// opening double-quote).  Returns (value, endPos) where endPos is the position
// after the closing double-quote.  Handles `\"` escapes.
func jsonStringAt(json: in String, startPos: in Int): (String, Int) {
  if startPos >= json.length {
    return ("", startPos)
  }
  var s = ""
  var j = startPos
  var escaping = false
  while j < json.length {
    val c = json[j]
    if escaping {
      if c == 'n' {
        s = s + "\n"
      } else if c == 't' {
        s = s + "\t"
      } else if c == 'r' {
        s = s + "\r"
      } else if c == 'b' {
        s = s + "\u{0008}"
      } else if c == 'f' {
        s = s + "\u{000c}"
      } else {
        s = s + ("" + c)
      }
      escaping = false
    } else if c == '\\' {
      escaping = true
    } else if c == '"' {
      return (s, j + 1)
    } else {
      s = s + ("" + c)
    }
    j += 1
  };
  (s, j)
}
