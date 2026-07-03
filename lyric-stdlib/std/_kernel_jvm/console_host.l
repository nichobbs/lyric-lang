//! std/_kernel_jvm/console_host.l - JVM host boundary for console IO.
//!
//! Mirrors _kernel/console_host.l for the JVM target.  Pure Lyric over the
//! JVM auto-FFI against `java.lang.System.{out,err,in}` — the previous
//! version routed through a `lyric.stdlib.jvm.ConsoleHost` shim class that
//! never existed at runtime (same elimination as the `time_host.l` /
//! `collections_host.l` / `file_host.l` rewrites).  `System.out` / `err` /
//! `in` are public static FIELDS, resolved by the auto-FFI's static-field
//! path (`getstatic` from JDK metadata) rather than method resolution.
//!
//! hostConsoleRead returns a single UTF-16 code unit (0..65535) or -1 on
//! EOF, matching the contract of the .NET kernel's System.Console.Read.
//! Stdin reads share one process-wide BufferedReader (a module-level `val`,
//! initialised once in the class initialiser): constructing a fresh
//! buffered reader per call would buffer-and-discard lookahead bytes
//! between consecutive reads.
//!
//! Internal: prefer Std.Console for application code.  Import this kernel
//! module only when exact byte-level control is required (e.g. the LSP
//! Content-Length framing reader).
@axiom("java.lang.System.{out,err,in} and java.io.BufferedReader conform to their documented JVM contracts")
package Std.ConsoleHost

import Std.Core

extern type JSystem = "java.lang.System"

extern type JPrintStream = "java.io.PrintStream"

extern type JBufferedReader = "java.io.BufferedReader"

extern type JInputStreamReader = "java.io.InputStreamReader"

// Process-shared stdin reader (see the module doc).
val stdinReader: JBufferedReader = JBufferedReader.new(JInputStreamReader.new(JSystem.in))

/// Read a single UTF-16 code unit from stdin; -1 at EOF.
pub func hostConsoleRead(): Int {
  stdinReader.read()
}

pub func hostConsoleWrite(text: in String): Unit {
  val o = JSystem.out
  o.print(text)
}

pub func hostConsoleWriteLine(text: in String): Unit {
  val o = JSystem.out
  o.println(text)
}

/// Read a line from stdin; null at EOF (mapped to None by Std.Console).
pub func hostConsoleReadLine(): String? {
  stdinReader.readLine()
}

// Option seam over `hostConsoleReadLine` (issue #4775 item 1): `case null`
// parses as a catch-all binding under the self-hosted compiler, not a null
// test, so `Std.Console.readLine`'s original `case null -> Err(EndOfInput)`
// first arm silently reported EOF on every line.  Detect EOF via `??` with a
// NUL-string marker instead — mirrors `Std.EnvironmentHost.hostGetVarOpt`
// (#4750/#4752).  A NUL byte cannot appear in a real line read by
// `BufferedReader.readLine()` (it terminates the underlying stream read), so
// `\0` is safe as an unset sentinel here too.
pub func hostReadLineOpt(): Option[String] {
  val v = hostConsoleReadLine() ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  val e = JSystem.err
  e.println(text)
}
