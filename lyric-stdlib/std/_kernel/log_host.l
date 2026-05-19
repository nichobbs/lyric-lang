// std/_kernel/log_host.l - host boundary for diagnostic log output.
//
// Routes Std.Log messages through Lyric.Emitter.LogHelper.write,
// a static helper that forwards to stderr with a [LEVEL] prefix.
// Internal: only Std.Log should import this.

@axiom("Host logging writes diagnostic messages according to its configured sinks")
package Std.LogHost

@externTarget("Lyric.Emitter.LogHelper.write")
pub func write(level: in String, message: in String): Unit = ()
