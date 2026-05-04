// std/_kernel/parse_host.l - host boundary for primitive parsing.
//
// Routes the four `*.TryParse(string, out T)` BCL statics that
// Std.Parse's `parseOpt*` / `tryParse*` / `parse*` families consume.
// Internal: only `Std.Parse` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.Int32/Int64/Double/Boolean.TryParse conform to their documented .NET contracts")
package Std.ParseHost

// =====================================================================
// FFI to the BCL TryParse family.  Each returns true on success and
// writes the parsed value via the `out` parameter.
// =====================================================================

@externTarget("System.Int32.TryParse")
pub func hostTryParseInt(s: in String, value: out Int): Bool = ()

@externTarget("System.Int64.TryParse")
pub func hostTryParseLong(s: in String, value: out Long): Bool = ()

@externTarget("System.Double.TryParse")
pub func hostTryParseDouble(s: in String, value: out Double): Bool = ()

@externTarget("System.Boolean.TryParse")
pub func hostTryParseBool(s: in String, value: out Bool): Bool = ()
