// Std.Logging — structured, named, runtime-configurable logging.
//
// Builds on Std.ConsoleHost and adds a six-level severity scale, named loggers,
// structured key-value fields, and text/JSON output formatting.  A global level
// filter backed by package constants silently discards records below the
// configured threshold.
//
// Aspect templates for automatic call instrumentation live in
// Std.Logging.Aspects; import that package to use them.

@runtime_checked
package Std.Logging

import Std.Core
import Std.ConsoleHost as ConsoleHost

// ─── Types ───────────────────────────────────────────────────────────────────

/// Six-level severity scale.  Trace and Fatal extend Std.Log's four-level set;
/// they map to Debug and Error respectively at the host output boundary.
@stable(since="0.1")
pub enum LogLevel {
  case Trace
  case Debug
  case Info
  case Warn
  case Error
  case Fatal
}

/// A structured key-value field attached to a log record.
@stable(since="0.1")
pub record LogField {
  key:   String
  value: String
}

/// A named logger.  Obtain one via getLogger.
/// Loggers are value types; getLogger is pure and creates no shared state.
/// The name is prepended to every record produced through this logger.
@stable(since="0.1")
pub record Logger {
  name: String
}

// ─── Private helpers ─────────────────────────────────────────────────────────

func levelOrd(level: in LogLevel): Int {
  match level {
    case LogLevel.Trace -> 0
    case LogLevel.Debug -> 1
    case LogLevel.Info  -> 2
    case LogLevel.Warn  -> 3
    case LogLevel.Error -> 4
    case LogLevel.Fatal -> 5
  }
}

// Lowercase key passed to the host sink (matches Std.Log convention).
func levelKey(level: in LogLevel): String {
  match level {
    case LogLevel.Trace -> "trace"
    case LogLevel.Debug -> "debug"
    case LogLevel.Info  -> "info"
    case LogLevel.Warn  -> "warn"
    case LogLevel.Error -> "error"
    case LogLevel.Fatal -> "fatal"
  }
}

// Uppercase label used in text-format output.
func levelLabel(level: in LogLevel): String {
  match level {
    case LogLevel.Trace -> "TRACE"
    case LogLevel.Debug -> "DEBUG"
    case LogLevel.Info  -> "INFO"
    case LogLevel.Warn  -> "WARN"
    case LogLevel.Error -> "ERROR"
    case LogLevel.Fatal -> "FATAL"
  }
}

func appendFields(base: in String, fields: in slice[LogField]): String {
  var buf = base
  var i = 0
  while i < fields.length {
    val f = fields[i]
    buf = buf + " " + f.key + "=" + f.value
    i = i + 1
  }
  return buf
}

func formatText(loggerName: in String, level: in LogLevel, msg: in String, fields: in slice[LogField]): String {
  val prefix = "[" + levelLabel(level) + "] [" + loggerName + "] " + msg
  return appendFields(prefix, fields)
}

func formatJsonFields(fields: in slice[LogField]): String {
  var buf = ""
  var i = 0
  while i < fields.length {
    val f = fields[i]
    buf = buf + ",\"" + f.key + "\":\"" + f.value + "\""
    i = i + 1
  }
  return buf
}

func formatJson(loggerName: in String, level: in LogLevel, msg: in String, fields: in slice[LogField]): String {
  val label = levelKey(level)
  val extra = formatJsonFields(fields)
  return "{\"level\":\"" + label + "\",\"logger\":\"" + loggerName + "\",\"msg\":\"" + msg + "\"" + extra + "}"
}

func formatRecord(loggerName: in String, level: in LogLevel, msg: in String, fields: in slice[LogField]): String {
  return formatText(loggerName, level, msg, fields)
}

// Write to stderr for Error/Fatal, stdout for all other levels.
func emitLine(level: in LogLevel, text: in String): Unit {
  val ord = levelOrd(level)
  if ord >= 4 {
    ConsoleHost.hostConsoleErrorWriteLine(text)
  } else {
    ConsoleHost.hostConsoleWriteLine(text)
  }
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Return a named logger.  Pure: no shared state, returns a value type.
@stable(since="0.1")
pub func getLogger(name: in String): Logger
  requires: name.length > 0
{
  return Logger(name = name)
}

/// True when a record at `level` would pass the global level filter.
@stable(since="0.1")
pub func isEnabled(level: in LogLevel): Bool {
  return levelOrd(level) >= levelOrd(LogLevel.Info)
}

/// Emit one log record with structured fields.
/// Silently discarded when `level` is below `defaultLevel`.
@stable(since="0.1")
pub func log(logger: in Logger, level: in LogLevel, msg: in String, fields: in slice[LogField]): Unit {
  if not isEnabled(level) { return }
  val text = formatRecord(logger.name, level, msg, fields)
  emitLine(level, text)
}

/// Emit at `level` with no structured fields.
@stable(since="0.1")
pub func logMsg(logger: in Logger, level: in LogLevel, msg: in String): Unit {
  log(logger, level, msg, [])
}

/// Emit at Trace level.
@stable(since="0.1")
pub func trace(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Trace, msg)
}

/// Emit at Debug level.
@stable(since="0.1")
pub func debug(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Debug, msg)
}

/// Emit at Info level.
@stable(since="0.1")
pub func info(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Info, msg)
}

/// Emit at Warn level.
@stable(since="0.1")
pub func warn(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Warn, msg)
}

/// Emit at Error level.
@stable(since="0.1")
pub func error(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Error, msg)
}

/// Emit at Fatal level.
@stable(since="0.1")
pub func fatal(logger: in Logger, msg: in String): Unit {
  logMsg(logger, LogLevel.Fatal, msg)
}

/// Build one structured key-value field.
///
/// `key` must be non-empty; empty field names are caller bugs.
@stable(since="0.1")
pub func field(key: in String, value: in String): LogField
  requires: key.length > 0
{
  return LogField(key = key, value = value)
}
