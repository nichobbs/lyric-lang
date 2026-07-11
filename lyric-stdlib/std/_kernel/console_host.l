//! std/_kernel/console_host.l - host boundary for System.Console stdin/stdout/stderr.
//!
//! Low-level console I/O needed by Std.Console and the LSP framing layer.
//! `hostConsoleRead()` returns a single UTF-16 code unit (0..65535) or -1 on
//! EOF, matching System.Console.Read().  Other functions match the named
//! System.Console static methods.
//!
//! Internal: prefer Std.Console (print/println/readLine) for application code.
//! Import this kernel module only when exact byte-level control is required
//! (e.g. the LSP Content-Length framing reader).
@axiom("System.Console operations conform to their documented .NET contracts")
package Std.ConsoleHost

import Std.Core

extern type NetConsole = "System.Console"

pub func hostConsoleRead(): Int {
  NetConsole.Read()
}

pub func hostConsoleWrite(text: in String): Unit {
  NetConsole.Write(text)
}

pub func hostConsoleWriteLine(text: in String): Unit {
  NetConsole.WriteLine(text)
}

// stays @externTarget: the nullable `String?` return relies on the
// declared-signature nullable-return handling only the @externTarget
// path provides (auto-FFI has no null-return convention).
@externTarget("System.Console.ReadLine")
pub func hostConsoleReadLine(): String? = ()

// Option seam avoiding `case null`'s catch-all miscompile (#4775); NUL-marker mirrors `hostGetVarOpt` (#4750).
pub func hostReadLineOpt(): Option[String] {
  val v = hostConsoleReadLine() ?? "\u{0000}"
  if v == "\u{0000}" {
    None
  } else {
    Some(value = v)
  }
}

// stderr — `Console.Error` is a static property returning a
// `System.IO.TextWriter`; compose the property getter with the writer's
// instance `WriteLine(String)` in pure Lyric (no F# shim — #1493).
extern type TextWriter = "System.IO.TextWriter"

func consoleErrorWriter(): TextWriter {
  NetConsole.Error
}

// Binds the `TextWriter.WriteLine(string)` overload; auto-FFI overload
// scoring resolves it by the String argument type.
func textWriterWriteLine(w: in TextWriter, text: in String): Unit {
  w.WriteLine(text)
}

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  textWriterWriteLine(consoleErrorWriter(), text)
}
