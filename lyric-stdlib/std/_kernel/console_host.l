// std/_kernel/console_host.l - host boundary for System.Console stdin/stdout/stderr.
//
// Low-level console I/O needed by Std.Console and the LSP framing layer.
// `hostConsoleRead()` returns a single UTF-16 code unit (0..65535) or -1 on
// EOF, matching System.Console.Read().  Other functions match the named
// System.Console static methods.
//
// Internal: prefer Std.Console (print/println/readLine) for application code.
// Import this kernel module only when exact byte-level control is required
// (e.g. the LSP Content-Length framing reader).

@axiom("System.Console operations conform to their documented .NET contracts")
package Std.ConsoleHost

@externTarget("System.Console.Read")
pub func hostConsoleRead(): Int = ()

@externTarget("System.Console.Write")
pub func hostConsoleWrite(text: in String): Unit = ()

@externTarget("System.Console.WriteLine")
pub func hostConsoleWriteLine(text: in String): Unit = ()

@externTarget("System.Console.ReadLine")
pub func hostConsoleReadLine(): String? = ()

// stderr — routed through a thin Lyric.Emitter shim because
// Console.Error.WriteLine is not directly addressable as a static BCL call.
@externTarget("Lyric.Emitter.ConsoleHelper.writeErrorLine")
pub func hostConsoleErrorWriteLine(text: in String): Unit = ()
