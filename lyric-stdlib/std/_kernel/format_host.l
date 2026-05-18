// std/_kernel/format_host.l — host boundary for number and string formatting.
//
// All five operations resolve directly to BCL instance methods or a static
// property via the emitter's type-aware extern resolver, eliminating the
// Lyric.Stdlib.FormatHost F# shim.
//
// `System.Int32.ToString(string)` and `System.String.PadLeft/PadRight(int,char)`
// are unambiguous via instanceTyped (exact-param-type match after skipping
// the receiver arg).  `System.Double.ToString(string, IFormatProvider)` is
// resolved via instanceArity (2 remaining params), which uniquely identifies
// the format+culture overload.  `CultureInfo.InvariantCulture` resolves via
// the propGetter() fallback.
//
// Internal: only Std.Format should import this.

@axiom("System.Globalization.CultureInfo and System.String/Int/Double formatting operations conform to their documented .NET contracts")
package Std.FormatHost

extern type CultureInfo = "System.Globalization.CultureInfo"

// =====================================================================
// Culture singleton.
// =====================================================================

// System.Globalization.CultureInfo.InvariantCulture (static property).
// Returns the invariant (English) culture — decimal separator is always ".".
@externTarget("System.Globalization.CultureInfo.InvariantCulture")
pub func hostInvariantCulture(): CultureInfo = ()

// =====================================================================
// Integer formatting.
// =====================================================================

// Format an Int using a BCL format string (e.g. "x", "X", "D3").
// System.Int32.ToString(string format) — instance method.
@externTarget("System.Int32.ToString")
pub func hostIntToString(n: in Int, fmt: in String): String = ()

// =====================================================================
// Double formatting.
// =====================================================================

// Format a Double with the given BCL format string and IFormatProvider.
// System.Double.ToString(string format, IFormatProvider provider) — instance method.
// Pass hostInvariantCulture() as the provider for locale-independent output.
@externTarget("System.Double.ToString")
pub func hostDoubleToString(x: in Double, fmt: in String, culture: in CultureInfo): String = ()

