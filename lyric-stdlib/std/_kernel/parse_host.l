//! std/_kernel/parse_host.l - host boundary for primitive parsing.
//!
//! Int and Long parsing have been rewritten in pure Lyric in
//! stdlib/std/parse.l.  Double uses the invariant-culture 4-arg overload
//! so "3.14" parses correctly regardless of process locale (fixes the
//! mismatch with Std.Format which already uses InvariantCulture).
//! Internal: only `Std.Parse` should import this.
@axiom("System.Double/Boolean.TryParse conform to their documented .NET contracts")
package Std.ParseHost

extern type CultureInfo = "System.Globalization.CultureInfo"

extern type NumberStyles = "System.Globalization.NumberStyles"

// System.Globalization.CultureInfo.InvariantCulture (static property).
@externTarget("System.Globalization.CultureInfo.InvariantCulture")
pub func hostInvariantCulture(): CultureInfo = ()

// System.Globalization.NumberStyles.Float (enum field).
@externTarget("System.Globalization.NumberStyles.Float")
pub func hostNumberStylesFloat(): NumberStyles = ()

// System.Double.TryParse(string, NumberStyles, IFormatProvider, out double).
// Arity-4 static overload — invariant culture eliminates locale-dependent failures.
@externTarget("System.Double.TryParse")
pub func hostTryParseDoubleRaw(s: in String, styles: in NumberStyles, culture: in CultureInfo, value: out Double): Bool = ()

/// Target-neutral surface consumed by `Std.Parse` (the JVM kernel twin
/// exports the same two-argument shape): invariant-culture float parse.
pub func hostTryParseDouble(s: in String, value: out Double): Bool {
  // T0086 does not credit out-forwarding as an assignment.
  value = 0.0
  hostTryParseDoubleRaw(s, hostNumberStylesFloat(), hostInvariantCulture(), value)
}

@externTarget("System.Boolean.TryParse")
pub func hostTryParseBool(s: in String, value: out Bool): Bool = ()
