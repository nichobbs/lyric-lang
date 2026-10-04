//! lyric-ui/src/_kernel/guard_managed.l - the failure guards of the managed
//! targets (`dotnet`, `jvm`): a panic in an effect or a failed bind is caught.
//! The native twin (`guard_native.l`, same package) has no unwinding to catch.
//!
//! Internal: only Ui.Host and Ui.Host.Desktop should import this.
@cfg(any(feature = "dotnet", feature = "jvm"))
@io
package Ui.Kernel.Guard

import Std.Core
import Std.Console as Console
import Std.HttpServer as HttpServer

/// `run(effect)`, with a panic in it reported and answered by no result.
pub func guardedEffect[E, Msg](run: in (E) -> Option[Msg], effect: in E): Option[Msg] {
  var reply: Option[Msg] = None
  try {
    reply = run(effect)
  } catch Bug as b {
    Console.error("lyric-ui: an effect failed: " + b.message)
  }
  reply
}

/// Whether a listener can bind `port` on `host` right now.
pub func canBindLoopback(host: in String, port: in Int): Bool {
  try {
    val l = HttpServer.startListener("http://" + host + ":" + port.toString() + "/")
    HttpServer.stopListener(l)
    return true
  } catch Bug as e {
    return false
  }
}
