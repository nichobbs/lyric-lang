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

@externTarget("System.Console.Read")
pub func hostConsoleRead(): Int = ()

@externTarget("System.Console.Write")
pub func hostConsoleWrite(text: in String): Unit = ()

@externTarget("System.Console.WriteLine")
pub func hostConsoleWriteLine(text: in String): Unit = ()

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

@externTarget("System.Console.get_Error")
func consoleErrorWriter(): TextWriter = ()

// Targets the `TextWriter.WriteLine(string)` overload; the emitter resolves it by the `in String` parameter type.
@externTarget("System.IO.TextWriter.WriteLine")
@externInstance
func textWriterWriteLine(w: in TextWriter, text: in String): Unit = ()

pub func hostConsoleErrorWriteLine(text: in String): Unit {
  textWriterWriteLine(consoleErrorWriter(), text)
}
