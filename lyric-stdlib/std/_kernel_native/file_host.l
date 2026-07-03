//! std/_kernel_native/file_host.l — native-target file-system boundary.
//!
//! The `--target native` twin of `_kernel/file_host.l`, selected by the
//! native source loader by basename.  Implements the exception-free
//! Result seams (issue #4752) that `Std.File` delegates to, over the
//! audited lyric-rt helpers (`lyric_file_*` / `lyric_dir_*`) — POSIX
//! status codes instead of exceptions, so no try/catch is needed here.
//!
//! Scope: the text-mode Result seams plus the existence probes.  The
//! bytes-mode surface (`hostReadAllBytes` / `hostWriteAllBytes`), file
//! stat, and directory enumeration need `slice[Byte]` and DateTime
//! lowering the native backend doesn't have yet (issue #4752 tracks
//! them); the `Std.File` functions built on them stay
//! compile-time-unreachable on native until then.
@axiom("POSIX file-system calls via lyric-rt conform to their documented contracts")
package Std.FileHost

import Std.Core
import Std.Errors

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func rtFileExists(path: NativePtr[Byte]): Int = "lyric_file_exists"

extern func rtDirExists(path: NativePtr[Byte]): Int = "lyric_dir_exists"

extern func rtReadAllOk(path: NativePtr[Byte], outp: NativePtr[String]): Int = "lyric_file_read_all_ok"

extern func rtWriteAll(path: NativePtr[Byte], data: String, append: Int): Int = "lyric_file_write_all"

extern func rtDelete(path: NativePtr[Byte]): Int = "lyric_file_delete"

extern func rtDirCreate(path: NativePtr[Byte]): Int = "lyric_dir_create"

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
