// std/file.l - Result-based file operations.
//
// This package is the safe wrapper over the trusted System.IO externs
// declared in std/io.l. It performs cheap validation before entering
// the host boundary and converts any escaping Bug into IOError.

@runtime_checked
package Std.File

import Std.Errors
import System.IO as HostIO

// Shared path validation for public file APIs. Empty paths are
// recoverable caller input errors, not precondition Bugs, so the public
// functions return Err instead of relying on `requires:`.
@pure
func invalidPath(path: in String): Option[IOError] {
  if path.length == 0 {
    return Some(value = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return None
}

/// Check whether a file exists at the given path.
///
/// Invalid or empty paths return false to match common existence-probe
/// semantics. This function does not distinguish "not found" from
/// "path cannot be represented"; opening APIs return richer IOError
/// values.
pub func exists(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  return HostIO.fileExists(path)
}

/// Read the entire contents of a text file.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `path` should name a readable file; missing files return
///   `Err(FileNotFound)` before the host read is attempted.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `FileNotFound`: no file exists at the path when checked.
/// - `PermissionDenied`: reserved for host errors that can be
///   classified precisely.
/// - `IoError`: encoding, race, device, and other host failures.
pub func readText(path: in String): Result[String, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.fileExists(path) {
    return Err(error = FileNotFound(path = path))
  }

  return try {
    Ok(value = HostIO.readAllText(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Write a complete text file.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
///
/// # Behavior
/// Creates or replaces the destination according to the host IO
/// boundary contract.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: disk-full, encoding, race, device, and other host
///   failures.
pub func writeText(path: in String, text: in String): Result[Unit, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  return try {
    HostIO.writeAllText(path, text)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Read the entire contents of a file as bytes.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `path` should name a readable file; missing files return
///   `Err(FileNotFound)` before the host read is attempted.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `FileNotFound`: no file exists at the path when checked.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: race, device, and other host failures.
///
/// The returned slice is owned by the caller and has non-negative
/// length per the extern contract.
pub func readBytes(path: in String): Result[slice[Byte], IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.fileExists(path) {
    return Err(error = FileNotFound(path = path))
  }

  return try {
    Ok(value = HostIO.readAllBytes(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Write bytes to a file.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `bytes` must be a valid slice.
///
/// # Behavior
/// Creates or replaces the destination according to the host IO
/// boundary contract.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: disk-full, race, device, and other host failures.
pub func writeBytes(path: in String, bytes: in slice[Byte]): Result[Unit, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  return try {
    HostIO.writeAllBytes(path, bytes)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

// Future: copy, move, append, truncate, metadata (size, modified time,
// permissions), and stream-opening helpers. Keep destructive operations
// explicit in both this safe wrapper and the std/io.l trusted boundary.
