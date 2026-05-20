// std/file.l - Bootstrap-grade file I/O.
//
// G10 (`docs/23-fsharp-shim-elimination.md` §5): every helper now
// wraps a direct BCL `@externTarget` (declared in
// `stdlib/std/_kernel/file_host.l`) in `try { … } catch Bug as b
// { … }` to surface host failures as `Result.Err(IoError)`.  No more
// F#-side `FileHost` round-trip.
//
// For bytes round-tripping the public surface stays `List[Byte]` for
// caller convenience; the kernel extern returns / accepts
// `slice[Byte]` and we shuttle through `slice[T].toList()` /
// `List[T].toArray()` in pure Lyric.

@runtime_checked
package Std.File

import Std.Core
import Std.Collections
import Std.Errors
import Std.FileHost

/// Probe whether a regular file exists at `path`.
///
/// Empty / invalid paths return false (matches common existence-probe
/// semantics).  No exception is propagated — host failures are
/// indistinguishable from "doesn't exist" here; use `readText` for
/// distinguishable errors.
///
/// Named `fileExists` rather than the more idiomatic `exists` because
/// `exists` is a soft keyword (predicate-logic quantifier) reserved for
/// `requires` / `ensures` clauses.
@stable(since="1.0")
pub func fileExists(path: in String): Bool {
  if path.length == 0 {
    false
  } else {
    hostFileExists(path)
  }
}

/// Read the entire contents of `path` as UTF-8 text.
///
/// Returns `Err(InvalidPath)` for empty paths, `Err(FileNotFound)` if
/// the host reports the file is missing, and `Err(IoError)` for any
/// other host failure (encoding, permission, device, …).  The existence
/// probe was dropped to eliminate a TOCTOU race between the probe and
/// the read — instead the host exception is classified by message.
@stable(since="1.0")
pub func readText(path: in String): Result[String, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    Ok(value = hostReadAllText(path))
  } catch Bug as b {
    // Locale caveat: the "Could not find file" prefix match assumes
    // an English .NET runtime.  On non-English runtimes a real
    // FileNotFoundException may slip through as IoError until the
    // host shim is upgraded to return an exception-type tag rather
    // than the localised message text.  See lyric-lang #601.
    if b.message.startsWith("Could not find file") or
       b.message.contains("FileNotFoundException") or
       b.message.contains("DirectoryNotFoundException") {
      Err(error = FileNotFound(path = path))
    } else {
      Err(error = IoError(path = path, message = b.message))
    }
  }
}

/// Write `text` to `path` (creating or replacing).
///
/// Returns `Ok(())` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (permission, disk-full, …).
@stable(since="1.0")
pub func writeText(path: in String, text: in String): Result[Unit, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    hostWriteAllText(path, text)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Probe whether `path` names an existing directory.  Returns false
/// for empty paths and host errors.
@stable(since="1.0")
pub func dirExists(path: in String): Bool {
  if path.length == 0 {
    false
  } else {
    hostDirectoryExists(path)
  }
}

/// Create the directory at `path` (and any missing parents).  No-op
/// if it already exists.  Returns `Ok(())` on success,
/// `Err(InvalidPath)` for empty paths, or `Err(IoError)` if the host
/// call fails.
@stable(since="1.0")
pub func createDir(path: in String): Result[Unit, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    hostCreateDirectory(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Recursively delete a directory and every file it contains.
/// Returns `Ok(())` on success (also when the directory doesn't exist —
/// the host throws and we swallow it for caller convenience).
/// `Err(InvalidPath)` for empty paths, `Err(IoError)` for permission
/// or device errors.
@stable(since="1.0")
pub func deleteDirRecursive(path: in String): Result[Unit, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    hostDeleteDirectoryRecursive(path, true)
    Ok(value = ())
  } catch Bug as b {
    // Distinguishing "doesn't exist" from "permission denied" requires
    // an exception-type-aware shim; treat any host failure as IoError.
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Read the file at `path` as raw bytes.
///
/// Returns `Ok(bytes)` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (not found, permission, …).
@stable(since="1.0")
pub func readBytes(path: in String): Result[List[Byte], IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    val raw = hostReadAllBytes(path)
    val acc: List[Byte] = newListWithCapacity(raw.length)
    for b in raw {
      acc.add(b)
    }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Write raw bytes to `path` (creating or replacing).
///
/// Returns `Ok(())` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (permission, disk-full, …).
@stable(since="1.0")
pub func writeBytes(path: in String, bytes: in List[Byte]): Result[Unit, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return try {
    hostWriteAllBytes(path, bytes.toArray())
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// List the names of all files directly inside `dir` (non-recursive).
///
/// Returns `Ok(files)` where each element is an absolute path to a file.
/// Returns `Err(InvalidPath)` for an empty path, `Err(IoError)` for
/// any host failure (missing dir, permission, …).
@stable(since="1.0")
pub func listFiles(dir: in String): Result[List[String], IOError] {
  if dir.length == 0 {
    return Err(error = InvalidPath(path = dir, reason = "path must not be empty"))
  }
  return try {
    val raw = hostEnumerateFiles(dir)
    val acc: List[String] = newListWithCapacity(raw.length)
    for f in raw { acc.add(f) }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = dir, message = b.message))
  }
}

/// List the names of all sub-directories directly inside `dir` (non-recursive).
///
/// Returns `Ok(dirs)` where each element is an absolute path to a directory.
/// Returns `Err(InvalidPath)` for an empty path, `Err(IoError)` for
/// any host failure (missing dir, permission, …).
@stable(since="1.0")
pub func listDirs(dir: in String): Result[List[String], IOError] {
  if dir.length == 0 {
    return Err(error = InvalidPath(path = dir, reason = "path must not be empty"))
  }
  return try {
    val raw = hostEnumerateDirectories(dir)
    val acc: List[String] = newListWithCapacity(raw.length)
    for d in raw { acc.add(d) }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = dir, message = b.message))
  }
}

// Helper: collect all files recursively starting from `dir` into `acc`.
// Errors stop the traversal and propagate up.
func collectFilesRecursive(dir: in String, acc: in List[String]): Result[Unit, IOError] {
  val files = match listFiles(dir) {
    case Ok(fs)  -> fs
    case Err(e)  -> { return Err(error = e) }
  }
  for f in files.toArray() { acc.add(f) }
  val subdirs = match listDirs(dir) {
    case Ok(ds)  -> ds
    case Err(e)  -> { return Err(error = e) }
  }
  for sub in subdirs.toArray() {
    match collectFilesRecursive(sub, acc) {
      case Ok(_)  -> ()
      case Err(e) -> { return Err(error = e) }
    }
  }
  return Ok(value = ())
}

/// List all files recursively under `dir`, depth-first.
///
/// Returns `Ok(files)` with one absolute path per file.  Traversal
/// errors (missing intermediate dir, permission) surface as `Err(IoError)`.
@stable(since="1.0")
pub func listFilesRecursive(dir: in String): Result[List[String], IOError] {
  if dir.length == 0 {
    return Err(error = InvalidPath(path = dir, reason = "path must not be empty"))
  }
  val acc: List[String] = newList()
  match collectFilesRecursive(dir, acc) {
    case Ok(_)  -> Ok(value = acc)
    case Err(e) -> Err(error = e)
  }
}
