//! std/_kernel_jvm/log_host.l - JVM host boundary for diagnostics output.
//!
//! Mirrors _kernel/log_host.l for the JVM target.  Routes through a
//! shim backed by java.util.logging.Logger.  The logger is named
//! "lyric.stdlib" and honours the standard JVM logging configuration
//! (logging.properties / JUL handlers).
@axiom("lyric.stdlib.jvm.LogHost writes diagnostic messages via java.util.logging.Logger")
package Std.LogHost

extern package lyric.stdlib.jvm.LogHost {
  pub func write(level: in String, message: in String): Unit
    requires: level.length > 0
}
