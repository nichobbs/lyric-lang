//! std/_kernel/annotation_meta_host.l - trusted host boundary for
//! `Std.AnnotationMeta`.
//!
//! The compiler embeds one `Lyric.AnnotationMeta` (single-package assembly)
//! or `Lyric.AnnotationMeta.<Pkg>` (project bundle) managed resource per
//! compiled package (#6866, D-progress-941).  This kernel enumerates the
//! managed resources of every loaded, non-dynamic assembly and returns the
//! JSON text of each one whose name carries that prefix.  Only the manifest
//! resource tables are read: no types, members or attributes are inspected,
//! so the seam stays free of type reflection.  Decoding the JSON happens in
//! pure Lyric in `Std.AnnotationMeta`.
@axiom("System.AppDomain.GetAssemblies and System.Reflection.Assembly manifest-resource enumeration conform to their documented .NET contracts")
@io
package Std.AnnotationMetaHost

import Std.Core
import Std.Collections

extern type NetAmDomain = "System.AppDomain"

extern type NetAmAssembly = "System.Reflection.Assembly"

extern type NetAmStream = "System.IO.Stream"

extern type NetAmReader = "System.IO.StreamReader"

// The metadata `.ctor` resolver does not bind a constructor whose argument is
// an extern-type value at a `.new()` call site, so the `StreamReader(Stream)`
// constructor is bound explicitly (same constraint `Std.ProcessCaptureHost`
// documents for `newProcReaderFrom`).
@externTarget("System.IO.StreamReader..ctor")
func newAmReader(s: in NetAmStream): NetAmReader = ()

@externTarget("System.AppDomain.GetAssemblies")
func loadedAssemblies(d: in NetAmDomain): slice[NetAmAssembly] = ()

func isAnnotationMetaResource(name: in String): Bool {
  name == "Lyric.AnnotationMeta" or name.startsWith("Lyric.AnnotationMeta.")
}

// Declared non-null: the stream is requested only for a name taken from the
// same assembly's `GetManifestResourceNames`, for which the CLR never
// returns null.
@externTarget("System.Reflection.Assembly.GetManifestResourceStream")
func resourceStream(asm: in NetAmAssembly, name: in String): NetAmStream = ()

func readAll(r: in NetAmReader): String {
  r.ReadToEnd()
}

func disposeReader(r: in NetAmReader): Unit {
  r.Dispose()
}

func readResource(asm: in NetAmAssembly, name: in String): String {
  val reader = newAmReader(resourceStream(asm, name))
  val text = readAll(reader)
  disposeReader(reader)
  text
}

func collectFromAssembly(asm: in NetAmAssembly, acc: in List[String]): Unit {
  if asm.IsDynamic {
    return
  }
  val names = asm.GetManifestResourceNames()
  var i = 0
  while i < names.length {
    if isAnnotationMetaResource(names[i]) {
      acc.add(readResource(asm, names[i]))
    }
    i = i + 1
  }
}

/// True when this target embeds and can read `Lyric.AnnotationMeta`
/// resources.
pub func hostAnnotationMetaSupported(): Bool {
  true
}

/// The JSON text of every `Lyric.AnnotationMeta[.<Pkg>]` resource embedded in
/// any loaded assembly, in assembly-load then resource-table order.  Empty
/// when no loaded assembly carries one.
pub func hostAnnotationMetaDocuments(): slice[String] {
  val acc: List[String] = newList()
  val domain: NetAmDomain = NetAmDomain.CurrentDomain
  val asms = loadedAssemblies(domain)
  var i = 0
  while i < asms.length {
    collectFromAssembly(asms[i], acc)
    i = i + 1
  }
  acc.toArray()
}
