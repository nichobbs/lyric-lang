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
