//! iface_dump.l - the text form of a package interface, printed by
//! `lyric interface dump` (docs/70 §9.6).
//!
//! The dump is total over the model: two interfaces with the same dump are the
//! same interface, which is what the producer's round-trip check (I0005)
//! compares.  It lists the canonical form, so it does not depend on the order
//! a producer collected declarations in.
package Lyric.Iface

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Symbols

func joinList(xs: in List[String], sep: in String): String {
  var buf = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      buf = buf + sep
    }
    buf = buf + xs[i]
    i = i + 1
  }
  buf
}

/// The text of `i`, one line per fact, in canonical order.
pub func dumpIface(i: in Iface): String {
  val c = canonicalIface(i)
  val lines: List[String] = newList()
  lines.add("interface " + c.header.pkg + " (format " + toString(c.header.formatVersion) + ")")
  lines.add("verification: " + ifVerifName(c.header.verification))
  lines.add("targets: " + joinList(c.header.targets, ", "))
  lines.add("annotations: " + joinList(c.header.consumerAnnotations, ", "))
  lines.add("reexports: " + joinList(c.reexports, ", "))
  lines.add("built against (" + toString(c.header.builtAgainst.count) + "):")
  for b in c.header.builtAgainst {
    lines.add("  " + b.pkg + " " + b.version + " " + b.hash)
  }
  lines.add("declarations (" + toString(c.decls.count) + "):")
  for d in c.decls {
    lines.add("  " + ifVisName(d.vis) + " " + ifKindName(d.kind) + " " + defPathKey(d.path))
  }
  joinList(lines, "\n") + "\n"
}
