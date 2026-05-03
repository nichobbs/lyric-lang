// std/log_host.l - trusted host boundary for diagnostics output.
//
// The safe logging package keeps the public surface small while the
// host boundary decides where messages go in this source-level draft.

@axiom("Host logging writes diagnostic messages according to its configured sinks")
package Std.LogHost

extern package System.Diagnostics {
  pub func write(level: in String, message: in String): Unit
    requires: level.length > 0
}
