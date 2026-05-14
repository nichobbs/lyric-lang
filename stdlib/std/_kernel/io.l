// std/io.l - trusted host-runtime boundary for stdlib IO.
//
// The functions in this file are intentionally thin and unsafe from
// Lyric's point of view: they expose the host surface that safe
// wrappers convert into Result-returning APIs. Keep this file small and
// reviewable; adding a host call here expands the trusted base.

@axiom("System.Console and System.IO operations conform to their documented .NET contracts")
package Std.IO

extern package System.Console {
  // Output calls are used by Std.Console's Unit-returning print APIs.
  pub func write(text: in String): Unit
  pub func writeLine(text: in String): Unit
  pub func errorWriteLine(text: in String): Unit

  // Null represents EOF. Std.Console.readLine converts it to
  // IOError.EndOfInput.
  pub func readLine(): String?
}

extern package System.IO {
  // Opaque handle type reserved for future stream and metadata APIs.
  // The Phase 3 file helpers use static host functions instead.
  pub exposed type File

  // Existence probes are total and do not throw for invalid paths.
  pub func fileExists(path: in String): Bool

  // Read/write operations keep the host's exception behavior at the
  // axiom boundary; Std.File catches and normalizes failures.
  pub func readAllText(path: in String): String
    requires: path.length > 0

  pub func writeAllText(path: in String, text: in String): Unit
    requires: path.length > 0

  pub func readAllBytes(path: in String): slice[Byte]
    requires: path.length > 0
    ensures: result.length >= 0

  pub func writeAllBytes(path: in String, bytes: in slice[Byte]): Unit
    requires: path.length > 0

  pub func directoryExists(path: in String): Bool

  // Directory operations are normalized by Std.Directory.
  pub func createDirectory(path: in String): Unit
    requires: path.length > 0

  pub func enumerateFileSystemEntries(path: in String): slice[String]
    requires: path.length > 0

  pub func enumerateFiles(path: in String): slice[String]
    requires: path.length > 0

  pub func enumerateDirectories(path: in String): slice[String]
    requires: path.length > 0

  // Shallow delete requires an empty directory. Recursive delete may
  // remove files and subdirectories; keep it as a separate trusted call
  // so reviews can spot destructive behavior.
  pub func deleteDirectory(path: in String): Unit
    requires: path.length > 0

  pub func deleteDirectoryRecursive(path: in String): Unit
    requires: path.length > 0

  // Path helpers are computations over host path syntax only.
  pub func getExtension(path: in String): String
  pub func getFileName(path: in String): String
  pub func getDirectoryName(path: in String): String?
  pub func combine(base: in String, relative: in String): String
  pub func isPathRooted(path: in String): Bool
}
