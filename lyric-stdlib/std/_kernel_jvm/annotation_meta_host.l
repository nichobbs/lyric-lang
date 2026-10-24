//! std/_kernel_jvm/annotation_meta_host.l - JVM twin of
//! `_kernel/annotation_meta_host.l`.
//!
//! The compiler writes one `Lyric.AnnotationMeta.<Pkg>` JAR entry per
//! compiled package (#6866, D-progress-941).  The JDK offers no way to list
//! resources by prefix through a class loader, so this kernel walks the
//! entries of every `.jar` on `java.class.path` (the jar running the program,
//! including a bundled stdlib, is always on it) and returns the UTF-8 text of
//! each entry whose name carries the prefix.  No class is loaded or
//! reflected on: only the archive entry names and bytes are read.  Decoding
//! the JSON happens in pure Lyric in `Std.AnnotationMeta`.
//!
//! A class-path entry that is not an existing `.jar` file (a directory of
//! classes, a missing path) carries no annotation metadata and is skipped; a
//! jar that exists but cannot be opened or read fails loudly with the JDK's
//! message.
@axiom("java.util.zip.ZipInputStream and java.lang.System.getProperty conform to their documented JVM contracts")
@io
package Std.AnnotationMetaHost

import Std.Core
import Std.Collections
import Std.String as Str

extern type JAmSystem = "java.lang.System"

extern type JAmFile = "java.io.File"

extern type JAmFileInputStream = "java.io.FileInputStream"

extern type JAmZipInputStream = "java.util.zip.ZipInputStream"

extern type JAmObjects = "java.util.Objects"

extern type JAmString = "java.lang.String"

func isAnnotationMetaEntry(name: in String): Bool {
  name == "Lyric.AnnotationMeta" or name.startsWith("Lyric.AnnotationMeta.")
}

// `ZipEntry.toString()` is the entry name.  `getNextEntry()` returns null at
// the end of the archive, which `Objects.toString(Object, String)` maps to
// the empty default; a real entry name is never empty.
func nextEntryName(zis: in JAmZipInputStream): String {
  JAmObjects.toString(zis.getNextEntry(), "")
}

func scanEntries(zis: in JAmZipInputStream, acc: in List[String]): Unit {
  var more = true
  while more {
    val name = nextEntryName(zis)
    if name.length == 0 {
      more = false
    } else if isAnnotationMetaEntry(name) {
      acc.add(JAmString.new(zis.readAllBytes(), "UTF-8"))
    }
  }
}

func scanJar(path: in String, acc: in List[String]): Unit {
  val fis = JAmFileInputStream.new(path)
  val zis = JAmZipInputStream.new(fis)
  try {
    scanEntries(zis, acc)
    zis.close()
  } catch Bug as b {
    zis.close()
    panic(b.message)
  }
}

/// True when this target embeds and can read `Lyric.AnnotationMeta`
/// resources.
pub func hostAnnotationMetaSupported(): Bool {
  true
}

/// The UTF-8 text of every `Lyric.AnnotationMeta.<Pkg>` entry in any jar on
/// the class path, in class-path then archive order.  Empty when no jar
/// carries one.
pub func hostAnnotationMetaDocuments(): slice[String] {
  val acc: List[String] = newList()
  val classPath = JAmSystem.getProperty("java.class.path") ?? ""
  val entries = Str.split(classPath, JAmFile.pathSeparator)
  var i = 0
  while i < entries.length {
    val p = entries[i]
    if p.endsWith(".jar") and JAmFile.new(p).isFile() {
      scanJar(p, acc)
    }
    i = i + 1
  }
  acc.toArray()
}
