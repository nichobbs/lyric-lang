// std/_kernel/parse_host.l - host boundary for primitive parsing.
//
// Int and Long parsing have been rewritten in pure Lyric in
// stdlib/std/parse.l.  Double and Bool continue to route through the
// BCL for locale-correct and IEEE-754-accurate behaviour.
// Internal: only `Std.Parse` should import this.

@axiom("System.Double/Boolean.TryParse conform to their documented .NET contracts")
package Std.ParseHost

@externTarget("System.Double.TryParse")
pub func hostTryParseDouble(s: in String, value: out Double): Bool = ()

@externTarget("System.Boolean.TryParse")
pub func hostTryParseBool(s: in String, value: out Bool): Bool = ()
