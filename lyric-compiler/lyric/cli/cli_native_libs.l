package Lyric.Cli

import Std.Core
import Std.Collections
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
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
      for tok in Str.split(Str.trim(res.stdout), " ") {
        if Str.startsWith(tok, "-L") or Str.startsWith(tok, "-l") or Str.startsWith(tok, "-Wl,") {
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
