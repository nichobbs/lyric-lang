//! Storage.Port, managed targets — the filesystem and encoding operations the
//! local-filesystem backend needs, as `Result`s, on `dotnet` and the JVM.
//!
//! `Storage.Kernel.Net` and `Storage.Kernel.Jvm` bind host functions that
//! throw. This file is the one place those exceptions are caught: each
//! `port*` function runs a kernel call and returns the failure as data, so
//! `storage.l` has no `try` and compiles for every target.
//! `storage_port_native.l` gives the same functions for `--target native`,
//! where nothing throws (and nothing could be caught).
//!
//! The `Err` text is the host's message; `storage.l` adds the operation and
//! the `StorageError` code.
//!
//! Internal: only `Storage` should import this.
@cfg(not(target = "native"))
@io
package Storage.Port

import Std.Core
import Std.String as Str
import Storage.Kernel.Net
import Storage.Kernel.Jvm

pub func portDecodeBase64(data: in String): Result[slice[Byte], String] {
  return try {
    Ok(hostFromBase64(data))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func portEncodeBase64(bytes: in slice[Byte]): String {
  hostToBase64(bytes)
}

/// The lowercase-hex MD5 of `bytes`: the single-part S3 ETag scheme. An
/// integrity tag, not a signature.
pub func portEtag(bytes: in slice[Byte]): String {
  Str.toLower(hostBytesToHexUpper(hostMd5(bytes)))
}

/// The absolute path of `path` with `.` and `..` segments resolved.
pub func portFullPath(path: in String): Result[String, String] {
  return try {
    Ok(hostPathGetFullPath(path))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func portWriteText(path: in String, contents: in String): Result[Unit, String] {
  return try {
    hostWriteAllText(path, contents)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

pub func portReadText(path: in String): Result[String, String] {
  return try {
    Ok(hostReadAllText(path))
  } catch Bug as b {
    Err(b.message)
  }
}

pub func portFileExists(path: in String): Bool {
  hostFileExists(path)
}

pub func portDeleteFile(path: in String): Result[Unit, String] {
  return try {
    hostDeleteFile(path)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

pub func portDirectoryExists(path: in String): Bool {
  hostDirectoryExists(path)
}

/// Create `path` and any missing parents. An existing directory is not an
/// error.
pub func portCreateDirectory(path: in String): Result[Unit, String] {
  return try {
    hostCreateDirectory(path)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

/// The files directly in `dir`, as paths that start with `dir`.
pub func portFiles(dir: in String): Result[slice[String], String] {
  return try {
    Ok(hostGetFiles(dir))
  } catch Bug as b {
    Err(b.message)
  }
}

/// The directories directly in `dir`, as paths that start with `dir`.
pub func portDirectories(dir: in String): Result[slice[String], String] {
  return try {
    Ok(hostGetDirectories(dir))
  } catch Bug as b {
    Err(b.message)
  }
}
