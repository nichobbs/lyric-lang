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
//! Still unavailable natively: file `stat` (needs an opaque timestamp
//! twin) and the panicking `readTextOrPanic` / `readBytesOrPanic`
//! variants (pure-layer try/catch) — issue #4752 tracks both.
@axiom("POSIX file-system calls via lyric-rt conform to their documented contracts")
package Std.FileHost

import Std.Core
import Std.Collections
import Std.Errors

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtFileExists(path: NativePtr[Byte]): Int = "lyric_file_exists"

extern func rtDirExists(path: NativePtr[Byte]): Int = "lyric_dir_exists"

extern func rtReadAllOk(path: NativePtr[Byte], outp: NativePtr[String]): Int = "lyric_file_read_all_ok"

extern func rtWriteAll(path: NativePtr[Byte], data: String, append: Int): Int = "lyric_file_write_all"

extern func rtDelete(path: NativePtr[Byte]): Int = "lyric_file_delete"

extern func rtDirCreate(path: NativePtr[Byte]): Int = "lyric_dir_create"

// Return-plus-ok-flag kernels (a ref-container out-param would leak
// its initialiser; these always return a fresh owned list, empty on
// failure, and report success through the Int out-flag).
extern func rtReadBytes(path: NativePtr[Byte], okOut: NativePtr[Int]): List[Byte] = "lyric_file_read_bytes"

extern func rtDirList(path: NativePtr[Byte], okOut: NativePtr[Int]): List[String] = "lyric_dir_list2"

extern func rtWriteBytes(path: NativePtr[Byte], data: List[Byte], append: Int): Int = "lyric_file_write_bytes"

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

// Single-level create; mkdir(2)'s EEXIST counts as success for a
// create-if-missing seam.
@unsafe_ffi
func createDirOne(path: in String): Bool {
  val c = toC(path)
  val rc = rtDirCreate(c)
  if rc == 0 {
    freeC(c)
    return true
  }
  val probe = rtDirExists(c)
  freeC(c)
  probe == 1
}

pub func hostCreateDirResult(path: in String): Result[Unit, IOError] {
  // lyric_dir_create is single-level mkdir(2); create each parent
  // prefix first so this seam keeps the managed twin's
  // create-with-parents semantics.  Index 0 is skipped so an absolute
  // path never asks for mkdir("").
  var i = 1
  val n = path.length
  while i < n {
    if path.substring(i, 1) == "/" {
      if not createDirOne(path.substring(0, i)) {
        return Err(error = IoError(path = path, message = "the directory could not be created"))
      }
    }
    i = i + 1
  }
  if createDirOne(path) {
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

// Bare entry NAMES straight from lyric_dir_list2 (files and dirs
// mixed); the managed twin yields absolute paths split by kind, so
// each public seam below re-joins the names onto `dir` and filters by
// an existence probe of its kind.
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

pub func hostListFilesResult(dir: in String): Result[List[String], IOError] {
  match listEntryNamesNative(dir) {
    case Ok(names) -> {
      val acc: List[String] = newList()
      for n in names {
        val p = dir + "/" + n
        if hostFileExists(p) {
          acc.add(p)
        }
      }
      Ok(value = acc)
    }
    case Err(e) -> Err(error = e)
  }
}

pub func hostListDirsResult(dir: in String): Result[List[String], IOError] {
  match listEntryNamesNative(dir) {
    case Ok(names) -> {
      val acc: List[String] = newList()
      for n in names {
        val p = dir + "/" + n
        if hostDirectoryExists(p) {
          acc.add(p)
        }
      }
      Ok(value = acc)
    }
    case Err(e) -> Err(error = e)
  }
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
