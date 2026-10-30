//! std/_kernel/file_host.l - host boundary for `System.IO.File` and
//! `System.IO.Directory`.
//!
//! G10 follow-up (`docs/23-fsharp-shim-elimination.md` §5): replaces
//! the F# `Lyric.Stdlib.FileHost` pair-of-statics workaround
//! (`*IsValid` + `*Value` / `*Error` per operation) with direct BCL
//! externs — now expressed as `extern type` auto-FFI calls resolved
//! from reference-assembly metadata.  `Std.File` wraps each call in
//! `try { … } catch Bug as b { … b.message }` to surface failures as
//! `Result.Err`.
//!
//! Internal: only `Std.File` and `Std.Directory` should import this;
//! per `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("System.IO.File / Directory operations conform to their documented .NET contracts")
@io
package Std.FileHost

import Std.Core
import Std.Collections
import Std.Errors
import Std.ProcessHost

extern type NetFile = "System.IO.File"

extern type NetDirectory = "System.IO.Directory"

// =====================================================================
// Probes — return Bool, never throw under normal use.
// =====================================================================
pub func hostFileExists(path: in String): Bool {
  NetFile.Exists(path)
}

pub func hostDirectoryExists(path: in String): Bool {
  NetDirectory.Exists(path)
}

// =====================================================================
// Text-mode IO — both methods throw on host failure (not-found,
// permission, encoding, …); callers wrap in `try { } catch`.
// =====================================================================
pub func hostReadAllText(path: in String): String {
  NetFile.ReadAllText(path)
}

pub func hostWriteAllText(path: in String, contents: in String): Unit {
  NetFile.WriteAllText(path, contents)
}

// =====================================================================
// File metadata — modification time via DateTime objects.
// =====================================================================
// `FileTime` is the target-neutral name consumers (Std.File's FileStat)
// use for the opaque last-write timestamp; on .NET it is System.DateTime,
// on the JVM kernel it is the boxed epoch-milliseconds Long.
extern type FileTime = "System.DateTime"

pub func hostGetLastWriteTimeUtc(path: in String): FileTime {
  NetFile.GetLastWriteTimeUtc(path)
}

// DateTime's `>` is the static operator method op_GreaterThan; spelled
// as an explicit static call on the FileTime (System.DateTime) alias.
pub func hostDateTimeGreaterThan(a: in FileTime, b: in FileTime): Bool {
  FileTime.op_GreaterThan(a, b)
}

// Issue #6961: the exception-free Result seam every kernel twin now
// implements, so `Std.File.stat`'s pure-layer body needs no
// `try`/`catch` on any target (native has none to offer — D-N-003).
// `stat()` already probes hostFileExists/hostDirectoryExists before
// calling this, so a thrown exception here is a TOCTOU race
// (deleted between the probe and this call) or a genuine host error
// (permissions, path-too-long, ...) — every case reports IoError.
pub func hostGetLastWriteTimeUtcResult(path: in String): Result[FileTime, IOError] {
  try {
    Ok(value = hostGetLastWriteTimeUtc(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

// =====================================================================
// Directory creation — `CreateDirectory` returns `DirectoryInfo` in
// the BCL; `Std.File` only needs the success/throw signal.
// =====================================================================
extern type DirectoryInfo = "System.IO.DirectoryInfo"

pub func hostCreateDirectory(path: in String): DirectoryInfo {
  NetDirectory.CreateDirectory(path)
}

// =====================================================================
// Bytes-mode IO — `ReadAllBytes` returns `byte[]` (which Lyric maps
// to `slice[Byte]`); `WriteAllBytes` takes `byte[]`.  Both throw on
// host failure; `Std.File` wraps them in `try { } catch Bug as b`.
// =====================================================================
pub func hostReadAllBytes(path: in String): slice[Byte] {
  NetFile.ReadAllBytes(path)
}

pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit {
  NetFile.WriteAllBytes(path, bytes)
}

// =====================================================================
// Directory enumeration — used by the LSP workspace index builder.
// =====================================================================
pub func hostEnumerateFiles(path: in String): slice[String] {
  NetDirectory.GetFiles(path)
}

pub func hostEnumerateDirectories(path: in String): slice[String] {
  NetDirectory.GetDirectories(path)
}

pub func hostEnumerateFileSystemEntries(path: in String): slice[String] {
  NetDirectory.GetFileSystemEntries(path)
}

pub func hostDeleteDirectory(path: in String): Unit {
  NetDirectory.Delete(path)
}

pub func hostDeleteDirectoryRecursive(path: in String, recursive: in Bool): Unit {
  NetDirectory.Delete(path, recursive)
}

pub func hostDeleteFile(path: in String): Unit {
  NetFile.Delete(path)
}

// =====================================================================
// Result seams — the exception-free surface both kernel twins
// implement (issue #4752).  On this managed side the try/catch and the
// BCL exception-message classification live HERE, so the pure
// `Std.File` layer stays target-neutral; the `_kernel_native/` twin
// implements the same signatures over lyric-rt without exceptions.
// =====================================================================
pub func hostReadTextResult(path: in String): Result[String, IOError] {
  try {
    Ok(value = hostReadAllText(path))
  } catch Bug as b {
    // Locale caveat: the "Could not find file" prefix match assumes
    // an English .NET runtime.  On non-English runtimes a real
    // FileNotFoundException may slip through as IoError until the
    // host shim is upgraded to return an exception-type tag rather
    // than the localised message text.  See lyric-lang #601.
    if b.message.startsWith("Could not find file") or b.message.contains("FileNotFoundException") or b.message.contains("DirectoryNotFoundException") {
      Err(error = FileNotFound(path = path))
    } else {
      Err(error = IoError(path = path, message = b.message))
    }
  }
}

pub func hostWriteTextResult(path: in String, text: in String): Result[Unit, IOError] {
  try {
    hostWriteAllText(path, text)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

pub func hostCreateDirResult(path: in String): Result[Unit, IOError] {
  try {
    hostCreateDirectory(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// Deletes an EMPTY directory; a non-empty one is an `IoError`.
pub func hostDeleteDirEmptyResult(path: in String): Result[Unit, IOError] {
  try {
    hostDeleteDirectory(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

pub func hostDeleteFileResult(path: in String): Result[Unit, IOError] {
  try {
    hostDeleteFile(path)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

// Bytes-mode and enumeration Result seams (issue #4752, D-N-015 slice):
// every failure reports IoError, matching the pure wrappers these
// replaced (readBytes/writeBytes/listFiles/listDirs never classified
// FileNotFound separately).
pub func hostReadBytesResult(path: in String): Result[slice[Byte], IOError] {
  try {
    Ok(value = hostReadAllBytes(path))
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

pub func hostWriteBytesResult(path: in String, bytes: in slice[Byte]): Result[Unit, IOError] {
  try {
    hostWriteAllBytes(path, bytes)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}

/// True when `path` is a symbolic link (or other reparse point) to a
/// directory: `DirectoryInfo.LinkTarget` is non-null only for links.
/// Recursive listings skip such links so a link back to an ancestor cannot
/// repeat the tree (#7246).
pub func hostIsDirSymlink(path: in String): Bool {
  if not hostDirectoryExists(path) {
    return false
  }
  val target = DirectoryInfo.new(path).LinkTarget ?? ""
  target.length > 0
}

extern type FileInfo = "System.IO.FileInfo"

extern type NetOs = "System.OperatingSystem"

/// Renames (moves) a file or directory within one file system.
pub func hostRenameResult(fromPath: in String, toPath: in String): Result[Unit, IOError] {
  try {
    if hostDirectoryExists(fromPath) {
      NetDirectory.Move(fromPath, toPath)
    } else {
      NetFile.Move(fromPath, toPath)
    }
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = fromPath, message = b.message))
  }
}

/// Gives `path` mode 0755 (a no-op on Windows beyond checking it exists).
/// `File.SetUnixFileMode` takes a `[Flags] UnixFileMode`, and no single
/// named member is 0755, so this runs the POSIX `chmod 755` utility instead.
pub func hostSetExecutableResult(path: in String): Result[Unit, IOError] {
  if not hostFileExists(path) {
    return Err(error = FileNotFound(path = path))
  }
  if NetOs.IsWindows() {
    return Ok(value = ())
  }
  val args: List[String] = newList()
  args.add("755")
  args.add(path)
  match hostRunInheritedResult("chmod", args) {
    case Ok(code) -> if code == 0 {
      Ok(value = ())
    } else {
      Err(error = IoError(path = path, message = "chmod 755 exited " + code.toString()))
    }
    case Err(e) -> Err(error = e)
  }
}

// The runtime's own `lstat(2)` shim (dotnet/runtime
// `src/native/libs/System.Native/pal_io.h`), present wherever .NET runs on
// Unix and linked statically into a NativeAOT executable. It fills a
// `FileStatus`, whose layout and `S_IF*` type bits are the runtime's own and
// so the same on every Unix, rather than the platform's `struct stat`.
@library("libSystem.Native")
extern func sysLStat(path: NativePtr[Byte], output: NativePtr[Byte]): Int = "SystemNative_LStat"

// The buffers go through `Marshal` rather than `Std.Ffi`, whose byte loads
// and stores are unverifiable IL; these calls keep the kernel verifiable.
@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.Marshal.ReadInt32")
func netReadInt32(ptr: in NativePtr[Byte], ofs: in Int): Int = ()

@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.Marshal.AllocHGlobal")
func netAllocHGlobal(size: in Int): NativePtr[Byte] = ()

@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.Marshal.FreeHGlobal")
func netFreeHGlobal(ptr: in NativePtr[Byte]): Unit = ()

@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.Marshal.StringToCoTaskMemUTF8")
func netStringToUtf8(s: in String): NativePtr[Byte] = ()

@unsafe_ffi
@externStatic
@externTarget("System.Runtime.InteropServices.Marshal.FreeCoTaskMem")
func netFreeCoTaskMem(ptr: in NativePtr[Byte]): Unit = ()

// Room for a `FileStatus` (under 160 bytes in every release so far).
val fileStatusSize: Int = 256

/// The file type bits (`mode & 0xF000`) of `path` itself, or -1 when it
/// cannot be examined (missing, or an inaccessible parent).
@unsafe_ffi
func lstatFileType(path: in String): Int {
  val cpath = netStringToUtf8(path)
  val status = netAllocHGlobal(fileStatusSize)
  // `Mode`, an int32 in host byte order, follows the int32 `Flags`.
  val mode = if sysLStat(cpath, status) == 0 { netReadInt32(status, 4) } else { -1 }
  netFreeHGlobal(status)
  netFreeCoTaskMem(cpath)
  if mode < 0 {
    -1
  } else {
    mode.and(0xF000)
  }
}

/// What `path` itself is, without following a link: 0 missing, 1 regular
/// file, 2 directory, 3 symbolic link, 4 other (the codes of
/// `lyric_path_kind_nofollow`). On Unix this asks `lstat` (#8578), since
/// .NET's `FileSystemInfo` reports a FIFO, socket or device node as a file.
/// A Windows file system holds only files, directories and reparse points.
@unsafe_ffi
pub func hostPathKindNoFollow(path: in String): Int {
  if NetOs.IsWindows() {
    val target = FileInfo.new(path).LinkTarget ?? ""
    if target.length > 0 {
      return 3
    }
    if hostDirectoryExists(path) {
      return 2
    }
    if hostFileExists(path) {
      return 1
    }
    return 0
  }
  val kind = lstatFileType(path)
  if kind < 0 {
    0
  } else if kind == 0x8000 {
    1
  } else if kind == 0x4000 {
    2
  } else if kind == 0xA000 {
    3
  } else {
    4
  }
}

pub func hostListFilesResult(dir: in String): Result[List[String], IOError] {
  try {
    val raw = hostEnumerateFiles(dir)
    val acc: List[String] = newListWithCapacity(raw.length)
    for f in raw {
      acc.add(f)
    }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = dir, message = b.message))
  }
}

/// Every entry directly inside `dir`, of any kind (files, directories, links,
/// including a link whose target is missing), as paths under `dir`.
pub func hostListEntriesResult(dir: in String): Result[List[String], IOError] {
  try {
    val raw = hostEnumerateFileSystemEntries(dir)
    val acc: List[String] = newListWithCapacity(raw.length)
    for e in raw {
      acc.add(e)
    }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = dir, message = b.message))
  }
}

pub func hostListDirsResult(dir: in String): Result[List[String], IOError] {
  try {
    val raw = hostEnumerateDirectories(dir)
    val acc: List[String] = newListWithCapacity(raw.length)
    for d in raw {
      acc.add(d)
    }
    Ok(value = acc)
  } catch Bug as b {
    Err(error = IoError(path = dir, message = b.message))
  }
}

// Not-found routes into IoError like every other failure (BCL
// Directory.Delete throws DirectoryNotFoundException; distinguishing
// it from permission-denied would need an exception-type-aware shim).
pub func hostDeleteDirRecursiveResult(path: in String): Result[Unit, IOError] {
  try {
    hostDeleteDirectoryRecursive(path, true)
    Ok(value = ())
  } catch Bug as b {
    Err(error = IoError(path = path, message = b.message))
  }
}
