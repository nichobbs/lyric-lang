//! std/_kernel_jvm/console_host.l - JVM host boundary for console IO.
//!
//! Mirrors _kernel/console_host.l for the JVM target.  Routes through
//! lyric.stdlib.jvm.ConsoleHost, which wraps java.lang.System.{out,err,in}
//! with a process-shared BufferedReader for stdin (lazily created on the
//! first readLine call).
//!
//! hostConsoleRead returns a single UTF-16 code unit (0..65535) or -1 on
//! EOF, matching the contract of the .NET kernel's System.Console.Read.
//!
//! Internal: prefer Std.Console for application code.  Import this kernel
//! module only when exact byte-level control is required (e.g. the LSP
//! Content-Length framing reader).
@axiom("lyric.stdlib.jvm.ConsoleHost operations conform to their documented JVM contracts")
package Std.ConsoleHost

@externTarget("lyric.stdlib.jvm.ConsoleHost.read")
pub func hostConsoleRead(): Int = ()

@externTarget("lyric.stdlib.jvm.ConsoleHost.write")
pub func hostConsoleWrite(text: in String): Unit = ()

@externTarget("lyric.stdlib.jvm.ConsoleHost.writeLine")
pub func hostConsoleWriteLine(text: in String): Unit = ()

@externTarget("lyric.stdlib.jvm.ConsoleHost.readLine")
pub func hostConsoleReadLine(): String? = ()

@externTarget("lyric.stdlib.jvm.ConsoleHost.errorWriteLine")
pub func hostConsoleErrorWriteLine(text: in String): Unit = ()
