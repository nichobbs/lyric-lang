// std/file.l - Bootstrap-grade file I/O.
//
// Routes through `hostFile*` builtins resolved by the emitter to static
// methods on `Lyric.Stdlib.FileHost`.  Each operation catches host
// exceptions on the F# side and surfaces a `Result[T, IOError]` to
// callers — no exception escapes the FFI boundary.
//
// Pair-of-statics shape (`*IsValid` + `*Value` / `*Error`) is the same
// bootstrap workaround used by `Std.Parse`: Lyric has no out-parameters,
// so we expose two host calls and accept the cost of doing the IO twice
// when surfacing the error message.  Collapses to a single TryRead /
// TryWrite once Lyric grows out-params or real exception-to-Result
// translation.
@runtime_checked
package Std.File

import Std.Errors

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
pub func readText(path: in String): Result[String, IOError] {
  if path.length == 0 {
    Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  } else if not hostFileExists(path) {
    Err(error = FileNotFound(path = path))
  } else if hostReadAllTextIsValid(path) {
    Ok(value = hostReadAllTextValue(path))
  } else {
    Err(error = IoError(path = path, message = hostReadAllTextError(path)))
  }
}

/// Write `text` to `path` (creating or replacing).
///
/// Returns `Ok(())` on success, `Err(InvalidPath)` for empty paths,
/// or `Err(IoError)` for any host failure (permission, disk-full, …).
pub func writeText(path: in String, text: in String): Result[Unit, IOError] {
  if path.length == 0 {
    Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  } else if hostWriteAllTextIsValid(path, text) {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = hostWriteAllTextError(path, text)))
  }
}

/// Probe whether `path` names an existing directory.  Returns false
/// for empty paths and host errors.
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
pub func createDir(path: in String): Result[Unit, IOError] {
  if path.length == 0 {
    Err(error = InvalidPath(path = path, reason = "path must not be empty"))
  } else if hostCreateDirectoryIsValid(path) {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "createDirectory failed"))
  }
}
