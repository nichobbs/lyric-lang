//! std/_kernel/file_host.l - host boundary for `System.IO.File` and
//! `System.IO.Directory`.
//!
//! G10 follow-up (`docs/23-fsharp-shim-elimination.md` §5): replaces
//! the F# `Lyric.Stdlib.FileHost` pair-of-statics workaround
//! (`*IsValid` + `*Value` / `*Error` per operation) with direct BCL
//! `@externTarget`s.  `Std.File` wraps each call in `try { … } catch
//! Bug as b { … b.message }` to surface failures as `Result.Err`.
//!
//! Internal: only `Std.File` and `Std.Directory` should import this;
//! per `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
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
// File metadata — modification time via DateTime objects.
// =====================================================================
// `FileTime` is the target-neutral name consumers (Std.File's FileStat)
// use for the opaque last-write timestamp; on .NET it is System.DateTime,
// on the JVM kernel it is the boxed epoch-milliseconds Long.
extern type FileTime = "System.DateTime"

@externTarget("System.IO.File.GetLastWriteTimeUtc")
pub func hostGetLastWriteTimeUtc(path: in String): FileTime = ()

@externTarget("System.DateTime.op_GreaterThan")
pub func hostDateTimeGreaterThan(a: in FileTime, b: in FileTime): Bool = ()

// =====================================================================
// Directory creation — `CreateDirectory` returns `DirectoryInfo` in
// the BCL; `Std.File` only needs the success/throw signal.
// =====================================================================
extern type DirectoryInfo = "System.IO.DirectoryInfo"

@externTarget("System.IO.Directory.CreateDirectory")
pub func hostCreateDirectory(path: in String): DirectoryInfo = ()

// =====================================================================
// Bytes-mode IO — `ReadAllBytes` returns `byte[]` (which Lyric maps
// to `slice[Byte]`); `WriteAllBytes` takes `byte[]`.  Both throw on
// host failure; `Std.File` wraps them in `try { } catch Bug as b`.
// =====================================================================
@externTarget("System.IO.File.ReadAllBytes")
pub func hostReadAllBytes(path: in String): slice[Byte] = ()

@externTarget("System.IO.File.WriteAllBytes")
pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit = ()

// =====================================================================
// Directory enumeration — used by the LSP workspace index builder.
// =====================================================================
@externTarget("System.IO.Directory.GetFiles")
pub func hostEnumerateFiles(path: in String): slice[String] = ()

@externTarget("System.IO.Directory.GetDirectories")
pub func hostEnumerateDirectories(path: in String): slice[String] = ()

@externTarget("System.IO.Directory.GetFileSystemEntries")
pub func hostEnumerateFileSystemEntries(path: in String): slice[String] = ()

@externTarget("System.IO.Directory.Delete")
pub func hostDeleteDirectory(path: in String): Unit = ()

@externTarget("System.IO.Directory.Delete")
pub func hostDeleteDirectoryRecursive(path: in String, recursive: in Bool): Unit = ()

@externTarget("System.IO.File.Delete")
pub func hostDeleteFile(path: in String): Unit = ()
