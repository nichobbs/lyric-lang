//! Lyric.AppHost — native apphost launcher emission for `kind = "exe"` builds.
//!
//! The .NET SDK ships a per-RID *apphost* template: a small native executable
//! carrying an embedded placeholder — the lowercase-hex ASCII of
//! SHA-256("foobar") — that marks a fixed-size reserved region into which the
//! path of the managed entry-point DLL is spliced.  Binding the template lets
//! the produced launcher boot the CLR and run the managed assembly directly
//! (`./app` instead of `dotnet app.dll`).  This is the framework-dependent
//! foundation the later `bundle` (self-contained) and `aot` build kinds build
//! on; both still need a host launcher.
//!
//! The binding logic mirrors `Microsoft.NET.HostModel.AppHost.HostWriter`:
//! locate the placeholder, overwrite it with the UTF-8 path followed by a NUL
//! terminator, and zero the remainder of the reserved region.  The managed DLL
//! is referenced by its file name only (it sits beside the launcher in `bin/`).
package Lyric.AppHost

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Parse as Parse
import Std.Environment as Environment
import Std.Encoding as Enc
import Std.Process as Process

// SHA-256("foobar") in lowercase hex — the app-binary-path placeholder the
// .NET apphost template embeds (Microsoft.NET.HostModel).  Exactly 64 ASCII
// bytes; the reserved region that follows is NUL-padded.
pub val PLACEHOLDER: String =
  "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2"

// The apphost reserves this many bytes at the placeholder offset for the path
// (Microsoft.NET.HostModel `MaxAppBinaryPathSizeInBytes`).  The embedded DLL
// path plus its NUL terminator must fit within it.
pub val RESERVED_BYTES: Int = 1024

val HOST_PACK_PREFIX: String = "Microsoft.NETCore.App.Host."

/// A located apphost template binary and the runtime identifier it targets.
pub record AppHostTemplate {
  path: String   // absolute path to the template apphost binary
  rid: String    // runtime identifier, e.g. "linux-x64", "win-x64", "osx-arm64"
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Placeholder binding (pure — hermetically testable)
// ─────────────────────────────────────────────────────────────────────────────

/// The result of a single placeholder scan: how many non-overlapping
/// occurrences of the needle were found, and the offset of the first (or -1).
record PlaceholderScan {
  count: Int
  firstOffset: Int
}

/// Scan `hay` for `needle` in one pass, reporting both the count of
/// non-overlapping occurrences and the offset of the first.  The binder needs
/// both the count (to reject missing/ambiguous placeholders) and the offset (to
/// splice), so a single scan replaces what was two.  Naive O(n·m) match; the
/// apphost template is well under 100 KB so this is fine.
func scanPlaceholder(hay: in List[Byte], needle: in slice[Byte]): PlaceholderScan {
  if needle.length == 0 {
    return PlaceholderScan(count = 0, firstOffset = -1)
  }
  val last = hay.count - needle.length
  var count = 0
  var firstOffset = -1
  var i = 0
  while i <= last {
    var k = 0
    var matched = true
    while k < needle.length {
      if hay[i + k] != needle[k] {
        matched = false
        k = needle.length
      } else {
        k += 1
      }
    }
    if matched {
      if firstOffset < 0 {
        firstOffset = i
      }
      count += 1
      i += needle.length
    } else {
      i += 1
    }
  }
  PlaceholderScan(count = count, firstOffset = firstOffset)
}

/// Find the first occurrence of `needle` in `hay`, or -1 if absent.
pub func findBytes(hay: in List[Byte], needle: in slice[Byte]): Int {
  scanPlaceholder(hay, needle).firstOffset
}

/// Splice `appRelDllPath` into a copy of `templateBytes`, returning the bound
/// launcher bytes.  Mirrors `HostWriter`: the path (UTF-8) plus a NUL
/// terminator overwrites the start of the placeholder's reserved region, and
/// the rest of the region is zero-filled.
///
/// Errors when the placeholder is missing or ambiguous, when the reserved
/// region runs past the end of the template, or when the path does not fit.
pub func bindAppHost(
  templateBytes: in List[Byte], appRelDllPath: in String
): Result[List[Byte], String] {
  val needle = Enc.encodeUtf8(PLACEHOLDER)
  val scan = scanPlaceholder(templateBytes, needle)
  if scan.count == 0 {
    return Err(error = "apphost template does not contain the app-binary-path placeholder")
  }
  if scan.count > 1 {
    return Err(error = "apphost template contains the placeholder more than once (ambiguous)")
  }
  val idx = scan.firstOffset

  if idx + RESERVED_BYTES > templateBytes.count {
    return Err(
      error = "apphost template too short: reserved region extends past end of file"
    )
  }

  val pathBytes = Enc.encodeUtf8(appRelDllPath)
  // path + NUL terminator must fit the reserved region.
  if pathBytes.length + 1 > RESERVED_BYTES {
    return Err(
      error = "managed DLL path is longer than the apphost reserved region (" +
        toString(RESERVED_BYTES) + " bytes)"
    )
  }

  val outBytes: List[Byte] = newList()
  // Bytes before the reserved region, verbatim.
  var i = 0
  while i < idx {
    outBytes.add(templateBytes[i])
    i += 1
  }
  // The path, then a NUL terminator.
  var p = 0
  while p < pathBytes.length {
    outBytes.add(pathBytes[p])
    p += 1
  }
  outBytes.add(0)
  // Zero-fill the remainder of the reserved region.
  var z = pathBytes.length + 1
  while z < RESERVED_BYTES {
    outBytes.add(0)
    z += 1
  }
  // Bytes after the reserved region, verbatim.
  var j = idx + RESERVED_BYTES
  while j < templateBytes.count {
    outBytes.add(templateBytes[j])
    j += 1
  }
  Ok(value = outBytes)
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Template discovery
// ─────────────────────────────────────────────────────────────────────────────

// Candidate .NET install roots, in priority order.  Mirrors the reference-pack
// discovery in `Msil.MetadataReader`; the Unix fallbacks are best-effort —
// set `DOTNET_ROOT` explicitly on Windows.
func candidateDotnetRoots(): List[String] {
  val roots: List[String] = newList()
  val dr = Environment.getVarOrDefault("DOTNET_ROOT", "")
  if dr.length > 0 {
    roots.add(dr)
  }
  val home = Environment.getVarOrDefault("HOME", "")
  if home.length > 0 {
    roots.add(Path.join(home, ".dotnet"))
  }
  roots.add("/usr/share/dotnet")
  roots.add("/usr/lib/dotnet")
  roots.add("/usr/local/share/dotnet")
  roots.add("/opt/homebrew/opt/dotnet/libexec")
  roots
}

// Numeric value of a dotted-version component, treating any non-numeric
// component (e.g. a `10.0.0-rc.1` pre-release tail) as 0.
func versionComponent(s: in String): Int {
  match Parse.parseOptInt(s) {
    case Some(v) -> v
    case None -> 0
  }
}

// The numeric core of a version directory name: the part before any
// `-pre.release` tail (`"10.0.0-rc.1"` -> `"10.0.0"`).
func versionCore(v: in String): String {
  val segs = Str.split(v, "-")
  segs[0]
}

// True when `v` carries a pre-release tail (`"10.0.0-rc.1"`).
func isPreRelease(v: in String): Bool {
  Str.split(v, "-").length > 1
}

// Compare two dotted numeric version cores: 1 if a > b, -1 if a < b, 0 equal.
func compareVersionCore(a: in String, b: in String): Int {
  val aParts = Str.split(a, ".")
  val bParts = Str.split(b, ".")
  var i = 0
  while i < aParts.length and i < bParts.length {
    val av = versionComponent(aParts[i])
    val bv = versionComponent(bParts[i])
    if av != bv {
      return if av > bv { 1 } else { -1 }
    }
    i += 1
  }
  if aParts.length != bParts.length {
    return if aParts.length > bParts.length { 1 } else { -1 }
  }
  0
}

// True when `a` is a strictly higher version directory than `b`.  Compares the
// dotted numeric cores; on a tie a release ranks above a pre-release, so
// `"10.0.0"` beats `"10.0.0-rc.1"` (the pre-release tail must not win).
func dirVersionGreater(a: in String, b: in String): Bool {
  val cmp = compareVersionCore(versionCore(a), versionCore(b))
  if cmp != 0 {
    return cmp > 0
  }
  val aPre = isPreRelease(a)
  val bPre = isPreRelease(b)
  if aPre != bPre {
    return not aPre
  }
  false
}

// Highest-versioned immediate sub-directory name of `dir`, or None.
func pickHighestDir(dir: in String): Option[String] {
  match File.listDirs(dir) {
    case Err(_) -> None
    case Ok(names) -> {
      if names.count == 0 {
        return None
      }
      var best = names[0]
      var i = 1
      while i < names.count {
        if dirVersionGreater(names[i], best) {
          best = names[i]
        }
        i += 1
      }
      Some(value = best)
    }
  }
}

// The apphost binary file name for a RID (`.exe` suffix on Windows).
func apphostFileName(rid: in String): String {
  if Str.startsWith(rid, "win") {
    "apphost.exe"
  } else {
    "apphost"
  }
}

/// Choose the apphost template to use from the discovered `candidates`.  When
/// `hostRid` is known (non-empty) and a candidate matches it, that one wins —
/// this is what makes the right architecture get picked on machines with
/// several `Microsoft.NETCore.App.Host.<rid>` packs installed (cross-compilation
/// setups).  Otherwise the first discovered candidate is used (the single-RID
/// common case, and the JVM/unknown-host case where `hostRid` is empty).
/// Pure and hermetically testable.
pub func preferHostRid(
  candidates: in List[AppHostTemplate], hostRid: in String
): Option[AppHostTemplate] {
  if hostRid.length > 0 {
    var ci = 0
    while ci < candidates.count {
      if candidates[ci].rid == hostRid {
        return Some(value = candidates[ci])
      }
      ci += 1
    }
  }
  if candidates.count > 0 {
    return Some(value = candidates[0])
  }
  None
}

/// Locate the apphost template for the host machine.  Probes each candidate
/// .NET root for `Microsoft.NETCore.App.Host.<rid>` packs, collecting the
/// highest-versioned template in each, then prefers the one whose RID matches
/// the host runtime identifier (falling back to the first discovered).
pub func locateTemplate(): Option[AppHostTemplate] {
  val candidates: List[AppHostTemplate] = newList()
  val roots = candidateDotnetRoots()
  var ri = 0
  while ri < roots.count {
    val packsDir = Path.join(roots[ri], "packs")
    if File.dirExists(packsDir) {
      match File.listDirs(packsDir) {
        case Ok(names) -> {
          var ni = 0
          while ni < names.count {
            val nm = names[ni]
            if Str.startsWith(nm, HOST_PACK_PREFIX) {
              val rid = Str.substring(nm, HOST_PACK_PREFIX.length, nm.length - HOST_PACK_PREFIX.length)
              val packDir = Path.join(packsDir, nm)
              match pickHighestDir(packDir) {
                case Some(ver) -> {
                  val ahPath = Path.join(
                    Path.join(
                      Path.join(Path.join(packDir, ver), "runtimes"),
                      rid
                    ),
                    Path.join("native", apphostFileName(rid))
                  )
                  if File.fileExists(ahPath) {
                    candidates.add(AppHostTemplate(path = ahPath, rid = rid))
                  }
                }
                case None -> ()
              }
            }
            ni += 1
          }
        }
        case Err(_) -> ()
      }
    }
    ri += 1
  }
  preferHostRid(candidates, Environment.runtimeIdentifier())
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. End-to-end emission
// ─────────────────────────────────────────────────────────────────────────────

/// The launcher file name for an assembly stem and RID (`<stem>.exe` on
/// Windows, bare `<stem>` elsewhere).
pub func launcherName(stem: in String, rid: in String): String {
  if Str.startsWith(rid, "win") {
    stem + ".exe"
  } else {
    stem
  }
}

// The launcher path beside `dllPath` for the given RID: same directory, the
// DLL's stem (sans `.dll`), `.exe`-suffixed on Windows.
func launcherPathBesideDll(dllPath: in String, rid: in String): String {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  val stem = if Str.endsWith(base, ".dll") {
    Str.substring(base, 0, base.length - 4)
  } else {
    base
  }
  Path.join(dir, launcherName(stem, rid))
}

/// Compute the apphost launcher path that `emitAppHost` would produce for
/// `dllPath` on this host, or None when no apphost template can be located.
/// Used by `lyric run` to find and exec the launcher for a `kind = "exe"`
/// build without re-deriving the RID itself.
pub func launcherPathForDll(dllPath: in String): Option[String] {
  match locateTemplate() {
    case None -> None
    case Some(tpl) -> Some(value = launcherPathBesideDll(dllPath, tpl.rid))
  }
}

/// Emit a native apphost launcher beside `dllPath` that boots it (the DLL must
/// sit in the same directory).  Reads the SDK template, binds the managed
/// DLL's file name, writes the launcher (`<stem>` / `<stem>.exe`), marks it
/// executable, and ad-hoc-signs it on macOS (where modifying the binary
/// invalidates the signature).  Returns the launcher path on success.
pub func emitAppHost(dllPath: in String): Result[String, String] {
  match locateTemplate() {
    case None ->
      Err(
        error = "could not locate a .NET apphost template; set DOTNET_ROOT to a .NET SDK install"
      )
    case Some(tpl) -> {
      val launcherPath = launcherPathBesideDll(dllPath, tpl.rid)
      val templateBytes = match File.readBytes(tpl.path) {
        case Ok(b) -> b
        case Err(e) -> return Err(error = "reading apphost template: " + IOError.message(e))
      }
      val appRel = Path.basename(dllPath)
      val bound = match bindAppHost(templateBytes, appRel) {
        case Ok(b) -> b
        case Err(m) -> return Err(error = m)
      }
      match File.writeBytes(launcherPath, bound) {
        case Ok(_) -> ()
        case Err(e) -> return Err(error = "writing apphost launcher: " + IOError.message(e))
      }
      // Mark executable on non-Windows hosts.
      if not Str.startsWith(tpl.rid, "win") {
        val chmodArgs: List[String] = newList()
        chmodArgs.add("+x")
        chmodArgs.add(launcherPath)
        match Process.run("chmod", chmodArgs) {
          case Ok(_) -> ()
          case Err(e) ->
            return Err(error = "marking apphost executable: " + IOError.message(e))
        }
      }
      // macOS: modifying the binary invalidates its code signature; ad-hoc
      // re-sign so the launcher will run.
      if Str.startsWith(tpl.rid, "osx") {
        val signArgs: List[String] = newList()
        signArgs.add("-s")
        signArgs.add("-")
        signArgs.add("--force")
        signArgs.add(launcherPath)
        match Process.run("codesign", signArgs) {
          case Ok(_) -> ()
          case Err(e) ->
            return Err(error = "ad-hoc signing apphost (macOS): " + IOError.message(e))
        }
      }
      Ok(value = launcherPath)
    }
  }
}
