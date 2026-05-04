// std/log.l - logging and diagnostics.
//
// Phase 5 logging is intentionally simple: messages are best-effort
// diagnostics, not durable audit records. Structured fields are modeled
// now so later sinks can preserve them without changing call sites.

@runtime_checked
package Std.Log

import Std.LogHost as HostLog

@stable(since="1.0")
pub enum LogLevel {
  case Debug
  case Info
  case Warn
  case Error
}

@stable(since="1.0")
pub record LogField {
  key: String
  value: String
}

@stable(since="1.0")
pub interface Logger {
  func log(level: in LogLevel, msg: in String, fields: in slice[LogField]): Unit
}

@pure
func levelName(level: in LogLevel): String {
  match level {
    case Debug -> "debug"
    case Info -> "info"
    case Warn -> "warn"
    case Error -> "error"
  }
}

@pure
func formatFields(fields: in slice[LogField]): String {
  if fields.length == 0 {
    return ""
  }

  var text = ""
  var i = 0
  while i < fields.length {
    val f = fields[i]
    if i == 0 {
      text = " " + f.key + "=" + f.value
    } else {
      text = text + " " + f.key + "=" + f.value
    }
    i += 1
  }
  return text
}

/// Emit a best-effort log message through the host diagnostics sink.
@stable(since="1.0")
pub func log(level: in LogLevel, msg: in String, fields: in slice[LogField]): Unit {
  HostLog.write(levelName(level), msg + formatFields(fields))
}

/// Log at debug level.
@stable(since="1.0")
pub func debug(msg: in String): Unit {
  log(Debug, msg, [])
}

/// Log at info level.
@stable(since="1.0")
pub func info(msg: in String): Unit {
  log(Info, msg, [])
}

/// Log at warning level.
@stable(since="1.0")
pub func warn(msg: in String): Unit {
  log(Warn, msg, [])
}

/// Log at error level.
@stable(since="1.0")
pub func error(msg: in String): Unit {
  log(Error, msg, [])
}

/// Construct one structured field.
///
/// # Preconditions
/// - `key` must be non-empty. Empty field names are caller bugs.
@stable(since="1.0")
pub func field(key: in String, value: in String): LogField
  requires: key.length > 0
{
  return LogField(key = key, value = value)
}
