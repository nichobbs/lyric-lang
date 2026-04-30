// std/directory.l - Result-based directory operations.
//
// Directory APIs mirror Std.File's boundary style: user-input problems
// become IOError values, while host failures are caught at this wrapper
// layer and do not leak as Bug into application code.

@runtime_checked
package Std.Directory

import Std.Errors { IOError }
import System.IO as HostIO

// Empty paths are represented as data errors so callers can recover
// without catching Bug.
@pure
func invalidPath(path: in String): Option[IOError] {
  if path.length == 0 {
    return Some(value = InvalidPath(path = path, reason = "path must not be empty"))
  }
  return None
}

/// Check whether a directory exists at the given path.
///
/// Invalid or empty paths return false because this is an existence
/// probe, not a creating/opening operation. Use `create` or
/// `enumerate` when the caller needs a classified IOError.
pub func exists(path: in String): Bool {
  if path.length == 0 {
    return false
  }
  return HostIO.directoryExists(path)
}

/// Create the directory named by path.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
///
/// # Behavior
/// Directory creation follows the host boundary's recursive
/// `CreateDirectory` semantics: existing directories are success, and
/// missing parents may be created.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: parent/file conflicts, race, device, and other host
///   failures.
pub func create(path: in String): Result[Unit, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  return try {
    HostIO.createDirectory(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Create a directory and all parent directories as needed.
///
/// This is an alias for callers that want to document recursive intent.
/// The host boundary currently models directory creation with recursive
/// `CreateDirectory` semantics, so this delegates to `create`.
pub func createRecursive(path: in String): Result[Unit, IOError] {
  return create(path)
}

/// List files and subdirectories directly under a directory.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `path` must name an existing directory; missing directories return
///   `Err(DirectoryNotFound)` before the host enumeration is attempted.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `DirectoryNotFound`: the path does not exist or is not a directory
///   when checked.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: race, device, and other host failures.
///
/// Result path shape follows the host boundary and is not yet pinned as
/// absolute or relative.
pub func enumerate(path: in String): Result[slice[String], IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.directoryExists(path) {
    return Err(error = DirectoryNotFound(path = path))
  }

  return try {
    Ok(value = HostIO.enumerateFileSystemEntries(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// List files, but not subdirectories, directly under a directory.
///
/// # Errors
/// Same error model as `enumerate`.
///
/// Result path shape follows the host boundary and is not yet pinned as
/// absolute or relative.
pub func enumerateFiles(path: in String): Result[slice[String], IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.directoryExists(path) {
    return Err(error = DirectoryNotFound(path = path))
  }

  return try {
    Ok(value = HostIO.enumerateFiles(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// List subdirectories, but not files, directly under a directory.
///
/// # Errors
/// Same error model as `enumerate`.
///
/// Filtering is performed at the host boundary so callers do not need
/// to inspect filesystem metadata themselves.
pub func enumerateDirectories(path: in String): Result[slice[String], IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.directoryExists(path) {
    return Err(error = DirectoryNotFound(path = path))
  }

  return try {
    Ok(value = HostIO.enumerateDirectories(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Delete an empty directory.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `path` must name an existing directory; missing directories return
///   `Err(DirectoryNotFound)` before the host delete is attempted.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `DirectoryNotFound`: the path does not exist or is not a directory
///   when checked.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: directory is not empty, race, device, and other host
///   failures.
///
/// Recursive deletion is intentionally a separate function so
/// destructive behavior is explicit at call sites.
pub func delete(path: in String): Result[Unit, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.directoryExists(path) {
    return Err(error = DirectoryNotFound(path = path))
  }

  return try {
    HostIO.deleteDirectory(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Delete a directory and all of its contents recursively.
///
/// # Preconditions as data
/// - `path` must be non-empty; empty paths return `Err(InvalidPath)`.
/// - `path` must name an existing directory; missing directories return
///   `Err(DirectoryNotFound)` before the host delete is attempted.
///
/// # Errors
/// - `InvalidPath`: path is syntactically unusable by the stdlib.
/// - `DirectoryNotFound`: the path does not exist or is not a directory
///   when checked.
/// - `PermissionDenied`: reserved for classified access failures.
/// - `IoError`: race, device, and other host filesystem failures.
pub func deleteRecursive(path: in String): Result[Unit, IOError] {
  match invalidPath(path) {
    case Some(e) -> return Err(error = e)
    case None -> ()
  }

  if not HostIO.directoryExists(path) {
    return Err(error = DirectoryNotFound(path = path))
  }

  return try {
    HostIO.deleteDirectoryRecursive(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

// Future: move, copy, metadata (createdAt, modifiedAt, size,
// permissions), watching for changes, and temporary directory creation.
// Add each host operation explicitly in std/io.l so reviewers can see
// when the trusted filesystem surface grows.
