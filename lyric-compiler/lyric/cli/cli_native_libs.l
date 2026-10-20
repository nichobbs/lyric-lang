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

/// The shared-library files of `lib<link>` in `dir`: `lib<link>.so`, its
/// versioned names (`.so.3`, `.so.3.2.0`), or `lib<link>.dylib` and its versioned names.
func sharedLibraryFiles(dir: in String, link: in String, darwin: in Bool): List[String] {
  val found: List[String] = newList()
  match File.listFiles(dir) {
    case Err(_) -> ()
    case Ok(files) -> {
      for f in files {
        val name = fileNameOf(f)
        if darwin {
          if Str.startsWith(name, "lib" + link + ".") and Str.endsWith(name, ".dylib") {
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
  darwin: in Bool,
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
  val shared = sharedLibraryFiles(dir, link, darwin)
  val staticName = Path.join(dir, "lib" + link + ".a")
  if shared.count == 0 and not File.fileExists(staticName) {
    val ext = if darwin { ".dylib" } else { ".so" }
    errors.add("native library '" + spec.name + "': " + dir + " holds no lib" + link + ext + " or lib" + link + ".a")
    return
  }
  args.add("-L" + dir)
  args.add("-l" + link)
  for f in shared {
    bundle.add(f)
  }
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
  darwin: in Bool,
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
      resolveDirLib(restored, darwin, args, bundle, errors)
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
    for m in p.members {
      match Zip.extractByName(bytes, entries, m) {
        case None -> {
          errors.add(label + ": the archive has no member '" + m + "'")
          return errors
        }
        case Some(ints) -> if not writeIntBytes(Path.join(dir, Path.basename(m)), ints) {
          errors.add(label + ": cannot write " + Path.basename(m))
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

func resolvePkgConfigLib(decl: in NativeLibDecl, args: in List[String], errors: in List[String]): Unit {
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
      for tok in Str.split(Str.trim(flat), " ") {
        if tok.length > 0 {
          args.add(tok)
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
  val darwin = isDarwinTriple(effTriple)
  val seen: List[String] = newList()
  for d in decls {
    if not stringListContains(seen, d.spec.name) {
      seen.add(d.spec.name)
      if d.spec.pkgConfig.length > 0 {
        resolvePkgConfigLib(d, args, errors)
      } else if d.spec.prebuilt.count > 0 {
        resolvePrebuiltLib(d, effTriple, darwin, args, bundle, errors)
      } else {
        resolveDirLib(d, darwin, args, bundle, errors)
      }
    }
  }
  if bundle.count > 0 {
    args.add("-Wl,-rpath," + (if darwin { "@loader_path" } else { "$ORIGIN" }))
  }
  NativeLinkPlan(args = args, bundle = bundle, errors = errors)
}

/// Copies the plan's shared libraries next to the executable, where the
/// `$ORIGIN` / `@loader_path` run path finds them.  Returns what failed.
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
