// std/_kernel/log_host.l - host boundary for diagnostic log output.
//
// Writes Std.Log messages to stderr in the format "[LEVEL] message",
// composing the pure-Lyric console stderr path (no F# shim — #1493).
// Internal: only Std.Log should import this.

package Std.LogHost

import Std.String as Str
import Std.ConsoleHost as Con

pub func write(level: in String, message: in String): Unit {
  Con.hostConsoleErrorWriteLine("[" + Str.toUpper(level) + "] " + message)
}
