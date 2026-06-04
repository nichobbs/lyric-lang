//! std/_kernel_jvm/format_host.l — JVM host boundary for number and string
//! formatting.
//!
//! padLeft / padRight have been removed (rewritten in pure Lyric in format.l).
//! Remaining operations route through lyric.stdlib.jvm.FormatHost shims:
//!
//!   toHexString       — Integer.toHexString(n); Java method, different class.
//!   toHexStringUpper  — Integer.toHexString(n).toUpperCase().
//!   formatFixed       — String.format("%.{d}f", x) with Locale.US.
//!
//! Internal: only Std.Format should import this.
@axiom("lyric.stdlib.jvm.FormatHost formatting operations conform to their documented JVM contracts")
package Std.FormatHost

@externTarget("lyric.stdlib.jvm.FormatHost.toHexString")
pub func hostToHexString(n: in Int): String = ()

@externTarget("lyric.stdlib.jvm.FormatHost.toHexStringUpper")
pub func hostToHexStringUpper(n: in Int): String = ()

@externTarget("lyric.stdlib.jvm.FormatHost.formatFixed")
pub func hostFormatFixed(x: in Double, decimals: in Int): String = ()
