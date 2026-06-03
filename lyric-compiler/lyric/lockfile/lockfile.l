// lockfile/lockfile.l — lyric.lock reader and writer.
//
// Implements the lock file format described in docs/38-workspace.md §6:
// a simplified TOML-like text file with a [workspace] header and
// repeated [[package]] blocks.
//
// Public API:
//   pub func emptyLockFile(): LockFile
//   pub func addOrUpdatePackage(lf: in LockFile, pkg: in LockedPackage): LockFile
//   pub func findPackage(lf: in LockFile, name: in String): Option[LockedPackage]
//   pub func serializeLockFile(lf: in LockFile): String
//   pub func parseLockFile(text: in String): Result[LockFile, String]

package Lyric.Lockfile

import Std.Core
import Std.Collections
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────

pub record LockedPackage {
  name:    String
  version: String
  source:  String          // "workspace", "path:<dir>", "nuget:<url>", "git:<url>#<rev>"
  sha512:  Option[String]
  path:    Option[String]
}

pub record LockFile {
  formatVersion: Int       // always 1
  packages:      List[LockedPackage]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Construction helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Return a new, empty lock file with format version 1.
pub func emptyLockFile(): LockFile {
  LockFile(formatVersion = 1, packages = newList())
}

/// Return a new LockFile where the package with `pkg.name` is replaced by
/// `pkg`, or appended if no package with that name existed.
pub func addOrUpdatePackage(lf: in LockFile, pkg: in LockedPackage): LockFile {
  val updated: List[LockedPackage] = newList()
  var found = false
  var i = 0
  while i < lf.packages.count {
    val existing = lf.packages[i]
    if existing.name == pkg.name {
      updated.add(pkg)
      found = true
    } else {
      updated.add(existing)
    }
    i += 1
  }
  if not found { updated.add(pkg) }
  LockFile(formatVersion = lf.formatVersion, packages = updated)
}

/// Linear scan; returns the first package whose name equals `name`.
pub func findPackage(lf: in LockFile, name: in String): Option[LockedPackage] {
  var i = 0
  while i < lf.packages.count {
    val p = lf.packages[i]
    if p.name == name { return Some(value = p) }
    i += 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Serialization
// ─────────────────────────────────────────────────────────────────────────────

/// Render a LockFile to the canonical lyric.lock text format.
pub func serializeLockFile(lf: in LockFile): String {
  var buf = "# lyric.lock — machine-generated\n\n[workspace]\nversion = 1\n\n"
  var i = 0
  while i < lf.packages.count {
    val p = lf.packages[i]
    buf = buf + "[[package]]\n"
    buf = buf + "name = \"" + p.name + "\"\n"
    buf = buf + "version = \"" + p.version + "\"\n"
    buf = buf + "source = \"" + p.source + "\"\n"
    match p.sha512 {
      case Some(h) -> { buf = buf + "sha512 = \"" + h + "\"\n" }
      case None    -> ()
    }
    match p.path {
      case Some(d) -> { buf = buf + "path = \"" + d + "\"\n" }
      case None    -> ()
    }
    i += 1
    // Separate blocks with a blank line; no trailing blank line after the last.
    if i < lf.packages.count { buf = buf + "\n" }
  }
  buf
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Parsing
// ─────────────────────────────────────────────────────────────────────────────

// Trim leading and trailing whitespace from a line.
func trimLine(s: in String): String {
  Str.trim(s)
}

// Strip surrounding double-quote characters from a TOML string value.
// Returns the unquoted content, or Err if the value is not properly quoted.
func unquote(raw: in String, lineNum: in Int): Result[String, String] {
  val t = Str.trim(raw)
  if t.length < 2 {
    return Err(error = "line " + Str.fromInt(lineNum) + ": expected quoted string, got: " + t)
  }
  if t[0] != '"' or t[t.length - 1] != '"' {
    return Err(error = "line " + Str.fromInt(lineNum) + ": value must be double-quoted: " + t)
  }
  // Strip first and last characters (the quotes).
  var content = ""
  var i = 1
  while i < t.length - 1 {
    content = content + "" + t[i]
    i += 1
  }
  Ok(value = content)
}

// Flush an in-progress [[package]] block, if any, into pkgs.
func flushBlock(name: inout Option[String], version: inout Option[String],
                source: inout Option[String], sha512: inout Option[String],
                path: inout Option[String],
                pkgs: in List[LockedPackage]): Result[Unit, String] {
  match name {
    case None    -> Ok(value = ())  // no block in progress
    case Some(n) -> {
      val v = unwrapOr(version, "")
      val s = unwrapOr(source, "")
      pkgs.add(LockedPackage(
        name    = n,
        version = v,
        source  = s,
        sha512  = sha512,
        path    = path))
      name    = None
      version = None
      source  = None
      sha512  = None
      path    = None
      Ok(value = ())
    }
  }
}

/// Parse the text of a lyric.lock file.
///
/// Returns `Ok(LockFile)` on success or `Err(message)` on the first parse
/// error.  Unknown keys and the `[workspace]` / `version` header are
/// silently accepted so the parser is forward-compatible with future
/// additions to the lock file format.
pub func parseLockFile(text: in String): Result[LockFile, String] {
  val lines = Str.split(text, "\n")
  val pkgs: List[LockedPackage] = newList()

  var inPackageBlock = false
  var curName:    Option[String] = None
  var curVersion: Option[String] = None
  var curSource:  Option[String] = None
  var curSha512:  Option[String] = None
  var curPath:    Option[String] = None

  var lineNum = 0
  while lineNum < lines.length {
    val raw  = lines[lineNum]
    val line = trimLine(raw)
    lineNum += 1

    // Skip blank lines and comments.
    if Str.isEmpty(line) or Str.startsWith(line, "#") {
      // do nothing
    } else if line == "[[package]]" {
      // Flush previous block.
      match flushBlock(curName, curVersion, curSource, curSha512, curPath, pkgs) {
        case Err(e) -> return Err(error = e)
        case Ok(_)  -> ()
      }
      inPackageBlock = true
    } else if line == "[workspace]" or Str.startsWith(line, "[") {
      // Section header that is not [[package]]; exit any package block.
      match flushBlock(curName, curVersion, curSource, curSha512, curPath, pkgs) {
        case Err(e) -> return Err(error = e)
        case Ok(_)  -> ()
      }
      inPackageBlock = false
    } else if inPackageBlock {
      // Parse key = value inside a [[package]] block.
      match Str.indexOf(line, "=") {
        case None ->
          return Err(error = "line " + Str.fromInt(lineNum) + ": expected key = value, got: " + line)
        case Some(eqIdx) -> {
          val key   = Str.trim(Str.substring(line, 0, eqIdx))
          val value = Str.trim(Str.substring(line, eqIdx + 1, line.length - eqIdx - 1))
          if key == "name" {
            match unquote(value, lineNum) {
              case Err(e) -> return Err(error = e)
              case Ok(s)  -> { curName = Some(value = s) }
            }
          } else if key == "version" {
            match unquote(value, lineNum) {
              case Err(e) -> return Err(error = e)
              case Ok(s)  -> { curVersion = Some(value = s) }
            }
          } else if key == "source" {
            match unquote(value, lineNum) {
              case Err(e) -> return Err(error = e)
              case Ok(s)  -> { curSource = Some(value = s) }
            }
          } else if key == "sha512" {
            match unquote(value, lineNum) {
              case Err(e) -> return Err(error = e)
              case Ok(s)  -> { curSha512 = Some(value = s) }
            }
          } else if key == "path" {
            match unquote(value, lineNum) {
              case Err(e) -> return Err(error = e)
              case Ok(s)  -> { curPath = Some(value = s) }
            }
          }
          // Unknown keys are silently ignored for forward-compatibility.
        }
      }
    }
    // Lines outside of any recognised block are silently ignored.
  }

  // Flush the final block.
  match flushBlock(curName, curVersion, curSource, curSha512, curPath, pkgs) {
    case Err(e) -> return Err(error = e)
    case Ok(_)  -> ()
  }

  Ok(value = LockFile(formatVersion = 1, packages = pkgs))
}
