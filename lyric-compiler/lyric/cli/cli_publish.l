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
import Std.Time as Time
import Lyric.Manifest as Mf
import Lyric.Pack as Pack
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11. Publish command
// ─────────────────────────────────────────────────────────────────────────────
// Build the `.nuspec` document for a published Lyric package.  Dependencies
// are emitted as `<dependency>` metadata inside a single net10.0 group
// (`dependenciesMetadata` is the pre-rendered `<dependency .../>` lines) —
// never as `<PackageReference>`, so `dotnet pack` copies them into the
// package without a `dotnet restore` that would fail NU1102 on a
// same-run-but-not-yet-indexed sibling (#5644).  `description` falls back to
// the package id when empty (NuGet requires a non-empty description).
pub func buildPublishNuspec(
  id: in String,
  version: in String,
  authors: in List[String],
  description: in String,
  license: in String,
  repository: in Option[String],
  dependenciesMetadata: in String,
  absDllPath: in String,
  dllBase: in String,
): String {
  val descText = if Str.isEmpty(description) { id } else { description }
  // NuGet <authors> is a comma-separated list.  Fall back to the package id
  // when the manifest declares no [package] authors (NuGet requires a
  // non-empty authors value).
  var authorsText = ""
  var ai = 0
  while ai < authors.count {
    if ai > 0 {
      authorsText = authorsText + ", "
    }
    authorsText = authorsText + authors[ai]
    ai = ai + 1
  }
  if Str.isEmpty(authorsText) {
    authorsText = id
  }
  var nuspec = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
  nuspec = nuspec + "<package>\n"
  nuspec = nuspec + "  <metadata>\n"
  nuspec = nuspec + "    <id>" + Pack.xmlEscape(id) + "</id>\n"
  nuspec = nuspec + "    <version>" + Pack.xmlEscape(version) + "</version>\n"
  nuspec = nuspec + "    <authors>" + Pack.xmlEscape(authorsText) + "</authors>\n"
  nuspec = nuspec + "    <description>" + Pack.xmlEscape(descText) + "</description>\n"
  if not Str.isEmpty(license) {
    nuspec = nuspec + "    <license type=\"expression\">" + Pack.xmlEscape(license) + "</license>\n"
  }
  match repository {
    case Some(r) -> {
      nuspec = nuspec + "    <repository type=\"git\" url=\"" + Pack.xmlEscape(r) + "\" />\n"
    }
    case None -> ()
  }
  nuspec = nuspec + "    <tags>lyric-package</tags>\n"
  if not Str.isEmpty(dependenciesMetadata) {
    nuspec = nuspec + "    <dependencies>\n"
    nuspec = nuspec + "      <group targetFramework=\"net10.0\">\n"
    nuspec = nuspec + dependenciesMetadata
    nuspec = nuspec + "      </group>\n"
    nuspec = nuspec + "    </dependencies>\n"
  }
  nuspec = nuspec + "  </metadata>\n"
  nuspec = nuspec + "  <files>\n"
  nuspec = nuspec + "    <file src=\"" + Pack.xmlEscape(absDllPath) + "\" target=\"lib/net10.0/" +
    Pack.xmlEscape(dllBase) +
    "\" />\n"
  nuspec = nuspec + "  </files>\n"
  nuspec = nuspec + "</package>\n"
  nuspec
}

// ─────────────────────────────────────────────────────────────────────────────
// wasm32 publish bundle (docs/35 section 8.1)
// ─────────────────────────────────────────────────────────────────────────────
/// The NPM package name for a Lyric package: lowercased, with every character
/// outside `a-z 0-9 . - _` replaced by `-`.  NPM rejects an empty name, one
/// starting with `.` or `_`, and one longer than 214 characters.
pub func npmPackageName(name: in String): Result[String, String] {
  val upperTable = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  val lowerTable = "abcdefghijklmnopqrstuvwxyz"
  var cleaned = ""
  var i = 0
  while i < name.length {
    val c = Str.substring(name, i, 1)
    val upperAt = Str.indexOfRaw(upperTable, c)
    if upperAt >= 0 {
      cleaned = cleaned + Str.substring(lowerTable, upperAt, 1)
    } else if Str.contains("abcdefghijklmnopqrstuvwxyz0123456789._-", c) {
      cleaned = cleaned + c
    } else {
      cleaned = cleaned + "-"
    }
    i += 1
  }
  if cleaned.length == 0 or cleaned.length > 214 {
    return Err(error = "package name '" + name + "' cannot be an NPM package name (1 to 214 characters)")
  }
  if Str.startsWith(cleaned, ".") or Str.startsWith(cleaned, "_") {
    return Err(error = "package name '" + name + "' cannot be an NPM package name (must not start with '.' or '_')")
  }
  Ok(value = cleaned)
}

/// The `package.json` of a wasm publish bundle.  `kind` is `"module"` (JS glue
/// `<stem>.js` and `<stem>.d.ts` beside the `.wasm`) or `"component"` (the
/// `.wasm` and its `.wit`, plus the `jco` bindings in `<stem>-js/` when
/// `hasBindings`).  `[npm]` rows become `dependencies`, so the consumer's
/// package manager installs what the `npm:` host imports reach.
pub func buildWasmPackageJson(
  npmName: in String,
  version: in String,
  description: in String,
  license: in String,
  repository: in Option[String],
  kind: in String,
  stem: in String,
  hasBindings: in Bool,
  npm: in Option[Mf.NpmSection],
): String {
  val files: List[String] = newList()
  files.add(stem + ".wasm")
  var entryFile = ""
  var types = ""
  if kind == "module" {
    files.add(stem + ".js")
    files.add(stem + ".d.ts")
    entryFile = stem + ".js"
    types = stem + ".d.ts"
  } else {
    files.add(stem + ".wit")
    if hasBindings {
      files.add(stem + "-js")
      entryFile = stem + "-js/" + stem + ".js"
      types = stem + "-js/" + stem + ".d.ts"
    }
  }
  var json = "{\n  \"name\": \"" + jsonEscape(npmName) + "\",\n  \"version\": \"" + jsonEscape(version) + "\""
  if description.length > 0 {
    json = json + ",\n  \"description\": \"" + jsonEscape(description) + "\""
  }
  if license.length > 0 {
    json = json + ",\n  \"license\": \"" + jsonEscape(license) + "\""
  }
  match repository {
    case Some(r) -> {
      json = json + ",\n  \"repository\": \"" + jsonEscape(r) + "\""
    }
    case None -> ()
  }
  json = json + ",\n  \"type\": \"module\""
  if entryFile.length > 0 {
    json = json + ",\n  \"main\": \"" + jsonEscape(entryFile) + "\""
  }
  if types.length > 0 {
    json = json + ",\n  \"types\": \"" + jsonEscape(types) + "\""
  }
  json = json + ",\n  \"files\": ["
  var fi = 0
  while fi < files.count {
    if fi > 0 {
      json = json + ", "
    }
    json = json + "\"" + jsonEscape(files[fi]) + "\""
    fi += 1
  }
  json = json + "]"
  match npm {
    case Some(n) -> if n.entries.count > 0 {
      json = json + ",\n  \"dependencies\": {\n"
      var ni = 0
      while ni < n.entries.count {
        if ni > 0 {
          json = json + ",\n"
        }
        json = json + "    \"" + jsonEscape(n.entries[ni].name) + "\": \"" + jsonEscape(n.entries[ni].version) + "\""
        ni += 1
      }
      json = json + "\n  }"
    }
    case None -> ()
  }
  json + "\n}\n"
}

/// Copy one file byte for byte.
func copyBundleFile(src: in String, dst: in String): Result[Unit, String] {
  match File.readBytes(src) {
    case Err(e) -> Err(error = "cannot read " + src + ": " + IOError.message(e))
    case Ok(bytes) -> match File.writeBytes(dst, bytes) {
      case Err(e) -> Err(error = "cannot write " + dst + ": " + IOError.message(e))
      case Ok(_) -> Ok(value = ())
    }
  }
}

/// `lyric publish --wasm`: stage the built `.wasm` and its sidecars and pack
/// them as `<name>-<version>.tgz`, the tarball `npm publish` accepts.
func publishWasmBundle(
  manifest: in Mf.Manifest,
  mfDir: in String,
  version: in String,
  wasmOverride: in Option[String],
  outputDir: in Option[String],
): Int {
  val pkg: Mf.PackageSection = manifest.packageSection
  val npmName = match npmPackageName(pkg.name) {
    case Ok(n) -> n
    case Err(e) -> {
      printErr("publish: " + e)
      return 1
    }
  }
  val wasmPath = match wasmOverride {
    case Some(w) -> w
    case None -> {
      val fileName = match manifest.project {
        case Some(proj) -> match proj.outputAssembly {
          case Some(asm) -> asm
          case None -> pkg.name + ".wasm"
        }
        case None -> pkg.name + ".wasm"
      }
      Path.join(Path.join(mfDir, "bin"), fileName)
    }
  }
  if not Str.endsWith(wasmPath, ".wasm") {
    printErr("publish: --wasm-file must name a .wasm file: " + wasmPath)
    return 1
  }
  if not File.fileExists(wasmPath) {
    printErr(
      "publish: wasm output not found: " + wasmPath + " - run `lyric build --shape module` or `--shape component` first"
    )
    return 1
  }
  val stemPath = Str.substring(wasmPath, 0, wasmPath.length - 5)
  val stem = Path.basename(stemPath)
  val srcDir = Path.dirname(wasmPath)
  val witPath = stemPath + ".wit"
  val jsPath = stemPath + ".js"
  val bindingsDir = stemPath + "-js"
  val isComponent = File.fileExists(witPath)
  val isModule = File.fileExists(jsPath) and File.fileExists(stemPath + ".d.ts")
  if isComponent and isModule {
    printErr(
      "publish: both " + stem + ".wit and " + stem + ".js sit beside " + wasmPath +
        " - remove the stale one so the shape is unambiguous"
    )
    return 1
  }
  if not isComponent and not isModule {
    printErr(
      "publish: neither " + stem + ".wit (component) nor " + stem + ".js with " + stem + ".d.ts (module) sits beside " +
        wasmPath +
        " - rebuild with `--shape module` or `--shape component`"
    )
    return 1
  }
  val kind = if isComponent { "component" } else { "module" }
  val hasBindings = isComponent and File.dirExists(bindingsDir)

  val outDir = match outputDir { case Some(d) -> d; case None -> Path.join(Path.join(mfDir, "bin"), "npm") }
  val stageRoot = Path.join(outDir, npmName + "-" + version + "-stage")
  val stageDir = Path.join(stageRoot, "package")
  if File.dirExists(stageRoot) {
    match File.deleteDirRecursive(stageRoot) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("publish: cannot clear " + stageRoot + ": " + IOError.message(e))
        return 1
      }
    }
  }
  match File.createDir(stageDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("publish: cannot create " + stageDir + ": " + IOError.message(e))
      return 1
    }
  }

  val copies: List[String] = newList()
  copies.add(stem + ".wasm")
  if isComponent {
    copies.add(stem + ".wit")
  } else {
    copies.add(stem + ".js")
    copies.add(stem + ".d.ts")
  }
  var ci = 0
  while ci < copies.count {
    match copyBundleFile(Path.join(srcDir, copies[ci]), Path.join(stageDir, copies[ci])) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("publish: " + e)
        return 1
      }
    }
    ci += 1
  }
  if hasBindings {
    val destBindings = Path.join(stageDir, stem + "-js")
    match File.createDir(destBindings) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("publish: cannot create " + destBindings + ": " + IOError.message(e))
        return 1
      }
    }
    val absSrc = if Path.isAbsolute(bindingsDir) {
      bindingsDir
    } else {
      Path.join(Environment.currentDirectory(), bindingsDir)
    }
    val listed = match File.listFilesRecursive(bindingsDir) {
      case Ok(l) -> l
      case Err(e) -> {
        printErr("publish: cannot list " + bindingsDir + ": " + IOError.message(e))
        return 1
      }
    }
    var li = 0
    while li < listed.count {
      val f = listed[li]
      val rel = if Str.startsWith(f, absSrc) {
        Str.substring(f, absSrc.length + 1)
      } else if Str.startsWith(f, bindingsDir) {
        Str.substring(f, bindingsDir.length + 1)
      } else {
        Path.basename(f)
      }
      val dst = Path.join(destBindings, rel)
      match File.createDir(Path.dirname(dst)) {
        case Ok(_) -> ()
        case Err(e) -> {
          printErr("publish: cannot create " + Path.dirname(dst) + ": " + IOError.message(e))
          return 1
        }
      }
      match copyBundleFile(f, dst) {
        case Ok(_) -> ()
        case Err(e) -> {
          printErr("publish: " + e)
          return 1
        }
      }
      li += 1
    }
  }

  val packageJson = buildWasmPackageJson(
    npmName,
    version,
    pkg.description,
    pkg.license,
    pkg.repository,
    kind,
    stem,
    hasBindings,
    manifest.npm
  )
  match File.writeText(Path.join(stageDir, "package.json"), packageJson) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("publish: cannot write package.json: " + IOError.message(e))
      return 1
    }
  }

  val tarball = Path.join(outDir, npmName + "-" + version + ".tgz")
  val tarArgs: List[String] = newList()
  tarArgs.add("-czf")
  tarArgs.add(tarball)
  tarArgs.add("-C")
  tarArgs.add(stageRoot)
  tarArgs.add("package")
  val tarExit = match Process.run("tar", tarArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("publish: tar failed: " + IOError.message(e))
      return 1
    }
  }
  match File.deleteDirRecursive(stageRoot) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  if tarExit != 0 {
    printErr("publish: tar exited with " + toString(tarExit))
    return tarExit
  }
  Console.println("publish: packed " + kind + " bundle " + tarball + " (publish with `npm publish " + tarball + "`)")
  0
}

func cmdPublish(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var dllOverride: Option[String] = None
  var outputDir: Option[String] = None
  var registryUrl: Option[String] = None
  var apiKey: Option[String] = None
  var skipDuplicate = false
  var packageVersionArg: Option[String] = None
  var wasmMode = false
  var wasmFileArg: Option[String] = None

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
    } else if arg == "--wasm" {
      wasmMode = true
      i += 1
    } else if arg == "--wasm-file" {
      if i + 1 < argv.length {
        wasmFileArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --wasm-file requires an argument")
        return 1
      }
    } else if arg == "--skip-duplicate" {
      skipDuplicate = true
      i += 1
    } else if arg == "--package-version" {
      if i + 1 < argv.length {
        packageVersionArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("publish: --package-version requires an argument")
        return 1
      }
    } else {
      printErr("publish: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  match packageVersionArg {
    case Some(v) -> match validatePackageVersionArg(v) {
      case Some(msg) -> {
        printErr("publish: " + msg)
        return 1
      }
      case None -> ()
    }
    case None -> ()
  }

  val mfPath = match manifestArg { case Some(p) -> p; case None -> "lyric.toml" }

  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("publish: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Mf.Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("publish: " + Mf.ManifestError.message(e))
      return 1
    }
  }

  // Warn when [workspace.overrides] are present — these should not ship.
  match manifest.workspace {
    case Some(ws) -> if ws.overrides.count > 0 {
      printErr("publish: warning: [workspace.overrides] is non-empty — override entries should not be committed")
    }
    case None -> ()
  }

  // Reject branch-form git deps — mutable refs cannot appear in a published manifest.
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    match dep.source {
      case Git(_, refKind, refValue, _) -> if refKind == "branch" {
        printErr(
          "publish: dep '" + dep.name + "' uses git branch '" + refValue +
            "' — mutable refs are not allowed in published packages"
        )
        return 1
      }
      case _ -> ()
    }
    di += 1
  }

  val pkg: Mf.PackageSection = manifest.packageSection
  val effectiveVersion = match packageVersionArg { case Some(v) -> v; case None -> pkg.version }
  val mfDir = Path.dirname(mfPath)
  if wasmMode {
    return publishWasmBundle(manifest, mfDir, effectiveVersion, wasmFileArg, outputDir)
  }
  match wasmFileArg {
    case Some(_) -> {
      printErr("publish: --wasm-file applies to --wasm only")
      return 1
    }
    case None -> ()
  }
  val dllPath = match dllOverride {
    case Some(d) -> d
    case None -> {
      val defaultDllName = match manifest.project {
        case Some(proj) -> match proj.outputAssembly {
          case Some(asm) -> asm
          case None -> pkg.name + ".dll"
        }
        case None -> pkg.name + ".dll"
      }
      Path.join(Path.join(mfDir, "bin"), defaultDllName)
    }
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
            printErr("publish: cannot parse workspace member manifest: " + Mf.ManifestError.message(e))
            return 1
          }
          case Ok(mf) -> match packageVersionArg { case Some(v) -> v; case None -> mf.packageSection.version }
        }
      }
      case Path(_) -> {
        printErr("publish: dep '" + dep.name + "' uses path source — not allowed in published packages")
        return 1
      }
      case Git(_, _, refValue, _) -> refValue  // tag name / SHA / branch (branch rejected above)
    }
    nuspecDeps = nuspecDeps + "        <dependency id=\"" + Pack.xmlEscape(dep.name) + "\" version=\"" +
      Pack.xmlEscape(version) +
      "\" />\n"
    si += 1
  }

  val absDllPath = if Path.isAbsolute(dllPath) { dllPath } else { Path.join(Environment.currentDirectory(), dllPath) }
  val dllBase = Path.basename(absDllPath)

  // Pack from a hand-authored .nuspec rather than a csproj carrying the deps
  // as <PackageReference>.  A PackageReference must be `dotnet restore`d, which
  // fails NU1102 when a sibling ecosystem package was pushed to nuget.org only
  // moments earlier and is not yet indexed — the whole ecosystem-publish race
  // (#5644): tier-3 libraries restoring against a just-published tier-1/2
  // package that nuget.org has not indexed yet.  In a .nuspec the same
  // dependencies are pure metadata: pack copies them straight into the
  // package's own <dependencies> without ever contacting the feed, so
  // publishing an interdependent set in one run never blocks on indexing.
  val nuspec = buildPublishNuspec(
    pkg.name,
    effectiveVersion,
    pkg.authors,
    pkg.description,
    pkg.license,
    pkg.repository,
    nuspecDeps,
    absDllPath,
    dllBase
  )

  val tmpNuspec = Path.join(mfDir, pkg.name + "-" + effectiveVersion + "-publish.nuspec")
  match File.writeText(tmpNuspec, nuspec) {
    case Err(e) -> {
      printErr("publish: cannot write temp nuspec: " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }

  // A minimal csproj whose only job is to point `dotnet pack` at the nuspec.
  // It declares no package dependencies, so its implicit restore is trivial
  // and offline — no nuget.org round-trip, no NU1102.  CS2008 ("no source
  // files") is expected: there is nothing to compile, only a package to pack.
  var csproj = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  csproj = csproj + "  <PropertyGroup>\n"
  csproj = csproj + "    <TargetFramework>net10.0</TargetFramework>\n"
  csproj = csproj + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  csproj = csproj + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  csproj = csproj + "    <EnableDefaultItems>false</EnableDefaultItems>\n"
  csproj = csproj + "    <NoWarn>$(NoWarn);NU5128;CS2008</NoWarn>\n"
  csproj = csproj + "    <NuspecFile>" + Pack.xmlEscape(Path.basename(tmpNuspec)) + "</NuspecFile>\n"
  csproj = csproj + "  </PropertyGroup>\n"
  csproj = csproj + "</Project>\n"

  val tmpCsproj = Path.join(mfDir, pkg.name + "-" + effectiveVersion + "-publish.csproj")
  match File.writeText(tmpCsproj, csproj) {
    case Err(e) -> {
      printErr("publish: cannot write temp csproj: " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }

  // Pack.  No explicit restore step: the csproj carries no package
  // dependencies (they live in the nuspec as metadata), so `dotnet pack`'s
  // implicit restore is offline-trivial and the nuspec supplies both the
  // payload DLL and the dependency list.
  val packArgs: List[String] = newList()
  packArgs.add("pack")
  packArgs.add(tmpCsproj)
  packArgs.add("-o")
  packArgs.add(outDir)
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

  val nupkgPath = Path.join(outDir, pkg.name + "." + effectiveVersion + ".nupkg")
  Console.println("publish: packed " + nupkgPath)

  // Sign the .nupkg if LYRIC_NUGET_SIGNING_CERT points at a PFX file.
  val signingCert = match Environment.getVar("LYRIC_NUGET_SIGNING_CERT") { case Ok(p) -> p; case Err(_) -> "" }
  if not Str.isEmpty(signingCert) and File.fileExists(signingCert) {
    val signingPassword = match Environment.getVar("LYRIC_NUGET_SIGNING_CERT_PASSWORD") {
      case Ok(p) -> p
      case Err(_) -> ""
    }
    val signingTimestamper = match Environment.getVar("LYRIC_NUGET_SIGNING_TIMESTAMPER") {
      case Ok(t) -> t
      case Err(_) -> "http://timestamp.digicert.com"
    }
    val signArgs: List[String] = newList()
    signArgs.add("nuget")
    signArgs.add("sign")
    signArgs.add(nupkgPath)
    signArgs.add("--certificate-path")
    signArgs.add(signingCert)
    // `dotnet nuget sign` has no env-var or stdin form for the certificate
    // password (as of the .NET SDK versions this targets) — CLI argument is
    // the only option. This is a known, brief exposure window (visible via
    // /proc/<pid>/cmdline or `ps aux` for the duration of this subprocess);
    // acceptable on ephemeral, isolated CI runners. Migrate to a
    // `--certificate-password-stdin`-style flag if/when the SDK adds one (#4001).
    if not Str.isEmpty(signingPassword) {
      signArgs.add("--certificate-password")
      signArgs.add(signingPassword)
    }
    signArgs.add("--timestamper")
    signArgs.add(signingTimestamper)
    signArgs.add("--overwrite")
    val signExit = match Process.run("dotnet", signArgs) {
      case Ok(code) -> code
      case Err(e) -> {
        printErr("publish: dotnet nuget sign failed: " + IOError.message(e))
        return 1
      }
    }
    if signExit != 0 {
      return signExit
    }
    Console.println("publish: signed " + nupkgPath)
  }

  // Determine push registry and API key.
  val pushRegistry = match registryUrl {
    case Some(url) -> url
    case None -> match manifest.registry {
      case Some(rc) -> match rc.dotnet {
        case Some(url) -> url
        case None -> "https://api.nuget.org/v3/index.json"
      }
      case None -> "https://api.nuget.org/v3/index.json"
    }
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

  Console.println("publish: pushed " + pkg.name + " " + effectiveVersion + " to " + pushRegistry)
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
    val c = Str.charAtOrReplacement(q, qi)
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
      r = r + Str.substring(q, qi, 1)
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
    val c = Str.charAtOrReplacement(json, j)
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
        s = s + Str.substring(json, j, 1)
      }
      escaping = false
    } else if c == '\\' {
      escaping = true
    } else if c == '"' {
      return (s, j + 1)
    } else {
      s = s + Str.substring(json, j, 1)
    }
    j += 1
  };
  (s, j)
}
