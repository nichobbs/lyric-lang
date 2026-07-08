//! std/_kernel_jvm/log_host.l - JVM host boundary for diagnostics output.
//!
//! Mirrors _kernel/log_host.l for the JVM target exactly: writes to stderr
//! in the format "[LEVEL] message", composing the JVM console-stderr path
//! (Std.ConsoleHost). Replaces a `lyric.stdlib.jvm.LogHost` shim class
//! (routed through `java.util.logging.Logger`) that never existed at
//! runtime -- the `extern package` mechanism it used is a no-op in both the
//! type checker and both codegens. Deliberately matches the .NET kernel's
//! plain-stderr behavior rather than introducing JUL's independent level
//! filtering/handler configuration, which would make Std.Log behave
//! differently per target.
package Std.LogHost

import Std.String as Str
import Std.ConsoleHost as Con

pub func write(level: in String, message: in String): Unit {
  Con.hostConsoleErrorWriteLine("[" + Str.toUpper(level) + "] " + message)
}
