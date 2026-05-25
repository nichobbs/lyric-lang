// std/_kernel/assembly_resources_host.l — host boundary for reading
// embedded `Lyric.Contract.*` (and any other) resources from .NET
// PE assemblies.  Used by the self-hosted MSIL bridge's
// restored-dependency loader (#1229 Phase A.2).
//
// Why `System.Reflection.Assembly.LoadFrom` and not
// `System.Reflection.Metadata.PEReader`: `PEReader`'s embedded-
// resource read path requires either unsafe pointer arithmetic
// (Lyric doesn't expose unsafe pointers) or a ~12-extern chain
// through the `BlobReader` value-type API.  `Assembly.LoadFrom` ships
// in the same `System.Runtime.dll` (no new BCL dep) and reduces the
// extern surface to 8 host calls + 3 types — 6 read/walk calls plus
// the `hostStreamDispose` / `hostMemoryStreamDispose` pair so callers
// reading many resources release file handles deterministically.
// The trade-off is that `LoadFrom` JIT-resolves the assembly into
// the current `AssemblyLoadContext`; for compile-time consumers
// like the self-hosted MSIL bridge this overhead is irrelevant, and
// the process-lifetime accumulation matches the F# emitter's
// `Mono.Cecil.AssemblyDefinition` semantics (which also doesn't
// dispose).
//
// Internal: only `Std.AssemblyResources` should import this.

@axiom("System.Reflection.Assembly + System.IO.MemoryStream + System.IO.Stream operations conform to their documented .NET contracts")
package Std.AssemblyResourcesHost

import Std.Collections

// ── Extern type aliases ────────────────────────────────────────────────────

/// CLR `System.Reflection.Assembly` — loaded assembly handle.  Loaded
/// assemblies live for the AssemblyLoadContext's lifetime (default
/// context = process lifetime).  No Dispose API.
extern type RuntimeAssembly = "System.Reflection.Assembly"

/// CLR `System.IO.Stream` — the abstract base class returned by
/// `GetManifestResourceStream`.  Concrete returned type is
/// `UnmanagedMemoryStream` for embedded resources.
extern type ResStream = "System.IO.Stream"

/// CLR `System.IO.MemoryStream` — used as the accumulator when
/// copying a resource stream into a `byte[]` payload.
extern type ResMemoryStream = "System.IO.MemoryStream"

// ── Host functions ─────────────────────────────────────────────────────────

/// Resolves to `Assembly.LoadFrom(string)`.  Throws `FileNotFoundException`
/// when the path doesn't exist; callers should pre-check with `Std.File`.
@externTarget("System.Reflection.Assembly.LoadFrom")
pub func hostAssemblyLoadFrom(path: in String): RuntimeAssembly = ()

/// Resolves to `Assembly.GetManifestResourceNames(): string[]`.  Returns
/// every embedded resource name in the assembly (excludes linked
/// resources and assembly-relative file references).
@externTarget("System.Reflection.Assembly.GetManifestResourceNames")
pub func hostAssemblyResourceNames(asm: in RuntimeAssembly): slice[String] = ()

/// Resolves to `Assembly.GetManifestResourceStream(string): Stream`.
/// Returns null when the named resource isn't present — callers must
/// only invoke this for names already known to exist (via
/// `hostAssemblyResourceNames`).  Lyric doesn't expose null-checking
/// on extern types, so passing a null `ResStream` to subsequent
/// host calls will panic; this is the established convention.
@externTarget("System.Reflection.Assembly.GetManifestResourceStream")
pub func hostAssemblyResourceStream(asm: in RuntimeAssembly,
                                    name: in String): ResStream = ()

/// Resolves to `new System.IO.MemoryStream()`.  Default-capacity ctor.
@externTarget("System.IO.MemoryStream..ctor")
pub func hostNewMemoryStream(): ResMemoryStream = ()

/// Resolves to `Stream.CopyTo(Stream)`.  Reads `src` to EOF and writes
/// every byte to `dst`.  Used to drain a resource stream into a
/// `MemoryStream` accumulator before extracting the underlying buffer.
@externTarget("System.IO.Stream.CopyTo")
pub func hostStreamCopyTo(src: in ResStream, dst: in ResMemoryStream): Unit = ()

/// Resolves to `MemoryStream.ToArray(): byte[]`.  Returns a fresh copy
/// of the buffer's used bytes (excludes trailing capacity).  Lyric
/// maps `byte[]` to `slice[Byte]` at the FFI boundary.
@externTarget("System.IO.MemoryStream.ToArray")
pub func hostMemoryStreamToArray(ms: in ResMemoryStream): slice[Byte] = ()

/// Resolves to `Stream.Dispose()`.  Deterministic release of native
/// resources held by a `Stream` (file handles for `UnmanagedMemoryStream`
/// returned by `GetManifestResourceStream`).  Safe to call exactly
/// once per stream value.
@externTarget("System.IO.Stream.Dispose")
pub func hostStreamDispose(s: in ResStream): Unit = ()

/// Resolves to `MemoryStream.Dispose()`.  Returns the pooled
/// `byte[]` backing the accumulator to the array pool.  Same
/// semantics as `hostStreamDispose` (MemoryStream is a Stream
/// subclass) — separate extern only because Lyric's extern-type
/// aliases are nominal and the caller's value is typed as
/// `ResMemoryStream`.
@externTarget("System.IO.MemoryStream.Dispose")
pub func hostMemoryStreamDispose(ms: in ResMemoryStream): Unit = ()
