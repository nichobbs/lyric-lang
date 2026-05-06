// std/_kernel_jvm/parse_host.l - JVM host boundary for primitive parsing.
//
// Mirrors _kernel/parse_host.l for the JVM target.
//
// Java's parsing methods (Integer.parseInt, Long.parseLong,
// Double.parseDouble, Boolean.parseBoolean) throw NumberFormatException
// on failure rather than providing a TryParse(string, out T): Bool
// pattern.  All four operations route through lyric.stdlib.jvm.ParseHost
// shims that catch the exception and write the parsed value via the out
// parameter, returning false on failure.
//
// Internal: only Std.Parse should import this.

@axiom("lyric.stdlib.jvm.ParseHost operations conform to their documented JVM contracts")
package Std.ParseHost

extern package lyric.stdlib.jvm.ParseHost {
  pub func hostTryParseInt(s: in String, value: out Int): Bool
  pub func hostTryParseLong(s: in String, value: out Long): Bool
  pub func hostTryParseDouble(s: in String, value: out Double): Bool
  pub func hostTryParseBool(s: in String, value: out Bool): Bool
}
