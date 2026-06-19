//! std/_kernel_jvm/parse_host.l - JVM host boundary for primitive parsing.
//!
//! Int and Long parsing have been rewritten in pure Lyric in
//! stdlib/std/parse.l.  Double and Bool continue to route through JVM
//! shims for platform-correct behaviour.
//! Internal: only Std.Parse should import this.
@axiom("lyric.stdlib.jvm.ParseHost operations conform to their documented JVM contracts")
package Std.ParseHost

extern package lyric.stdlib.jvm.ParseHost {
  pub func hostTryParseDouble(s: in String, value: out Double): Bool
  pub func hostTryParseBool(s: in String, value: out Bool): Bool
}
