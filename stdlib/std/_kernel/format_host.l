// std/_kernel/format_host.l — host boundary for number and string formatting
// operations that cannot be expressed as a single @externTarget call.
//
// Three operations require F# shims in Lyric.Stdlib.FormatHost because
// they depend on format-string overloads of BCL methods that the emitter's
// arity-based overload resolution does not currently distinguish:
//
//   hostToHexString(n)        — Int32.ToString("x")
//   hostToHexStringUpper(n)   — Int32.ToString("X")
//   hostFormatFixed(x, d)     — Double.ToString("F{d}", InvariantCulture)
//
// Two padding operations route to System.String.PadLeft / PadRight.
// These are instance methods with two parameters (width + paddingChar);
// the emitter may see multiple PadLeft overloads, so the shim provides
// an unambiguous single-overload target.
//
// Internal: only Std.Format should import this.

@axiom("Lyric.Stdlib.FormatHost and System.String formatting operations conform to their documented .NET contracts")
package Std.FormatHost

// =====================================================================
// Integer hex formatting.
// =====================================================================

// Format an Int as lowercase hexadecimal without any prefix.
// `n.ToString("x")` — e.g. 255 → "ff".
@externTarget("Lyric.Stdlib.FormatHost.ToHexString")
pub func hostToHexString(n: in Int): String = ()

// Format an Int as uppercase hexadecimal without any prefix.
// `n.ToString("X")` — e.g. 255 → "FF".
@externTarget("Lyric.Stdlib.FormatHost.ToHexStringUpper")
pub func hostToHexStringUpper(n: in Int): String = ()

// =====================================================================
// Double fixed-point formatting.
// =====================================================================

// Format a Double with exactly `decimals` digits after the decimal point,
// using invariant (English) locale so the decimal separator is always ".".
// `x.ToString("F{decimals}", CultureInfo.InvariantCulture)`.
@externTarget("Lyric.Stdlib.FormatHost.FormatFixed")
pub func hostFormatFixed(x: in Double, decimals: in Int): String = ()

// =====================================================================
// String padding.
// =====================================================================

// Left-pad `s` with `ch` to at least `width` characters.
// `System.String.PadLeft(int totalWidth, char paddingChar)`.
@externTarget("Lyric.Stdlib.FormatHost.PadLeft")
pub func hostPadLeft(s: in String, width: in Int, ch: in Char): String = ()

// Right-pad `s` with `ch` to at least `width` characters.
// `System.String.PadRight(int totalWidth, char paddingChar)`.
@externTarget("Lyric.Stdlib.FormatHost.PadRight")
pub func hostPadRight(s: in String, width: in Int, ch: in Char): String = ()
