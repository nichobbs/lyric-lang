// std/_kernel/console_host.l - host boundary for System.Console stdin/stdout.
//
// Low-level console I/O needed by the LSP framing layer.
// `consoleRead()` returns a single UTF-16 code unit (0..65535) or -1 on EOF,
// matching System.Console.Read().  `consoleWrite` writes raw text without a
// trailing newline, matching System.Console.Write(string).
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
