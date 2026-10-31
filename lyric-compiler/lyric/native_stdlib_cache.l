//! Cache of the bundled-stdlib type check for `--target native` (#7971).
//!
//! A native build type-checks every bundled `Std.*` package its program
//! reaches (#7933).  Most of those checks are repeated unchanged build after
//! build, so this package records, per package, that a check against an exact
//! set of inputs succeeded and lowered nothing, and lets the next build skip it.
//!
//! What a hit stands for.  `checkBundledStdlibPackage` returns the package
//! after the checker's record-arithmetic, record-equality and `array[N, T]`
//! sites are lowered, and those passes are the identity when the checker
//! recorded no such site (`Lyric.Pipeline.stdlibLoweringIsIdentity`).  An entry
//! is therefore written only for a package whose check reported no error and
//! recorded no site, and a hit hands the already-parsed package back as the
//! lowered one.  A package with sites is always checked in full: its lowered
//! tree has no serialised form, and replaying a verdict alone would drop the
//! lowering.
//!
//! Key.  An entry's name is the SHA-256 of: the format tag, the compiler
//! fingerprint (`compilerFingerprint`), the target OS (the checker reads no
//! other target input, so not the triple), the package
//! name, and the name plus source hash of the package and of every package of
//! its import closure, in load order.  Nothing else reaches the checker.  Any
//! difference is a different key, so an entry can only be reached by a build
//! whose check would see byte-identical inputs.
//!
//! Soundness.  An entry's text restates its own key and carries the format
//! tag.  `lookup` accepts it only when the whole file equals the text `store`
//! would write for that key, so a truncated, edited, renamed or foreign file
//! is a miss and the package is checked in full, as is an absent or unreadable
//! cache.  Writing is best effort: a failure to write costs the speedup, never
//! the build.  Entries are never trusted beyond their key and are never
//! deleted by the compiler; a stale one is simply unreachable.
//!
//! Location.  `$LYRIC_CACHE_DIR/native-stdlib-check/`, else
//! `~/.lyric/cache/native-stdlib-check/` (beside `~/.lyric/tools`).
//! `LYRIC_CACHE_DIR=off` disables the cache.
//!
//! This is independent of the checked package interfaces planned in docs/70
//! (`Lyric.Iface`): it stores no compiler data structure, only a verdict keyed
//! by source hashes, so it stays valid whatever the checker's output becomes
//! and is retired by deleting this package once interfaces replace the check.
package Lyric.NativeStdlibCache

import Std.Core
import Std.Collections
import Std.String as Str
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Hash
import Std.Encoding
import Lyric.Version

/// Bump when the entry text, the key recipe or the meaning of a hit changes.
pub val CACHE_FORMAT_TAG: String = "lyric-native-stdlib-check-cache v1"

/// One package of a check's input: its dotted name and the SHA-256 of its
/// source text (`sourceHash`).
pub record KeyPart {
  name: String
  sourceHash: String
}

/// The directory entries live in, or "" when the cache is disabled or no home
/// directory is known.
pub func cacheDir(): String {
  val override = Environment.getVarOrDefault("LYRIC_CACHE_DIR", "")
  if override == "off" {
    return ""
  }
  val root = if override.length > 0 {
    override
  } else {
    val home = Environment.getVarOrDefault("HOME", Environment.getVarOrDefault("USERPROFILE", ""))
    if home.length == 0 {
      ""
    } else {
      Path.join(Path.join(home, ".lyric"), "cache")
    }
  }
  if root.length == 0 {
    ""
  } else {
    Path.join(root, "native-stdlib-check")
  }
}

/// SHA-256 of `text`'s UTF-8 bytes, as the stdlib renders it.
pub func sourceHash(text: in String): String {
  Std.Hash.sha256OfBytes(Std.Encoding.encodeUtf8(text))
}

/// Identifies the running compiler: its release version plus a hash of every
/// file of its own directory named `lyric*` / `Lyric*` (the dev layout's
/// compiler DLLs, a release's executable).  Two builds of the compiler differ
/// here even when both report the dev placeholder version.  Empty when the
/// directory cannot be read or holds no such file or one cannot be hashed,
/// which disables the cache: an unknowable compiler is never assumed
/// unchanged.
pub func compilerFingerprint(appBase: in String): String {
  if appBase.length == 0 {
    return ""
  }
  val listed = match File.listFiles(appBase) { case Ok(fs) -> fs; case Err(_) -> return "" }
  val names: List[String] = newList()
  for p in listed {
    val base = Path.basename(p)
    if Str.startsWith(Str.toLower(base), "lyric") {
      names.add(base)
    }
  }
  if names.count == 0 {
    return ""
  }
  var i = 1
  while i < names.count {
    var j = i
    while j > 0 and names[j - 1] > names[j] {
      val t = names[j]
      names[j] = names[j - 1]
      names[j - 1] = t
      j = j - 1
    }
    i = i + 1
  }
  var acc = "v=" + VERSION() + "\n"
  for n in names {
    match Std.Hash.sha512OfFile(Path.join(appBase, n)) {
      case Ok(h) -> {
        acc = acc + n + "=" + h + "\n"
      }
      case Err(_) -> return ""
    }
  }
  sourceHash(acc)
}

/// The cache key for checking `pkg` against `parts` (its own part first, then
/// its import closure in load order) as `compilerId` on `target`.  Empty when
/// `compilerId` is empty (no cache).
pub func entryKey(compilerId: in String, target: in String, pkg: in String, parts: in List[KeyPart]): String {
  if compilerId.length == 0 {
    return ""
  }
  var acc = CACHE_FORMAT_TAG + "\ncompiler=" + compilerId + "\ntarget=" + target + "\npackage=" + pkg + "\n"
  for p in parts {
    acc = acc + p.name + "=" + p.sourceHash + "\n"
  }
  sourceHash(acc)
}

func entryText(key: in String): String {
  CACHE_FORMAT_TAG + "\nkey=" + key + "\nverdict=clean-no-lowering-sites\n"
}

func entryPath(dir: in String, key: in String): String {
  Path.join(dir, key + ".ok")
}

/// True when `dir` holds a valid entry for `key`.  A missing, unreadable,
/// truncated, edited or foreign file is false.
pub func lookup(dir: in String, key: in String): Bool {
  if dir.length == 0 or key.length == 0 {
    return false
  }
  match File.readText(entryPath(dir, key)) {
    case Ok(text) -> text == entryText(key)
    case Err(_) -> false
  }
}

/// Record a clean, site-free check for `key`.  Best effort: returns false when
/// the entry could not be written, which only costs the next build its hit.
pub func store(dir: in String, key: in String): Bool {
  if dir.length == 0 or key.length == 0 {
    return false
  }
  match File.createDir(dir) {
    case Ok(_) -> ()
    case Err(_) -> if not File.dirExists(dir) { return false }
  }
  match File.writeText(entryPath(dir, key), entryText(key)) {
    case Ok(_) -> true
    case Err(_) -> false
  }
}
