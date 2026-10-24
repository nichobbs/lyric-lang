package Lyric.Cli

import Std.Core
import Std.Collections
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.ProcessCapture as ProcessCapture
import Std.Hash as Hash
import Std.Directory as Dir
import Std.Console as Console
import Jvm.ZipReader as Zip
import Lyric.Manifest as Mf

// ─────────────────────────────────────────────────────────────────────────────
// `[native.libs.<name>]`: C libraries a `--target native` program links
// (docs/67 §6, D191).
// ─────────────────────────────────────────────────────────────────────────────
/// A declared library and the directory of the manifest that declared it, which
/// its `dir` is relative to.
pub record NativeLibDecl {
  spec: Mf.NativeLibSpec
  baseDir: String
}

/// What a build does about the libraries: clang link arguments, the shared
/// library files that ship next to the executable, and what went wrong.
pub record NativeLinkPlan {
  args: List[String]
  bundle: List[String]
  errors: List[String]
}

pub func emptyNativeLinkPlan(): NativeLinkPlan {
  NativeLinkPlan(args = newList(), bundle = newList(), errors = newList())
}

func isDarwinTriple(triple: in String): Bool {
  Str.contains(triple, "apple") or Str.contains(triple, "darwin")
}

/// How a target names and finds its libraries: "darwin" (`lib<link>.dylib`,
/// `@loader_path`), "windows" (`<link>.dll` and `<link>.lib`; the loader looks
/// beside the executable first, so no run path, docs/67 G9) or "elf"
/// (`lib<link>.so`, `$ORIGIN`).
func libOsOf(triple: in String): String {
  if isDarwinTriple(triple) {
    "darwin"
  } else if Str.contains(triple, "windows") or Str.contains(triple, "win32") {
    "windows"
  } else {
    "elf"
  }
}

func hostTripleOrEmpty(): String {
  val args: List[String] = newList()
  args.add("-print-effective-triple")
  match Process.runCapture("clang", args, 30000) {
    case Ok(res) -> if res.exitCode == 0 { Str.trim(res.stdout) } else { "" }
    case Err(_) -> ""
  }
}

func fileNameOf(path: in String): String = Path.basename(path)

func linkNameOf(spec: in Mf.NativeLibSpec): String = if spec.link.length > 0 { spec.link } else { spec.name }

/// The shared-library files of `link` in `dir`: `lib<link>.so` and its
/// versioned names (`.so.3`, `.so.3.2.0`), `lib<link>.dylib` and its versioned
/// names, or `<link>.dll` on Windows.
func sharedLibraryFiles(dir: in String, link: in String, os: in String): List[String] {
  val found: List[String] = newList()
  match File.listFiles(dir) {
    case Err(_) -> ()
    case Ok(files) -> {
      for f in files {
        val name = fileNameOf(f)
        if os == "darwin" {
          if Str.startsWith(name, "lib" + link + ".") and Str.endsWith(name, ".dylib") {
            found.add(f)
          }
        } else if os == "windows" {
          if Str.toLower(name) == Str.toLower(link + ".dll") {
            found.add(f)
          }
        } else if name == "lib" + link + ".so" or Str.startsWith(name, "lib" + link + ".so.") {
          found.add(f)
        }
      }
    }
  }
  found
}

func resolveDirLib(
  decl: in NativeLibDecl,
  os: in String,
  args: in List[String],
  bundle: in List[String],
  errors: in List[String],
): Unit {
  val spec = decl.spec
  val link = linkNameOf(spec)
  val dir = if Path.isAbsolute(spec.dir) { spec.dir } else { Path.join(decl.baseDir, spec.dir) }
  if not File.dirExists(dir) {
    errors.add(
      "native library '" + spec.name + "': the directory " + dir + " does not exist (dir = \"" + spec.dir + "\")"
    )
    return
  }
  val shared = sharedLibraryFiles(dir, link, os)
  // On Windows a library links through `<link>.lib`, a static library or the
  // import library of `<link>.dll`, so the `.lib` must be there either way.
  val linkName = if os == "windows" { link + ".lib" } else { "lib" + link + ".a" }
  if os == "windows" and not File.fileExists(Path.join(dir, linkName)) {
    errors.add("native library '" + spec.name + "': " + dir + " holds no " + linkName)
    return
  }
  if shared.count == 0 and not File.fileExists(Path.join(dir, linkName)) {
    val ext = if os == "darwin" { ".dylib" } else { ".so" }
    errors.add("native library '" + spec.name + "': " + dir + " holds no lib" + link + ext + " or " + linkName)
    return
  }
  if os == "darwin" and shared.count > 0 {
    // A dylib records its own install name, and the executable records that name
    // when it links: one built with a bare `clang -shared` names its build path,
    // which the bundled copy would not satisfy (D230).
    val stageDir = Path.join(Path.join(Path.join(Path.join(decl.baseDir, ".lyric"), "native"), "_dylibs"), spec.name)
    val staged: List[String] = newList()
    var anyStaged = false
    for f in shared {
      match stageDarwinDylib(f, stageDir) {
        case Ok(p) -> {
          staged.add(p)
          if p != f {
            anyStaged = true
          }
        }
        case Err(msg) -> {
          errors.add("native library '" + spec.name + "': " + msg)
          return
        }
      }
    }
    if anyStaged {
      args.add("-L" + stageDir)
    }
    args.add("-L" + dir)
    args.add("-l" + link)
    for f in staged {
      bundle.add(f)
    }
    return
  }
  args.add("-L" + dir)
  args.add("-l" + link)
  for f in shared {
    bundle.add(f)
  }
}

/// The install name (`LC_ID_DYLIB`) of a Mach-O dynamic library, "" when it cannot be read.
func darwinInstallName(path: in String): String {
  val args: List[String] = newList()
  args.add("-D")
  args.add(path)
  match Process.runCapture("otool", args, 60000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        return ""
      }
      val lines = Str.split(Str.trim(res.stdout), "\n")
      if lines.length < 2 {
        return ""
      }
      Str.trim(lines[lines.length - 1])
    }
    case Err(_) -> ""
  }
}

func runToolOrError(tool: in String, args: in List[String]): Option[String] {
  match Process.runCapture(tool, args, 120000) {
    case Ok(res) -> if res.exitCode == 0 {
      None
    } else {
      Some(value = tool + " failed: " + Str.trim(res.stderr + res.stdout))
    }
    case Err(e) -> Some(value = tool + " could not be started: " + e)
  }
}

/// A copy of the dylib `path` whose install name is `@rpath/<file name>`, in
/// `stageDir`, so that a program linking it finds the copy bundled with the
/// executable by run path.  A dylib that already names itself with `@rpath/`
/// (SDL3, wgpu-native) is used as it is.  The copy is signed ad hoc again, since
/// rewriting the install name invalidates the signature arm64 macOS demands.
func stageDarwinDylib(path: in String, stageDir: in String): Result[String, String] {
  val id = darwinInstallName(path)
  if id.length == 0 {
    return Err(error = "cannot read the install name of " + path + " (otool -D)")
  }
  if Str.startsWith(id, "@rpath/") {
    return Ok(value = path)
  }
  match Dir.createRecursive(stageDir) {
    case Ok(_) -> ()
    case Err(_) -> return Err(error = "cannot create " + stageDir)
  }
  val dest = Path.join(stageDir, fileNameOf(path))
  match File.readBytes(path) {
    case Err(_) -> return Err(error = "cannot read " + path)
    case Ok(bytes) -> match File.writeBytes(dest, bytes) {
      case Ok(_) -> ()
      case Err(_) -> return Err(error = "cannot write " + dest)
    }
  }
  val idArgs: List[String] = newList()
  idArgs.add("-id")
  idArgs.add("@rpath/" + fileNameOf(path))
  idArgs.add(dest)
  match runToolOrError("install_name_tool", idArgs) {
    case Some(msg) -> return Err(error = msg)
    case None -> ()
  }
  val signArgs: List[String] = newList()
  signArgs.add("--force")
  signArgs.add("-s")
  signArgs.add("-")
  signArgs.add(dest)
  match runToolOrError("codesign", signArgs) {
    case Some(msg) -> return Err(error = msg)
    case None -> ()
  }
  Ok(value = dest)
}

/// Where the prebuilt archive for `triple` is restored: beside the manifest
/// that declares the library, under `.lyric/native/<name>/<triple>`.
pub func nativePrebuiltDir(decl: in NativeLibDecl, triple: in String): String {
  Path.join(Path.join(Path.join(Path.join(decl.baseDir, ".lyric"), "native"), decl.spec.name), triple)
}

/// The architecture and operating-system family of a target triple, so that
/// `x86_64-pc-linux-gnu` (Ubuntu's clang), `x86_64-unknown-linux-gnu` and
/// `x86_64-redhat-linux-gnu` name one platform.
func platformKey(triple: in String): String {
  val parts = Str.split(triple, "-")
  var arch = if parts.length > 0 { parts[0] } else { "" }
  if arch == "arm64" {
    arch = "aarch64"
  }
  if arch == "amd64" {
    arch = "x86_64"
  }
  var os = "other"
  if Str.contains(triple, "linux") {
    os = "linux"
  } else if Str.contains(triple, "apple") or Str.contains(triple, "darwin") or Str.contains(triple, "macos") {
    os = "darwin"
  } else if Str.contains(triple, "windows") or Str.contains(triple, "win32") {
    os = "windows"
  }
  arch + "-" + os
}

/// The prebuilt archive declared for `triple`: the exact triple, else the one for
/// the same architecture and operating system.
func prebuiltFor(spec: in Mf.NativeLibSpec, triple: in String): Option[Mf.NativePrebuilt] {
  for p in spec.prebuilt {
    if p.triple == triple {
      return Some(value = p)
    }
  }
  val key = platformKey(triple)
  for p in spec.prebuilt {
    if platformKey(p.triple) == key {
      return Some(value = p)
    }
  }
  None
}

func readMarker(dir: in String): String {
  match File.readText(Path.join(dir, ".sha256")) {
    case Ok(t) -> Str.trim(t)
    case Err(_) -> ""
  }
}

func resolvePrebuiltLib(
  decl: in NativeLibDecl,
  triple: in String,
  os: in String,
  args: in List[String],
  bundle: in List[String],
  errors: in List[String],
): Unit {
  val spec = decl.spec
  match prebuiltFor(spec, triple) {
    case None -> {
      val have: List[String] = newList()
      for p in spec.prebuilt {
        have.add(p.triple)
      }
      errors.add(
        "native library '" + spec.name + "' has no prebuilt archive for " + triple + " (declared: " +
          Str.joinList(", ", have) +
          ")"
      )
    }
    case Some(p) -> {
      val dir = nativePrebuiltDir(decl, p.triple)
      if readMarker(dir) != p.sha256 {
        errors.add("native library '" + spec.name + "': the " + triple + " archive is not restored; run `lyric restore`")
        return
      }
      val restored = NativeLibDecl(
        spec = Mf.NativeLibSpec(
          name = spec.name,
          link = spec.link,
          version = spec.version,
          pkgConfig = "",
          dir = dir
        ),
        baseDir = decl.baseDir
      )
      resolveDirLib(restored, os, args, bundle, errors)
      // Every DLL a Windows archive extracts ships: the library's own DLL may
      // keep its upstream name (an import library records the DLL it loads,
      // whatever the `.lib` is called), and the DLLs it depends on come too.
      if os == "windows" {
        match File.listFiles(dir) {
          case Ok(files) -> {
            for f in files {
              if Str.endsWith(Str.toLower(f), ".dll") and not stringListContains(bundle, f) {
                bundle.add(f)
              }
            }
          }
          case Err(_) -> ()
        }
      }
    }
  }
}

func fileNameFromUrl(url: in String): String {
  val noQuery = if Str.contains(url, "?") { Str.substring(url, 0, Str.indexOfRaw(url, "?")) } else { url }
  Path.basename(noQuery)
}

func writeIntBytes(path: in String, ints: in List[Int]): Bool {
  val bytes: List[Byte] = newList()
  for n in ints {
    bytes.add(n.toByte())
  }
  match File.writeBytes(path, bytes.toArray()) {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

/// Fetches, verifies and unpacks one prebuilt archive into its restore directory.
/// The file at `url` must hash to the manifest's `sha256`; anything else is refused
/// before it is unpacked.  Returns what failed.
pub func restorePrebuilt(decl: in NativeLibDecl, p: in Mf.NativePrebuilt): List[String] {
  val errors: List[String] = newList()
  val label = "native library '" + decl.spec.name + "' (" + p.triple + ")"
  val dir = nativePrebuiltDir(decl, p.triple)
  if readMarker(dir) == p.sha256 {
    Console.println("restore: " + label + " is up to date")
    return errors
  }
  // A pin change restores into an empty directory: files of the previous archive
  // (an old `libfoo.so.2`) would otherwise be bundled beside the new ones.
  if File.dirExists(dir) {
    val _ = File.deleteDirRecursive(dir)
  }
  match Dir.createRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> {
      errors.add(label + ": cannot create " + dir)
      return errors
    }
  }
  val download = Path.join(dir, ".download")
  val curlArgs: List[String] = newList()
  curlArgs.add("-fsSL")
  curlArgs.add("--retry")
  curlArgs.add("2")
  curlArgs.add("-o")
  curlArgs.add(download)
  curlArgs.add(p.url)
  Console.println("restore: " + label + " <- " + p.url)
  val res = ProcessCapture.runCaptureWithDiagnosticsTimeout("curl", curlArgs, "", 900000)
  if res.exitCode != 0 {
    errors.add(
      label + ": downloading " + p.url + " failed (curl exit " + Str.fromInt(res.exitCode) + "): " + Str.trim(res.stderr)
    )
    return errors
  }
  val bytes = match File.readBytes(download) {
    case Ok(b) -> b
    case Err(_) -> {
      errors.add(label + ": cannot read the downloaded file " + download)
      return errors
    }
  }
  val got = Str.toLower(Hash.sha256OfBytes(bytes))
  if got != p.sha256 {
    val _ = File.deleteFile(download)
    errors.add(label + ": checksum mismatch for " + p.url + ": expected " + p.sha256 + ", got " + got)
    return errors
  }
  if p.members.count == 0 {
    val dest = Path.join(dir, fileNameFromUrl(p.url))
    match File.writeBytes(dest, bytes) {
      case Ok(_) -> ()
      case Err(_) -> {
        errors.add(label + ": cannot write " + dest)
        return errors
      }
    }
  } else {
    val entries = Zip.readZipEntries(bytes)
    for spec in p.members {
      val m = Mf.prebuiltMemberPath(spec)
      val name = Mf.prebuiltMemberFileName(spec)
      match Zip.extractByName(bytes, entries, m) {
        case None -> {
          errors.add(label + ": the archive has no member '" + m + "'")
          return errors
        }
        case Some(ints) -> if not writeIntBytes(Path.join(dir, name), ints) {
          errors.add(label + ": cannot write " + name)
          return errors
        }
      }
    }
  }
  val _ = File.deleteFile(download)
  match File.writeText(Path.join(dir, ".sha256"), p.sha256) {
    case Ok(_) -> ()
    case Err(_) -> errors.add(label + ": cannot record the restore")
  }
  errors
}

/// Restores every prebuilt archive the declarations list for the given triples.
pub func restoreNativeLibs(decls: in List[NativeLibDecl], triples: in List[String]): List[String] {
  val errors: List[String] = newList()
  val seen: List[String] = newList()
  for d in decls {
    if d.spec.prebuilt.count > 0 and not stringListContains(seen, d.spec.name) {
      seen.add(d.spec.name)
      for t in triples {
        match prebuiltFor(d.spec, t) {
          case Some(p) -> {
            for e in restorePrebuilt(d, p) {
              errors.add(e)
            }
          }
          case None -> ()
        }
      }
    }
  }
  errors
}

/// The triples a restore fetches for: the host's and the manifest's `[native].triple`.
pub func restoreTriples(manifest: in Mf.Manifest): List[String] {
  val triples: List[String] = newList()
  val host = hostTripleOrEmpty()
  if host.length > 0 {
    triples.add(host)
  }
  match manifest.native {
    case Some(nc) -> if nc.triple.length > 0 and not stringListContains(triples, nc.triple) { triples.add(nc.triple) }
    case None -> ()
  }
  triples
}

func resolvePkgConfigLib(
  decl: in NativeLibDecl,
  os: in String,
  args: in List[String],
  bundle: in List[String],
  errors: in List[String],
): Unit {
  val spec = decl.spec
  if spec.version.length > 0 {
    val vArgs: List[String] = newList()
    vArgs.add("--atleast-version=" + spec.version)
    vArgs.add(spec.pkgConfig)
    match Process.runCapture("pkg-config", vArgs, 30000) {
      case Err(e) -> {
        errors.add("native library '" + spec.name + "': pkg-config could not be started (" + e + ")")
        return
      }
      case Ok(res) -> if res.exitCode != 0 {
        errors.add(
          "native library '" + spec.name + "': pkg-config package '" + spec.pkgConfig + "' is missing or older than " +
            spec.version
        )
        return
      }
    }
  }
  val lArgs: List[String] = newList()
  lArgs.add("--libs")
  lArgs.add(spec.pkgConfig)
  match Process.runCapture("pkg-config", lArgs, 30000) {
    case Err(e) -> errors.add("native library '" + spec.name + "': pkg-config could not be started (" + e + ")")
    case Ok(res) -> {
      if res.exitCode != 0 {
        errors.add(
          "native library '" + spec.name + "': pkg-config does not know '" + spec.pkgConfig + "': " + Str.trim(res.stderr)
        )
        return
      }
      // Every token `pkg-config --libs` prints is a link argument (`-L`, `-l`, `-pthread`,
      // `-Wl,...`, a static archive path); only blanks are dropped.
      val flat = Str.replace(Str.replace(Str.replace(res.stdout, "\n", " "), "\t", " "), "\r", " ")
      val libDirs: List[String] = newList()
      val names: List[String] = newList()
      for tok in Str.split(Str.trim(flat), " ") {
        if tok.length > 0 {
          args.add(tok)
          if Str.startsWith(tok, "-L") and tok.length > 2 {
            libDirs.add(Str.substring(tok, 2))
          } else if Str.startsWith(tok, "-l") and tok.length > 2 {
            names.add(Str.substring(tok, 2))
          }
        }
      }
      if os == "windows" {
        bundlePkgConfigDlls(libDirs, names, bundle)
      }
    }
  }
}

/// Windows has no system library directory the loader searches, so the DLLs a
/// pkg-config library links are bundled like a `dir` library's: `<name>.dll`
/// beside its import library, or in the `bin` directory next to that `lib`
/// directory (the layout vcpkg and a CMake install use).  A name with no DLL
/// (a static library, or a Windows system library) bundles nothing.
func bundlePkgConfigDlls(libDirs: in List[String], names: in List[String], bundle: in List[String]): Unit {
  for name in names {
    var found = false
    for d in libDirs {
      if not found {
        for candidate in [Path.join(d, name + ".dll"), Path.join(Path.join(Path.dirname(d), "bin"), name + ".dll")] {
          if not found and File.fileExists(candidate) {
            found = true
            if not stringListContains(bundle, candidate) {
              bundle.add(candidate)
            }
          }
        }
      }
    }
  }
}

/// Resolves `decls` (the project's, then its dependencies') for `triple`
/// ("" is the host).  A library named twice is resolved once, from the first
/// declaration, so a consumer overrides what a dependency declares.
pub func resolveNativeLibs(decls: in List[NativeLibDecl], triple: in String): NativeLinkPlan {
  val args: List[String] = newList()
  val bundle: List[String] = newList()
  val errors: List[String] = newList()
  if decls.count == 0 {
    return NativeLinkPlan(args = args, bundle = bundle, errors = errors)
  }
  val effTriple = if triple.length > 0 { triple } else { hostTripleOrEmpty() }
  if Str.startsWith(effTriple, "wasm32") {
    errors.add("[native.libs] is not supported for " + effTriple + ": a WebAssembly build links no C libraries")
    return NativeLinkPlan(args = args, bundle = bundle, errors = errors)
  }
  val os = libOsOf(effTriple)
  val seen: List[String] = newList()
  for d in decls {
    if not stringListContains(seen, d.spec.name) {
      seen.add(d.spec.name)
      // A triple with a prebuilt archive uses it; `pkg_config` serves the rest.
      val hasArchive = match prebuiltFor(d.spec, effTriple) { case Some(_) -> true; case None -> false }
      if d.spec.prebuilt.count > 0 and (hasArchive or d.spec.pkgConfig.length == 0) {
        resolvePrebuiltLib(d, effTriple, os, args, bundle, errors)
      } else if d.spec.pkgConfig.length > 0 {
        resolvePkgConfigLib(d, os, args, bundle, errors)
      } else {
        resolveDirLib(d, os, args, bundle, errors)
      }
    }
  }
  if bundle.count > 0 and os != "windows" {
    if os == "darwin" {
      // Beside the executable, and where an `.app` bundle keeps its libraries (D230).
      args.add("-Wl,-rpath,@loader_path")
      args.add("-Wl,-rpath,@executable_path/../Frameworks")
    } else {
      args.add("-Wl,-rpath,$ORIGIN")
    }
  }
  NativeLinkPlan(args = args, bundle = bundle, errors = errors)
}

/// Copies the plan's shared libraries next to the executable, where the
/// `$ORIGIN` / `@loader_path` run path (and the Windows loader) finds them.  Returns what failed.
pub func bundleNativeLibs(plan: in NativeLinkPlan, exePath: in String): List[String] {
  val errors: List[String] = newList()
  val outDir = Path.dirname(exePath)
  for f in plan.bundle {
    val dest = Path.join(outDir, fileNameOf(f))
    match File.readBytes(f) {
      case Err(_) -> errors.add("cannot read the shared library " + f)
      case Ok(bytes) -> match File.writeBytes(dest, bytes) {
        case Ok(_) -> ()
        case Err(_) -> errors.add("cannot write " + dest)
      }
    }
  }
  errors
}

/// The `NativeLibDecl`s of a manifest's own `[native.libs]` tables.
pub func nativeLibDeclsOf(manifest: in Mf.Manifest, manifestDir: in String): List[NativeLibDecl] {
  val decls: List[NativeLibDecl] = newList()
  match manifest.native {
    case Some(nc) -> {
      for s in nc.libs {
        decls.add(NativeLibDecl(spec = s, baseDir = manifestDir))
      }
    }
    case None -> ()
  }
  decls
}

// ─────────────────────────────────────────────────────────────────────────────
// `[native.app]`: a macOS `.app` bundle (docs/67 §6, D230).
// ─────────────────────────────────────────────────────────────────────────────
/// Whether `triple` ("" is the host) names a macOS target.
pub func isDarwinTarget(triple: in String): Bool {
  val eff = if triple.length > 0 { triple } else { hostTripleOrEmpty() }
  isDarwinTriple(eff)
}

func xmlEscape(s: in String): String {
  val amp = Str.replace(s, "&", "&amp;")
  val lt = Str.replace(amp, "<", "&lt;")
  val gt = Str.replace(lt, ">", "&gt;")
  val quot = Str.replace(gt, "\"", "&quot;")
  Str.replace(quot, "'", "&apos;")
}

/// A `CFBundleIdentifier` is reverse-DNS: letters, digits, hyphens and periods.
func bundleIdentifierPart(s: in String): String {
  val allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."
  var cleaned = ""
  var i = 0
  while i < s.length {
    val ch = Str.substring(s, i, 1)
    cleaned = cleaned + (if Str.contains(allowed, ch) { ch } else { "-" })
    i += 1
  }
  cleaned
}

/// The `Info.plist` of the bundle for `exeName`, with `app`'s fields and the defaults
/// documented on `Mf.NativeApp`.
pub func infoPlistText(app: in Mf.NativeApp, exeName: in String): String {
  val identifier = if app.identifier.length > 0 { app.identifier } else { "lyric." + bundleIdentifierPart(exeName) }
  val name = if app.name.length > 0 { app.name } else { exeName }
  val version = if app.version.length > 0 { app.version } else { "0.1.0" }
  val keys: List[String] = newList()
  val values: List[String] = newList()
  keys.add("CFBundleExecutable")
  values.add(exeName)
  keys.add("CFBundleIdentifier")
  values.add(identifier)
  keys.add("CFBundleName")
  values.add(name)
  keys.add("CFBundleDisplayName")
  values.add(name)
  keys.add("CFBundlePackageType")
  values.add("APPL")
  keys.add("CFBundleInfoDictionaryVersion")
  values.add("6.0")
  keys.add("CFBundleShortVersionString")
  values.add(version)
  keys.add("CFBundleVersion")
  values.add(version)
  keys.add("LSMinimumSystemVersion")
  values.add("11.0")
  keys.add("NSPrincipalClass")
  values.add("NSApplication")
  var body = ""
  var i = 0
  while i < keys.count {
    body = body + "  <key>" + keys[i] + "</key>\n  <string>" + xmlEscape(values[i]) + "</string>\n"
    i += 1
  }
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
    "<plist version=\"1.0\">\n<dict>\n" +
    body +
    "  <key>NSHighResolutionCapable</key>\n  <true/>\n</dict>\n</plist>\n"
}

/// Assembles `<exe>.app` beside the finished executable `exePath`: the executable in
/// `Contents/MacOS`, the plan's shared libraries in `Contents/Frameworks` (the
/// `@executable_path/../Frameworks` run path the link added finds them) and an
/// `Info.plist`.  The loose executable stays where it is, so `lyric run` is unaffected.
/// Signing and notarisation are not done: the executable and the libraries carry the
/// ad-hoc signature the linker and `stageDarwinDylib` gave them.  Returns the bundle's
/// path, or the reason it could not be written.
pub func assembleMacApp(app: in Mf.NativeApp, plan: in NativeLinkPlan, exePath: in String): Result[String, String] {
  val exeName = fileNameOf(exePath)
  val bundle = Path.join(Path.dirname(exePath), exeName + ".app")
  val contents = Path.join(bundle, "Contents")
  val macosDir = Path.join(contents, "MacOS")
  val frameworks = Path.join(contents, "Frameworks")
  if File.dirExists(bundle) {
    match File.deleteDirRecursive(bundle) {
      case Ok(_) -> ()
      case Err(_) -> return Err(error = "cannot replace the existing " + bundle)
    }
  }
  match Dir.createRecursive(macosDir) {
    case Ok(_) -> ()
    case Err(_) -> return Err(error = "cannot create " + macosDir)
  }
  val cpArgs: List[String] = newList()
  cpArgs.add(exePath)
  cpArgs.add(Path.join(macosDir, exeName))
  match runToolOrError("cp", cpArgs) {
    case Some(msg) -> return Err(error = msg)
    case None -> ()
  }
  if plan.bundle.count > 0 {
    match Dir.createRecursive(frameworks) {
      case Ok(_) -> ()
      case Err(_) -> return Err(error = "cannot create " + frameworks)
    }
    for f in plan.bundle {
      match File.readBytes(f) {
        case Err(_) -> return Err(error = "cannot read the shared library " + f)
        case Ok(bytes) -> match File.writeBytes(Path.join(frameworks, fileNameOf(f)), bytes) {
          case Ok(_) -> ()
          case Err(_) -> return Err(error = "cannot write into " + frameworks)
        }
      }
    }
  }
  match File.writeText(Path.join(contents, "Info.plist"), infoPlistText(app, exeName)) {
    case Ok(_) -> ()
    case Err(_) -> return Err(error = "cannot write the Info.plist")
  }
  Ok(value = bundle)
}

/// `[native.app]` as an `assembleMacApp` input, for a build whose target is `triple`:
/// None unless the manifest asks for a bundle and the target is macOS (the table is
/// ignored for other targets so one manifest serves every platform).
pub func macAppFor(nc: in Option[Mf.NativeConfig], triple: in String): Option[Mf.NativeApp] {
  match nc {
    case Some(c) -> match c.app {
      case Some(a) -> if isDarwinTarget(triple) { Some(value = a) } else { None }
      case None -> None
    }
    case None -> None
  }
}
