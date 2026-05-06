// std/file.l - Bootstrap-grade file I/O.
//
// G10 (`docs/23-fsharp-shim-elimination.md` §5): the text/dir-mode
// helpers wrap `System.IO.File` / `System.IO.Directory` calls in
// `try { … } catch Bug as b { … }` to surface host failures as
// `Result.Err(IoError)` — the same shape `Std.Directory` uses.  No
// more F#-side `FileHost` round-trip for those paths.
//
// `readBytes` / `writeBytes` still go through `Lyric.Stdlib.FileHost`
// pair-of-statics for now: `System.IO.File.ReadAllBytes` returns
// `byte[]`, but the public Lyric surface returns `List[Byte]`, and
// the BCL→Lyric conversion isn't expressible in pure Lyric without
// a `slice[Byte] → List[Byte]` constructor.  That migration lands as
// a follow-up to G10.

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
/// the host probe says the file doesn't exist, and `Err(IoError)` for
/// any other host failure (encoding, permission, device, …).
@stable(since="1.0")
pub func readText(path: in String): Result[String, IOError] {
  if path.length == 0 {
    return Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  }
  if not hostFileExists(path) {
    return Err(error = FileNotFound(path = path))
  }
  return try {
    Ok(value = hostReadAllText(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
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

/// Write raw bytes to `path` (creating or replacing).
/// Read the file at `path` as raw bytes.
///
/// Returns `Ok(bytes)` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (not found, permission, …).
@stable(since="1.0")
pub func readBytes(path: in String): Result[List[Byte], IOError] {
  if path.length == 0 {
    Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  } else if hostReadAllBytesIsValid(path) {
    Ok(value = hostReadAllBytesValue(path))
  } else {
    Err(error = IoError(path = path, message = hostReadAllBytesError(path)))
  }
}

///
/// Returns `Ok(())` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (permission, disk-full, …).
@stable(since="1.0")
pub func writeBytes(path: in String, bytes: in List[Byte]): Result[Unit, IOError] {
  if path.length == 0 {
    Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  } else if hostWriteAllBytesIsValid(path, bytes) {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = hostWriteAllBytesError(path, bytes)))
  }
}
