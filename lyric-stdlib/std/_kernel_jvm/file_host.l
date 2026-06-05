//! std/_kernel_jvm/file_host.l — JVM host boundary for file and directory I/O.
//!
//! Mirrors _kernel/file_host.l for the JVM target.  Routes through the
//! lyric.stdlib.jvm.FileHost shim (also used by _kernel_jvm/io.l's
//! Std.IO package), which wraps java.nio.file.Files / java.nio.file.Path.
//!
//! Provides the same Std.FileHost package surface as _kernel/file_host.l
//! so that Std.File can import Std.FileHost on both targets without change.
//!
//! Internal: only Std.File should import this.
@axiom("lyric.stdlib.jvm.FileHost operations conform to their documented JVM contracts")
package Std.FileHost

extern package lyric.stdlib.jvm.FileHost {
  // Existence probes — never throw for invalid paths.
  pub func fileExists(path: in String): Bool
  pub func directoryExists(path: in String): Bool

  // Text-mode I/O backed by java.nio.file.Files.readString / writeString.
  // Both throw java.io.IOException on failure; Std.File wraps in try/catch.
  pub func readAllText(path: in String): String
  pub func writeAllText(path: in String, text: in String): Unit

  // Directory creation backed by java.nio.file.Files.createDirectories.
  pub func createDirectory(path: in String): Unit

  // Bytes-mode I/O backed by java.nio.file.Files.readAllBytes / write.
  pub func readAllBytes(path: in String): slice[Byte]
  pub func writeAllBytes(path: in String, bytes: in slice[Byte]): Unit
  // Re-export with the names Std.File expects (matching _kernel/file_host.l).
}

pub func hostFileExists(path: in String): Bool = lyric.stdlib.jvm.FileHost.fileExists(path)

pub func hostDirectoryExists(path: in String): Bool = lyric.stdlib.jvm.FileHost.directoryExists(path)

pub func hostReadAllText(path: in String): String = lyric.stdlib.jvm.FileHost.readAllText(path)

pub func hostWriteAllText(path: in String, contents: in String): Unit = lyric.stdlib.jvm.FileHost.writeAllText(path, contents)

pub func hostCreateDirectory(path: in String): Unit = lyric.stdlib.jvm.FileHost.createDirectory(path)

pub func hostReadAllBytes(path: in String): slice[Byte] = lyric.stdlib.jvm.FileHost.readAllBytes(path)

pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit = lyric.stdlib.jvm.FileHost.writeAllBytes(path, bytes)
