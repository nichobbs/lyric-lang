//! std/assembly_resources.l — read embedded resources from .NET PE
//! assemblies (#1229 Phase A.2).
//!
//! Public surface:
//!   * `openAssembly(path) -> AssemblyResources` — load by path.
//!   * `resourceNames(ar) -> slice[String]` — every embedded name.
//!   * `tryReadResource(ar, name) -> Option[slice[Byte]]` — bytes if
//!     present, None otherwise.
//!
//! Primary consumer is the self-hosted MSIL bridge's
//! `Lyric.ContractMeta` JSON reader for restored dependencies (the
//! in-process replacement for the F# `--internal-contract-meta read`
//! subprocess).  Generally usable for any caller that needs to peek
//! at embedded resources of a .NET DLL/EXE without taking on the
//! `Mono.Cecil` dependency.
//!
//! Lifetime: assemblies are loaded via `Assembly.Load(byte[])`, which
//! creates a fresh assembly from the image bytes on every call (no
//! identity dedup — this is deliberate; see the host file's
//! `hostAssemblyLoad` doc for why `Assembly.LoadFrom`'s identity cache
//! made it unusable for reading many freshly emitted same-named DLLs).
//! Each loaded assembly stays in the current AssemblyLoadContext
//! (default = process lifetime).  This is acceptable for compile-time
//! consumers — a single build invocation reads a bounded set of DLLs.
//! Avoid using this from long-lived servers reading many distinct
//! assemblies — file a follow-up if that use case surfaces.
//! .NET-only.  The underlying kernel binds `System.Reflection.Assembly`;
//! the JVM equivalent would wrap `java.util.jar.JarFile` (tracked in
//! #1229 Phase B).  Without this gate, JVM builds importing
//! `Std.AssemblyResources` would fail at link time because the kernel
//! externs target BCL types that don't exist there (#1249).
@cfg(feature = "dotnet")
package Std.AssemblyResources

import Std.Core
import Std.Collections
import Std.File as File
import Std.AssemblyResourcesHost

/// Opaque handle to a loaded assembly's resource surface.  Wraps the
/// CLR `Assembly` handle plus a snapshot of the resource-name list.
/// `opaque type` (not `pub record`) keeps the `RuntimeAssembly` kernel
/// extern type out of consumers' view — the only legal use of an
/// `AssemblyResources` value outside this package is to pass it to
/// `resourceNames` / `tryReadResource`.
///
/// Lifetime: no explicit close.  See the package header for the
/// rationale — the underlying assembly is loaded from image bytes via
/// `Assembly.Load(byte[])` and lives for the process AssemblyLoadContext.
@stable(since = "0.1")
pub opaque type AssemblyResources {
  asm: RuntimeAssembly
  names: slice[String]
}

/// Load `path` and snapshot its embedded resource names.  Throws
/// (Lyric `Bug`) on file-not-found or malformed PE.  Callers that
/// need a try-friendly API should wrap with
/// `try { … } catch Bug as _ { None }`.
@stable(since = "0.1")
pub func openAssembly(path: in String): AssemblyResources {
  // Read the image bytes through `Std.File` (which owns the audited
  // `File.ReadAllBytes` extern) rather than declaring a duplicate kernel
  // extern, then load via the identity-independent `Assembly.Load(byte[])`.
  val image = File.readBytesOrPanic(path)
  val asm = hostAssemblyLoad(image)
  val names = hostAssemblyResourceNames(asm)
  AssemblyResources(asm = asm, names = names)
}

/// Every embedded-resource name in the assembly, in the order returned
/// by `Assembly.GetManifestResourceNames()` (CLR-stable per assembly
/// build, useful for deterministic iteration in tests).
@stable(since = "0.1")
pub func resourceNames(ar: in AssemblyResources): slice[String] {
  ar.names
}

// Linear scan over the snapshot — name lists are tiny (~1-30 entries
// per Lyric DLL) so a Dictionary is overkill.  Returns true when
// `needle` appears in the snapshot.
func containsName(names: in slice[String], needle: in String): Bool {
  var i = 0
  while i < names.length {
    if names[i] == needle {
      return true
    }
    i = i + 1
  }
  false
}

/// Read the bytes of the embedded resource named `name`.  Returns
/// `None` when the resource isn't present (the kernel's
/// `Assembly.GetManifestResourceStream` would return null and panic
/// on the subsequent `CopyTo`; we guard with the name-list snapshot
/// taken at `openAssembly` time).  Disposes the per-call resource
/// stream + `MemoryStream` accumulator before returning so callers
/// don't leak file handles when reading many resources in a row.
@stable(since = "0.1")
pub func tryReadResource(ar: in AssemblyResources, name: in String): Option[slice[Byte]] {
  if not containsName(ar.names, name) {
    return None
  }
  val stream = hostAssemblyResourceStream(ar.asm, name)
  val ms = hostNewMemoryStream()
  hostStreamCopyTo(stream, ms)
  val bytes = hostMemoryStreamToArray(ms)
  hostMemoryStreamDispose(ms)
  hostStreamDispose(stream)
  Some(value = bytes)
}
