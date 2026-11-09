//! A library enum named like the stdlib's `Std.Log.LogLevel`, with overlapping
//! case names but a different case set and different ordinals, so a reference
//! that resolves to the stdlib's enum is a wrong class (or a wrong value),
//! never a coincidentally right one.
package EnumCollisionLib

import Std.Core

pub enum LogLevel {
  case Trace
  case Debug
  case Info
  case Warn
  case Error
  case Fatal
  case Audit
}

pub func ordinalOf(level: in LogLevel): Int {
  return match level {
    case LogLevel.Trace -> 0
    case LogLevel.Debug -> 1
    case LogLevel.Info -> 2
    case LogLevel.Warn -> 3
    case LogLevel.Error -> 4
    case LogLevel.Fatal -> 5
    case LogLevel.Audit -> 6
  }
}

pub func isInfoOrAbove(level: in LogLevel): Bool {
  return ordinalOf(level) >= ordinalOf(LogLevel.Info)
}
