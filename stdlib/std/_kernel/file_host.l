// std/_kernel/file_host.l - host boundary for `System.IO.File` and
// `System.IO.Directory`.
//
// G10 follow-up (`docs/23-fsharp-shim-elimination.md` §5): replaces
// the F# `Lyric.Stdlib.FileHost` pair-of-statics workaround
// (`*IsValid` + `*Value` / `*Error` per operation) with direct BCL
// `@externTarget`s.  `Std.File` wraps each call in `try { … } catch
// Bug as b { … b.message }` to surface failures as `Result.Err`.
//
// Internal: only `Std.File` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.IO.File / Directory operations conform to their documented .NET contracts")
package Std.FileHost

// =====================================================================
// Probes — return Bool, never throw under normal use.
// =====================================================================

@externTarget("System.IO.File.Exists")
pub func hostFileExists(path: in String): Bool = ()

@externTarget("System.IO.Directory.Exists")
pub func hostDirectoryExists(path: in String): Bool = ()

// =====================================================================
// Text-mode IO — both methods throw on host failure (not-found,
// permission, encoding, …); callers wrap in `try { } catch`.
// =====================================================================

@externTarget("System.IO.File.ReadAllText")
pub func hostReadAllText(path: in String): String = ()

@externTarget("System.IO.File.WriteAllText")
pub func hostWriteAllText(path: in String, contents: in String): Unit = ()

// =====================================================================
// Directory creation — `CreateDirectory` returns `DirectoryInfo` in
// the BCL; `Std.File` only needs the success/throw signal.
// =====================================================================

@externTarget("System.IO.Directory.CreateDirectory")
pub func hostCreateDirectory(path: in String): Unit = ()

// =====================================================================
// Bytes-mode IO — `ReadAllBytes` returns `byte[]` (which Lyric maps
// to `slice[Byte]`); `WriteAllBytes` takes `byte[]`.  Both throw on
// host failure; `Std.File` wraps them in `try { } catch Bug as b`.
// =====================================================================

@externTarget("System.IO.File.ReadAllBytes")
pub func hostReadAllBytes(path: in String): slice[Byte] = ()

@externTarget("System.IO.File.WriteAllBytes")
pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit = ()
