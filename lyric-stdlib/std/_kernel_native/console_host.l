//! std/_kernel_native/console_host.l — native-target console boundary.
//!
//! The `--target native` twin of `_kernel/console_host.l`, selected by
//! the native source loader the same way `_kernel_jvm/` twins override
//! their `_kernel/` counterparts by basename (docs/44 J6 M-10).  Output
//! goes through the audited lyric-rt helpers (`lyric_console_write*`),
//! which loop on EINTR/partial writes; console output stays a
//! best-effort effect per Std.Console's contract.
//!
//! Console INPUT (`hostConsoleRead` / `hostConsoleReadLine` / `hostReadLineOpt`,
//! #4816) is not yet available on the native target: `String?` nullable
//! returns need the Phase N2 heap-type lowering.  `Std.Console.readLine` is
//! therefore compile-time-unreachable on native until then (tracked in the
//! docs/10 native milestone notes).
@axiom("POSIX write(2) via lyric-rt conforms to its documented contract")
package Std.ConsoleHost

extern func consoleWriteFd(fd: Int, s: String): Unit = "lyric_console_write"

extern func consoleNewlineFd(fd: Int): Unit = "lyric_console_write_newline"

pub func hostConsoleWrite(text: in String): Unit {
  consoleWriteFd(1, text)
}

pub func hostConsoleWriteLine(text: in String): Unit {
  consoleWriteFd(1, text)
  consoleNewlineFd(1)
}

pub func hostConsoleErrorWrite(text: in String): Unit {
  consoleWriteFd(2, text)
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  consoleWriteFd(2, text)
  consoleNewlineFd(2)
}
