// std/_kernel/path_host.l - host boundary for System.IO.Path.
//
// Pure string/path computations; never throws.  Used by Std.Path.
//
// Internal: only Std.Path should import this.

@axiom("System.IO.Path operations conform to their documented .NET contracts")
package Std.PathHost

@externTarget("System.IO.Path.Combine")
pub func hostPathCombine(base: in String, relative: in String): String = ()

@externTarget("System.IO.Path.GetExtension")
pub func hostPathGetExtension(path: in String): String = ()

@externTarget("System.IO.Path.GetFileName")
pub func hostPathGetFileName(path: in String): String = ()

@externTarget("System.IO.Path.GetDirectoryName")
pub func hostPathGetDirectoryName(path: in String): String? = ()

@externTarget("System.IO.Path.IsPathRooted")
pub func hostPathIsRooted(path: in String): Bool = ()
