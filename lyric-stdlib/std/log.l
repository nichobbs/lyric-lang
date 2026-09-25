//! std/log.l - logging and diagnostics.
//!
//! Phase 5 logging is intentionally simple: messages are best-effort
//! diagnostics, not durable audit records. Structured fields are modeled
//! now so later sinks can preserve them without changing call sites.
@runtime_checked
package Std.Log

import Std.Char
import Std.LogHost as HostLog
import Std.String

@stable(since = "1.0")
pub enum LogLevel {
  case Debug
  case Info
  case Warn
  case Error
}

@stable(since = "1.0")
pub record LogField {
  key: String
  value: String
  invariant: key.length > 0
}

@stable(since = "1.0")
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

// Escape special characters in a log field key or value to prevent log injection.
// Replaces \, line breaks, other control characters, = and " with escape
// sequences, so a field can neither start a new log line nor forge a field.
// Runs of characters that need no escaping are appended as single substrings,
// so the common case copies each field once.
func appendEscapedLogValue(sb: in StringBuilder, s: in String): Unit {
  var runStart = 0
  var i = 0
  while i < s.length {
    val ch: Char = s[i]
    val esc = if ch == '\\' {
      "\\\\"
    } else if isLineBreakOrControl(ch) {
      controlEscape(ch)
    } else if ch == '=' {
      "\\="
    } else if ch == '"' {
      "\\\""
    } else {
      ""
    }
    if esc.length > 0 {
      sb.append(s.substring(runStart, i - runStart))
      sb.append(esc)
      runStart = i + 1
    }
    i = i + 1
  }
  sb.append(s.substring(runStart, s.length - runStart))
}

@pure
func formatFields(fields: in slice[LogField]): String {
  if fields.length == 0 {
    return ""
  }
  val sb = StringBuilder.new()
  var i = 0
  while i < fields.length {
    val f = fields[i]
    sb.appendChar(' ')
    appendEscapedLogValue(sb, f.key)
    sb.appendChar('=')
    appendEscapedLogValue(sb, f.value)
    i += 1
  }
  sb.toString()
}

// Escape a log message: line breaks and other control characters become
// visible escapes so a message (often built from request data) cannot start
// a new, forged log line (CWE-117, #7244).  Unlike field values, `=` and `"`
// are left alone: the message is free text, and a record ends at the line
// break, which can no longer occur.
func appendEscapedLogMessage(sb: in StringBuilder, s: in String): Unit {
  var runStart = 0
  var i = 0
  while i < s.length {
    val ch: Char = s[i]
    val esc = if ch == '\\' {
      "\\\\"
    } else if isLineBreakOrControl(ch) {
      controlEscape(ch)
    } else {
      ""
    }
    if esc.length > 0 {
      sb.append(s.substring(runStart, i - runStart))
      sb.append(esc)
      runStart = i + 1
    }
    i = i + 1
  }
  sb.append(s.substring(runStart, s.length - runStart))
}

// C0 controls other than tab, DEL, C1 controls (including NEL, U+0085), and
// the Unicode line and paragraph separators — everything a log viewer may
// treat as a line break or that corrupts a single-line record.
func isLineBreakOrControl(ch: in Char): Bool {
  val c = toInt(ch);
  (c < 32 and c != 9) or (c >= 127 and c <= 159) or c == 0x2028 or c == 0x2029
}

func controlEscape(ch: in Char): String {
  val c = toInt(ch)
  if c == 10 {
    "\\n"
  } else if c == 13 {
    "\\r"
  } else {
    "\\u" + hex4(c)
  }
}

func hex4(n: in Int): String {
  val digits = "0123456789abcdef"
  var acc = ""
  var v = n
  var i = 0
  while i < 4 {
    acc = digits.substring(v % 16, 1) + acc
    v = v / 16
    i = i + 1
  }
  acc
}

/// Emit a best-effort log message through the host diagnostics sink.  Line
/// breaks and control characters in `msg` and in field keys and values are
/// escaped, so one call always produces exactly one log line.
@stable(since = "1.0")
pub func log(level: in LogLevel, msg: in String, fields: in slice[LogField]): Unit {
  HostLog.write(levelName(level), renderLogLine(msg, fields))
}

/// The text `log` hands to the host sink for `msg` and `fields`: the
/// escaped message followed by ` key=value` per field.  Never contains a
/// line break, whatever the inputs.
@stable(since = "1.2")
pub func renderLogLine(msg: in String, fields: in slice[LogField]): String {
  val sb = StringBuilder.new()
  appendEscapedLogMessage(sb, msg)
  sb.append(formatFields(fields))
  sb.toString()
}

/// Log at debug level.
@stable(since = "1.0")
pub func debug(msg: in String): Unit {
  log(Debug, msg, [])
}

/// Log at info level.
@stable(since = "1.0")
pub func info(msg: in String): Unit {
  log(Info, msg, [])
}

/// Log at warning level.
@stable(since = "1.0")
pub func warn(msg: in String): Unit {
  log(Warn, msg, [])
}

/// Log at error level.
@stable(since = "1.0")
pub func error(msg: in String): Unit {
  log(Error, msg, [])
}

/// Construct one structured field.
///
/// # Preconditions
/// - `key` must be non-empty. Empty field names are caller bugs.
@stable(since = "1.0")
pub func field(key: in String, value: in String): LogField
  requires: key.length > 0
{
  return LogField(key = key, value = value)
}
