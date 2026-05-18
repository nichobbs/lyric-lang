// std/_kernel_jvm/io.l - trusted JVM host boundary for stdlib IO.
//
// Mirrors _kernel/io.l for the JVM target.  All routing goes through
// lyric.stdlib.jvm.ConsoleHost / lyric.stdlib.jvm.FileHost shim
// classes rather than BCL statics.  The shim classes wrap:
//   ConsoleHost: java.lang.System.{out,err,in} + BufferedReader
//   FileHost:    java.nio.file.Files / java.nio.file.Path

@axiom("lyric.stdlib.jvm ConsoleHost and FileHost operations conform to their documented JVM contracts")
package Std.IO

extern package lyric.stdlib.jvm.ConsoleHost {
  // Output calls are used by Std.Console's Unit-returning print APIs.
  pub func write(text: in String): Unit
  pub func writeLine(text: in String): Unit
  pub func errorWriteLine(text: in String): Unit

  // Returns null at EOF (mapped to None by Std.Console.readLine).
  // Backed by a lazily-created BufferedReader over System.in; the
  // reader is shared for the process lifetime.
  pub func readLine(): String?
}

extern package lyric.stdlib.jvm.FileHost {
  // Opaque handle reserved for future stream APIs.
  // Phase 3 file helpers use static host functions instead.
  pub exposed type File

  // Existence probes never throw for invalid paths.
  pub func fileExists(path: in String): Bool

  // Read/write operations keep host exception behavior at the axiom
  // boundary; Std.File catches and normalises failures.
  // Backed by java.nio.file.Files.readString / writeString.
  pub func readAllText(path: in String): String
    requires: path.length > 0

  pub func writeAllText(path: in String, text: in String): Unit
    requires: path.length > 0

  // Backed by java.nio.file.Files.readAllBytes / write.
  pub func readAllBytes(path: in String): slice[Byte]
    requires: path.length > 0
    ensures: result.length >= 0

  pub func writeAllBytes(path: in String, bytes: in slice[Byte]): Unit
    requires: path.length > 0

  pub func directoryExists(path: in String): Bool

  // Backed by java.nio.file.Files.createDirectories (creates parents).
  pub func createDirectory(path: in String): Unit
    requires: path.length > 0

  // Backed by java.nio.file.Files.walk / find.
  pub func enumerateFileSystemEntries(path: in String): slice[String]
    requires: path.length > 0

  pub func enumerateFiles(path: in String): slice[String]
    requires: path.length > 0

  pub func enumerateDirectories(path: in String): slice[String]
    requires: path.length > 0

  // Shallow delete requires an empty directory.
  pub func deleteDirectory(path: in String): Unit
    requires: path.length > 0

  // Backed by java.nio.file.Files.walk + deleteIfExists (reverse order).
  pub func deleteDirectoryRecursive(path: in String): Unit
    requires: path.length > 0

  // Path helpers backed by java.nio.file.Path / java.io.File utilities.
  pub func getExtension(path: in String): String
  pub func getFileName(path: in String): String
  pub func getDirectoryName(path: in String): String?
  pub func combine(base: in String, relative: in String): String
  pub func isPathRooted(path: in String): Bool
}
