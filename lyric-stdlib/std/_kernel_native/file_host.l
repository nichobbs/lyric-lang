//! std/_kernel_native/file_host.l — native-target file-system boundary.
//!
//! The `--target native` twin of `_kernel/file_host.l`, selected by the
//! native source loader by basename.  Implements the exception-free
//! Result seams (issue #4752) that `Std.File` delegates to, over the
//! audited lyric-rt helpers (`lyric_file_*` / `lyric_dir_*`) — POSIX
//! status codes instead of exceptions, so no try/catch is needed here.
//!
//! Scope: the text- and bytes-mode Result seams, existence probes,
//! create/delete (files and recursive directory deletion), and
//! directory enumeration (D-N-015: slices share the RC'd list repr, so
//! the byte and path collections ride the ordinary list kernels).
//!
//! `hostReadAllBytes` and `hostReadAllText` (D-progress-910 /
//! issue #6961, #4752's residual-seam audit) back
//! `Std.File.readBytesOrPanic`/`readTextOrPanic`, whose pure-layer
//! bodies have NO `try`/`catch` around them on any target — their
//! "panic on failure" contract is naturally satisfied here by panicking
//! directly (native has no exceptions to propagate in the first place,
//! D-N-003), reusing `hostReadBytesResult`/`hostReadTextResult`'s own
//! seams rather than a second extern call each.
//!
//! `stat`/`fileStatIsNewer` (issue #6961) now ship too: `FileTime` is
//! the native twin of the dotnet/JVM kernels' `extern type FileTime`
//! (`System.DateTime` / boxed `java.lang.Long`) — a plain record
//! holding epoch-nanoseconds, the same representation `Std.Time`'s
//! native `Instant` already uses (D-N-027), backed by a new
//! `lyric_file_mtime_epoch_nanos_ok` lyric-rt seam (`stat(2)`'s
//! `st_mtim`). `hostGetLastWriteTimeUtcResult` is the exception-free
//! Result seam `Std.File.stat`'s pure-layer body calls directly (no
//! `try`/`catch` — D-N-003 has no unwinding on this target), mirroring
//! `hostReadTextResult`'s own precedent.
@axiom("POSIX file-system calls via lyric-rt conform to their documented contracts")
package Std.FileHost

import Std.Core
import Std.Collections
import Std.Errors

/// Native twin of the dotnet/JVM kernels' `extern type FileTime`: a
/// plain record holding epoch-nanoseconds, the same representation
/// `Std.Time`'s native `Instant` uses (D-N-027) — not a re-export of
/// `Instant` itself, so `Std.FileHost` stays independent of
/// `Std.TimeHost` on this target the same way it does on the other two.
pub record FileTime {
  epochNanos: Long
}

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtFileExists(path: NativePtr[Byte]): Int = "lyric_file_exists"

extern func rtMtimeEpochNanosOk(path: NativePtr[Byte], outp: NativePtr[Long]): Int = "lyric_file_mtime_epoch_nanos_ok"

extern func rtDirExists(path: NativePtr[Byte]): Int = "lyric_dir_exists"

extern func rtReadAllOk(path: NativePtr[Byte], outp: NativePtr[String]): Int = "lyric_file_read_all_ok"

extern func rtWriteAll(path: NativePtr[Byte], data: String, append: Int): Int = "lyric_file_write_all"

extern func rtDelete(path: NativePtr[Byte]): Int = "lyric_file_delete"

extern func rtDirCreateAll(path: NativePtr[Byte]): Int = "lyric_dir_create_all"

// Return-plus-ok-flag kernels (a ref-container out-param would leak
// its initialiser; these always return a fresh owned list, empty on
// failure, and report success through the Int out-flag).
extern func rtReadBytes(path: NativePtr[Byte], okOut: NativePtr[Int]): List[Byte] = "lyric_file_read_bytes"

extern func rtDirList(path: NativePtr[Byte], okOut: NativePtr[Int]): List[String] = "lyric_dir_list2"

// Single-sweep name+kind listing (#4856): one opendir/readdir pass
// classifies every entry via `d_type` instead of a bare-name listing
// plus a per-entry stat() probe. Each returned string is a single
// LYRIC_DIRENT_* digit ('1' = directory, '2' = regular file, '0' =
// neither, see lyric_rt.h) followed by the bare entry name — a second
// List[Int] out-param would leak its Lyric-side `newList()`
// initialiser the moment the extern call overwrites the slot (the
// return-plus-ok-flag protocol above exists precisely to avoid that).
extern func rtDirListTyped(path: NativePtr[Byte], okOut: NativePtr[Int]): List[String] = "lyric_dir_list_typed"

extern func rtWriteBytes(path: NativePtr[Byte], data: List[Byte], append: Int): Int = "lyric_file_write_bytes"

// The same two lyric-rt seams typed as `slice[Byte]`, which shares the
// `LyricList` representation on this target (D-N-015), so no copy is made.
extern func rtReadByteSlice(path: NativePtr[Byte], okOut: NativePtr[Int]): slice[Byte] = "lyric_file_read_bytes"

extern func rtWriteByteSlice(path: NativePtr[Byte], data: slice[Byte], append: Int): Int = "lyric_file_write_bytes"

extern func rtDirRemove(path: NativePtr[Byte]): Int = "lyric_dir_remove"

// lstat-based: a symlink-to-directory is NOT a directory here, so the
// recursive delete unlinks the link instead of descending into its
// target (which may be outside the tree being removed).
extern func rtIsDirNoFollow(path: NativePtr[Byte]): Int = "lyric_path_is_dir_nofollow"

@unsafe_ffi
pub func hostFileExists(path: in String): Bool {
  val c = toC(path)
  val rc = rtFileExists(c)
  freeC(c)
  rc == 1
}

@unsafe_ffi
pub func hostDirectoryExists(path: in String): Bool {
  val c = toC(path)
  val rc = rtDirExists(c)
  freeC(c)
  rc == 1
}

// Issue #6961: `Std.File.stat`'s pure-layer body calls this directly
// with NO `try`/`catch` around it on any target — the exception-free
// Result seam every kernel twin now implements. `stat()` already probes
// hostFileExists/hostDirectoryExists before calling this, so the only
// way `lyric_file_mtime_epoch_nanos_ok` fails here is a TOCTOU race
// (deleted between the probe and this call) or the nanosecond-range
// overflow guard — either way it is reported as IoError, matching the
// dotnet/JVM twins' catch-all classification once their own
// not-found case is ruled out by the same pre-probe.
@unsafe_ffi
pub func hostGetLastWriteTimeUtcResult(path: in String): Result[FileTime, IOError] {
  var nanos: Long = 0i64
  val c = toC(path)
  val rc = rtMtimeEpochNanosOk(c, nativeAddrOf(nanos))
  freeC(c)
  if rc == 0 {
    Ok(value = FileTime(epochNanos = nanos))
  } else {
    Err(error = IoError(path = path, message = "the file's modification time could not be read"))
  }
}

pub func hostDateTimeGreaterThan(a: in FileTime, b: in FileTime): Bool {
  a.epochNanos > b.epochNanos
}

@unsafe_ffi
pub func hostReadTextResult(path: in String): Result[String, IOError] {
  var text: String = ""
  val c = toC(path)
  val rc = rtReadAllOk(c, nativeAddrOf(text))
  if rc == 0 {
    freeC(c)
    return Ok(value = text)
  }
  // Classify only after the read has already failed (no TOCTOU on the
  // success path): a path that doesn't stat as a regular file is
  // FileNotFound; everything else (permissions, device errors) is
  // IoError.  The failure-path probe is inherently racy (#4791): a
  // file created between the failed read and the probe misreports as
  // IoError — the failure itself is still reported either way.
  val probe = rtFileExists(c)
  freeC(c)
  if probe == 0 {
    Err(error = FileNotFound(path = path))
  } else {
    Err(error = IoError(path = path, message = "the file could not be read"))
  }
}

// Issue #6961 (D-N-003 follow-up): `Std.File.readTextOrPanic` calls this
// directly with NO `try`/`catch` around it on any target -- its "panic on
// failure" contract is satisfied on native by panicking IN THE KERNEL
// itself rather than throwing an exception for the pure layer to let
// propagate uncaught, since native has no exceptions to propagate in the
// first place (D-N-003).  Mirrors `hostReadAllBytes` below exactly, reusing
// `hostReadTextResult`'s own seam rather than a second `rtReadAllOk` call.
@unsafe_ffi
pub func hostReadAllText(path: in String): String {
  match hostReadTextResult(path) {
    case Ok(text) -> text
    case Err(_) -> panic("Std.File.readTextOrPanic: the file could not be read: " + path)
  }
}

@unsafe_ffi
pub func hostWriteTextResult(path: in String, text: in String): Result[Unit, IOError] {
  val c = toC(path)
  val rc = rtWriteAll(c, text, 0)
  freeC(c)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the file could not be written"))
  }
}

@unsafe_ffi
pub func hostCreateDirResult(path: in String): Result[Unit, IOError] {
  // `mkdir -p` in the runtime: one mkdir(2) when the parent exists, and
  // parents created only on ENOENT, keeping the managed twin's
  // create-with-parents semantics (#7284).
  val c = toC(path)
  val rc = rtDirCreateAll(c)
  freeC(c)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the directory could not be created"))
  }
}

@unsafe_ffi
pub func hostDeleteFileResult(path: in String): Result[Unit, IOError] {
  val c = toC(path)
  val rc = rtDelete(c)
  if rc == 0 {
    freeC(c)
    return Ok(value = ())
  }
  // Idempotent on not-found, matching the managed twin (BCL
  // File.Delete succeeds silently when the path doesn't exist).  A
  // directory path is NOT the not-found case (rtFileExists is 0 for
  // directories too): the managed twin reports it as an error, so the
  // dir probe keeps parity (#4784).
  val probeFile = rtFileExists(c)
  val probeDir = rtDirExists(c)
  freeC(c)
  if probeFile == 0 and probeDir == 0 {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the file could not be deleted"))
  }
}

// Bytes-mode and enumeration Result seams (issue #4752, D-N-015
// slice): every failure reports IoError, matching the managed twin.
@unsafe_ffi
pub func hostReadBytesResult(path: in String): Result[List[Byte], IOError] {
  var ok: Int = 0
  val c = toC(path)
  val bytes = rtReadBytes(c, nativeAddrOf(ok))
  freeC(c)
  if ok == 1 {
    Ok(value = bytes)
  } else {
    Err(error = IoError(path = path, message = "the file could not be read"))
  }
}

// #4752 residual-seam audit (D-progress-910): `Std.File.readBytesOrPanic`
// calls this directly with NO `try`/`catch` around it on any target
// (unlike `readTextOrPanic`, which does) — its "panic on failure"
// contract is naturally satisfied on native by panicking IN THE KERNEL
// itself rather than throwing an exception for the pure layer to let
// propagate uncaught, since native has no exceptions to propagate in
// the first place (D-N-003). `slice[Byte]`/`List[Byte]` share the same
// representation on this target (D-N-015), so this reuses
// `hostReadBytesResult`'s own seam rather than a second `rtReadBytes`
// call.
@unsafe_ffi
pub func hostReadAllBytes(path: in String): slice[Byte] {
  match hostReadBytesResult(path) {
    case Ok(bytes) -> bytes.toArray()
    case Err(_) -> panic("Std.File.readBytesOrPanic: the file could not be read: " + path)
  }
}

@unsafe_ffi
pub func hostWriteBytesResult(path: in String, bytes: in List[Byte]): Result[Unit, IOError] {
  val c = toC(path)
  val rc = rtWriteBytes(c, bytes, 0)
  freeC(c)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the file could not be written"))
  }
}

@unsafe_ffi
pub func hostReadByteSliceResult(path: in String): Result[slice[Byte], IOError] {
  var ok: Int = 0
  val c = toC(path)
  val bytes = rtReadByteSlice(c, nativeAddrOf(ok))
  freeC(c)
  if ok == 1 {
    Ok(value = bytes)
  } else {
    Err(error = IoError(path = path, message = "the file could not be read"))
  }
}

@unsafe_ffi
pub func hostWriteByteSliceResult(path: in String, bytes: in slice[Byte]): Result[Unit, IOError] {
  val c = toC(path)
  val rc = rtWriteByteSlice(c, bytes, 0)
  freeC(c)
  if rc == 0 {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the file could not be written"))
  }
}

// Bare entry NAMES straight from lyric_dir_list2 (files and dirs
// mixed); used ONLY by the recursive delete walker below, which must
// classify each child with an lstat probe (isRealDirNative) rather
// than the following-stat semantics listEntriesByKind uses, so it
// cannot share that single-sweep typed listing.
@unsafe_ffi
func listEntryNamesNative(dir: in String): Result[List[String], IOError] {
  var ok: Int = 0
  val c = toC(dir)
  val names = rtDirList(c, nativeAddrOf(ok))
  freeC(c)
  if ok != 1 {
    return Err(error = IoError(path = dir, message = "the directory could not be listed"))
  }
  Ok(value = names)
}

// Single-sweep name+kind listing (#4856): one opendir/readdir pass
// classifies every entry via `d_type`, so filtering by `wantKindDigit`
// here costs no extra syscalls beyond the earlier bare-name listing
// plus a per-entry hostFileExists/hostDirectoryExists stat() probe.
// Each `rtDirListTyped` entry is a single LYRIC_DIRENT_* ASCII digit
// ('1' = directory, '2' = regular file) followed by the bare name.
// `wantKindDigit` is passed as a literal by the two callers below
// rather than a module-level constant, which the native backend does
// not yet support referencing from a function body.
@unsafe_ffi
func listEntriesByKind(dir: in String, wantKindDigit: String): Result[List[String], IOError] {
  var ok: Int = 0
  val c = toC(dir)
  val entries = rtDirListTyped(c, nativeAddrOf(ok))
  freeC(c)
  if ok != 1 {
    return Err(error = IoError(path = dir, message = "the directory could not be listed"))
  }
  val acc: List[String] = newList()
  for e in entries {
    if e.substring(0, 1) == wantKindDigit {
      acc.add(dir + "/" + e.substring(1, e.length - 1))
    }
  }
  Ok(value = acc)
}

pub func hostListFilesResult(dir: in String): Result[List[String], IOError] {
  listEntriesByKind(dir, "2")
}

pub func hostListDirsResult(dir: in String): Result[List[String], IOError] {
  listEntriesByKind(dir, "1")
}

@unsafe_ffi
func removeDirOne(path: in String): Bool {
  val c = toC(path)
  val rc = rtDirRemove(c)
  freeC(c)
  rc == 0
}

// True only for a real directory, not a symlink pointing at one.
@unsafe_ffi
func isRealDirNative(path: in String): Bool {
  val c = toC(path)
  val rc = rtIsDirNoFollow(c)
  freeC(c)
  rc == 1
}

// Depth-first single-pass delete: list each directory ONCE, probe each
// entry once (a REAL subdirectory recurses, anything else — a file or
// a symlink, even one pointing at a directory — is unlinked), then
// rmdir(2) the emptied directory.  The nofollow probe (`isRealDirNative`,
// lstat) is essential: descending through a directory symlink would
// delete files OUTSIDE the tree being removed, and `lyric_file_delete`
// is `unlink(2)`, which removes the link itself.  This matches
// `rm -rf` / BCL `Directory.Delete(recursive: true)` on modern .NET.
// Going through the two split list seams would read the directory twice
// per level and stat every child twice; the delete walk cannot afford
// that on a deep tree.  A missing path fails at the first listing
// (parity with the managed twin, which reports DirectoryNotFoundException
// as Err(IoError)).  No `@unsafe_ffi`: this seam touches no FFI primitive
// directly — every call is to another host function (`listEntryNamesNative`,
// `hostDirectoryExists`, `hostDeleteFileResult`, `removeDirOne`) that
// already crossed the boundary, matching `hostCreateDirResult` /
// `hostListFilesResult` / `hostListDirsResult`.
pub func hostDeleteDirRecursiveResult(path: in String): Result[Unit, IOError] {
  match listEntryNamesNative(path) {
    case Ok(names) -> {
      for n in names {
        val p = path + "/" + n
        if isRealDirNative(p) {
          match hostDeleteDirRecursiveResult(p) {
            case Ok(_) -> {
            }
            case Err(e) -> {
              return Err(error = e)
            }
          }
        } else {
          match hostDeleteFileResult(p) {
            case Ok(_) -> {
            }
            case Err(e) -> {
              return Err(error = e)
            }
          }
        }
      }
    }
    case Err(e) -> {
      return Err(error = e)
    }
  }
  if removeDirOne(path) {
    Ok(value = ())
  } else {
    Err(error = IoError(path = path, message = "the directory could not be deleted"))
  }
}
