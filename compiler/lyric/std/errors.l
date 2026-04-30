// std/errors.l - Standard error types for the Lyric stdlib.
//
// Error unions are used throughout the stdlib for Result-based error
// handling. No exceptions for recoverable errors; all IO and parsing
// failures are encoded as union cases.
@runtime_checked
package Std.Errors

// ---------------------------------------------------------------------------
// ParseError - numeric parsing and format errors.
// ---------------------------------------------------------------------------

pub union ParseError {
  case InvalidFormat(input: String, expected: String)
  case OutOfRange(value: String, bounds: String)
}

// Human-readable message for a ParseError.
@pure
pub func ParseError.message(e: in ParseError): String {
  match e {
    case InvalidFormat(input, expected) ->
      "invalid format: '" + input + "' (expected " + expected + ")"
    case OutOfRange(value, bounds) ->
      "out of range: " + value + " (bounds: " + bounds + ")"
  }
}

// ---------------------------------------------------------------------------
// IOError - filesystem and console I/O errors.
//
// `path` names a filesystem path when there is one. Console operations
// use source labels such as "stdin" so callers still get useful
// diagnostics without inventing a separate ConsoleError union.
// ---------------------------------------------------------------------------

pub union IOError {
  // The path string is syntactically unusable before any host IO call.
  case InvalidPath(path: String, reason: String)

  // Stable classifications that safe wrappers may detect before
  // entering the host boundary.
  case FileNotFound(path: String)
  case DirectoryNotFound(path: String)
  case AlreadyExists(path: String)
  case PermissionDenied(path: String)

  // Catch-all for host failures that do not map cleanly yet.
  case IoError(path: String, message: String)

  // End-of-input is expected for streams and console reads, not a Bug.
  case EndOfInput(source: String)

  // Environment/configuration lookups use the requested key as the
  // identifier rather than a filesystem path.
  case KeyNotFound(key: String)
}

// Human-readable message for an IOError.
@pure
pub func IOError.message(e: in IOError): String {
  match e {
    case InvalidPath(path, reason) ->
      "invalid path: " + path + " (" + reason + ")"
    case FileNotFound(path) ->
      "file not found: " + path
    case DirectoryNotFound(path) ->
      "directory not found: " + path
    case AlreadyExists(path) ->
      "already exists: " + path
    case PermissionDenied(path) ->
      "permission denied: " + path
    case IoError(path, msg) ->
      "I/O error for " + path + ": " + msg
    case EndOfInput(source) ->
      "end of input: " + source
    case KeyNotFound(key) ->
      "key not found: " + key
  }
}

// ---------------------------------------------------------------------------
// HttpError - network and HTTP errors.
// ---------------------------------------------------------------------------

pub union HttpError {
  case ConnectionFailed(url: String, message: String)
  case Timeout(url: String, durationMs: Long)
  case BadStatus(url: String, statusCode: Int)
  case InvalidUrl(url: String)
  // Wrap an underlying IO failure.  Named `Transport` (not `IoError`)
  // because case constructors live at package scope, so a duplicate
  // `IoError` here would collide with `IOError.IoError`.
  case Transport(url: String, error: IOError)
}

// Human-readable message for an HttpError.
@pure
pub func HttpError.message(e: in HttpError): String {
  match e {
    case ConnectionFailed(url, msg) ->
      "connection failed to " + url + ": " + msg
    case Timeout(url, ms) ->
      "timeout after " + ms + "ms to " + url
    case BadStatus(url, code) ->
      "HTTP " + code + " from " + url
    case InvalidUrl(url) ->
      "invalid URL: " + url
    case Transport(url, error) ->
      "I/O error for " + url + ": " + IOError.message(error)
  }
}
