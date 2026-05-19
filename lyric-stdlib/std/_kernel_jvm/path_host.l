// std/_kernel_jvm/path_host.l - JVM host boundary for path manipulation.
//
// Mirrors _kernel/path_host.l for the JVM target.  Pure string/path
// computations; never throws.  Used by Std.Path.
//
// All operations route through lyric.stdlib.jvm.PathHost, which wraps
// java.nio.file.{Path,Paths} and java.io.File.  The shim is preferred
// over direct Java calls because:
//   - .NET's `Path.Combine(base, "/abs")` returns "/abs", whereas
//     Java's `Paths.get(base).resolve("/abs")` returns "/abs" too,
//     but `Paths.get(base, "/abs").toString()` does not — the shim
//     normalises the behaviour.
//   - `GetFileName` / `GetDirectoryName` differ between platforms
//     when the path ends in a trailing separator.
//
// Internal: only Std.Path should import this.

@axiom("lyric.stdlib.jvm.PathHost operations conform to their documented JVM contracts")
package Std.PathHost

@externTarget("lyric.stdlib.jvm.PathHost.combine")
pub func hostPathCombine(base: in String, relative: in String): String = ()

@externTarget("lyric.stdlib.jvm.PathHost.getExtension")
pub func hostPathGetExtension(path: in String): String = ()

@externTarget("lyric.stdlib.jvm.PathHost.getFileName")
pub func hostPathGetFileName(path: in String): String = ()

@externTarget("lyric.stdlib.jvm.PathHost.getDirectoryName")
pub func hostPathGetDirectoryName(path: in String): String? = ()

@externTarget("lyric.stdlib.jvm.PathHost.isPathRooted")
pub func hostPathIsRooted(path: in String): Bool = ()
