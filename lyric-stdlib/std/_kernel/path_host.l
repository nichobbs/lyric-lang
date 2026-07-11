//! std/_kernel/path_host.l - host boundary for System.IO.Path.
//!
//! Pure string/path computations; never throws.  Used by Std.Path.
//!
//! Internal: only Std.Path should import this.
@axiom("System.IO.Path operations conform to their documented .NET contracts")
package Std.PathHost

extern type NetPath = "System.IO.Path"

pub func hostPathCombine(base: in String, relative: in String): String {
  NetPath.Combine(base, relative)
}

pub func hostPathGetExtension(path: in String): String {
  NetPath.GetExtension(path)
}

pub func hostPathGetFileName(path: in String): String {
  NetPath.GetFileName(path)
}

pub func hostPathGetDirectoryName(path: in String): String? {
  NetPath.GetDirectoryName(path)
}

pub func hostPathIsRooted(path: in String): Bool {
  NetPath.IsPathRooted(path)
}
