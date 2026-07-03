//! std/_kernel_jvm/file_host.l — JVM host boundary for file and directory I/O.
//!
//! Mirrors _kernel/file_host.l for the JVM target.  Pure Lyric over the JVM
//! auto-FFI against the JDK (`java.io.File` / `FileInputStream` /
//! `FileOutputStream`) — no `lyric.stdlib.jvm.*` shim classes (the previous
//! version routed every function through a `lyric.stdlib.jvm.FileHost` class
//! that never existed at runtime; same elimination as the `time_host.l` /
//! `collections_host.l` rewrites, D-progress-543).
//!
//! API divergences from the .NET twin bridged here:
//!
//!   - hostGetLastWriteTimeUtc: the .NET kernel returns a `DateTime` compared
//!     via `hostDateTimeGreaterThan`; the JDK reports epoch-milliseconds
//!     (`File.lastModified()`, 0L when absent).  Both targets expose the same
//!     two-function surface — an opaque timestamp + a greater-than — so
//!     `Std.File` compiles unchanged; on the JVM the timestamp is the epoch
//!     Long itself.
//!   - hostCreateDirectory: `File.mkdirs()` (creates parents, returns a
//!     success Bool that is discarded); the .NET twin returns DirectoryInfo.
//!     Std.File ignores the result on both targets.
//!   - Text I/O: whole-file byte read/write with explicit UTF-8 conversion
//!     (`String(byte[], "UTF-8")` / the `stringToUtf8Bytes` intrinsic),
//!     matching the .NET kernel's File.ReadAllText UTF-8 default.
//!   - Enumeration: `File.listFiles()` filtered by `isFile()`/`isDirectory()`,
//!     yielding absolute paths (`getPath()` on children of an absolute parent
//!     matches the BCL's Directory.GetFiles full-path behaviour for the
//!     absolute-input case Std.File uses).
//!
//! Failures follow the JDK contracts: read/write on a missing or unreadable
//! path throws `IOException` (surfaced to Lyric as a catchable `Bug`), which
//! `Std.File` wraps into `Result.Err(IOError)` — the same division of labour
//! as the .NET kernel.
//!
//! Internal: only Std.File should import this.
@axiom("java.io.File / FileInputStream / FileOutputStream conform to their documented JVM contracts")
package Std.FileHost

import Std.Core

// ── JDK extern types ──────────────────────────────────────────────────────────
extern type JFile = "java.io.File"

extern type JFIS = "java.io.FileInputStream"

extern type JFOS = "java.io.FileOutputStream"

extern type JString = "java.lang.String"

// ── Existence probes — never throw for invalid paths ─────────────────────────
pub func hostFileExists(path: in String): Bool {
  val f = JFile.new(path)
  f.isFile()
}

pub func hostDirectoryExists(path: in String): Bool {
  val f = JFile.new(path)
  f.isDirectory()
}

// ── Text-mode I/O (UTF-8) ─────────────────────────────────────────────────────
pub func hostReadAllText(path: in String): String {
  val bytes = hostReadAllBytes(path)
  JString.new(bytes, "UTF-8")
}

pub func hostWriteAllText(path: in String, contents: in String): Unit {
  hostWriteAllBytes(path, stringToUtf8Bytes(contents))
}

// ── Last-write timestamp ──────────────────────────────────────────────────────
/// `FileTime` is the target-neutral name consumers (Std.File's FileStat)
/// use for the opaque last-write timestamp: the boxed epoch-milliseconds
/// here, System.DateTime in the .NET kernel.
extern type FileTime = "java.lang.Long"

extern type JLong = "java.lang.Long"

/// Boxed epoch-milliseconds of the last modification (0 when the file is
/// absent), compared via `hostDateTimeGreaterThan`.
pub func hostGetLastWriteTimeUtc(path: in String): FileTime {
  val f = JFile.new(path)
  JLong.valueOf(f.lastModified())
}

pub func hostDateTimeGreaterThan(a: in FileTime, b: in FileTime): Bool {
  a.longValue() > b.longValue()
}

// ── Directory creation ────────────────────────────────────────────────────────
/// Creates `path` and any missing parents.  `mkdirs()` returns false when the
/// directory already exists — Std.File treats creation as idempotent, so the
/// result is discarded on both targets.
pub func hostCreateDirectory(path: in String): Unit {
  val f = JFile.new(path)
  f.mkdirs()
}

// ── Bytes-mode I/O ────────────────────────────────────────────────────────────
pub func hostReadAllBytes(path: in String): slice[Byte] {
  val fis = JFIS.new(path)
  val all = fis.readAllBytes()
  fis.close()
  all
}

pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit {
  val fos = JFOS.new(path)
  fos.write(bytes)
  fos.close()
}

// ── Enumeration — absolute paths, non-recursive ──────────────────────────────
pub func hostEnumerateFiles(path: in String): slice[String] {
  listChildren(path, 1)
}

pub func hostEnumerateDirectories(path: in String): slice[String] {
  listChildren(path, 2)
}

pub func hostEnumerateFileSystemEntries(path: in String): slice[String] {
  listChildren(path, 0)
}

// kind: 0 = all entries, 1 = files only, 2 = directories only.
func listChildren(path: in String, kind: in Int): slice[String] {
  val d = JFile.new(path)
  val children = d.listFiles()
  val out2: List[String] = newList()
  var i = 0
  while i < children.count {
    val c = children[i]
    var keep = true
    if kind == 1 {
      keep = c.isFile()
    }
    if kind == 2 {
      keep = c.isDirectory()
    }
    if keep {
      out2.add(c.getPath())
    }
    i = i + 1
  }
  out2.toArray()
}

// ── Deletion ──────────────────────────────────────────────────────────────────
pub func hostDeleteFile(path: in String): Unit {
  val f = JFile.new(path)
  f.delete()
}

pub func hostDeleteDirectory(path: in String): Unit {
  val f = JFile.new(path)
  f.delete()
}

pub func hostDeleteDirectoryRecursive(path: in String, recursive: in Bool): Unit {
  if recursive {
    deleteRecursively(path)
  } else {
    hostDeleteDirectory(path)
  }
}

func deleteRecursively(path: in String): Unit {
  val d = JFile.new(path)
  if d.isDirectory() {
    val children = d.listFiles()
    var i = 0
    while i < children.count {
      deleteRecursively(children[i].getPath())
      i = i + 1
    }
  }
  d.delete()
}
