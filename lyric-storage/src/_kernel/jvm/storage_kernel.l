//! Storage.Kernel.Jvm — JDK extern boundary for the local-filesystem
//! storage backend (#1444).
//!
//! Mirrors `Storage.Kernel.Net` function-for-function so the Lyric-side
//! data plane in `storage.l` compiles unchanged on `--target jvm`: the
//! inactive kernel is erased by the `@cfg` feature gate (`dotnet` /
//! `jvm`), so the unqualified `host*` calls resolve to whichever kernel
//! survives.  Pure Lyric over the JVM auto-FFI — the previous version
//! routed every function through phantom `lyric.storage.*` shim classes
//! that never existed at runtime (the same elimination as the stdlib
//! `_kernel_jvm/file_host.l` / `console_host.l` rewrites, D-progress-555)
//! and declared AWS/Azure SDK surfaces with no `[maven]` coordinates.
//! S3 and Azure Blob remain Lyric-side stubs in `storage.l` on both
//! targets (see the .NET kernel header).
//!
//! JDK surface bound here (all in `java.base` — no Maven dependencies):
//!
//!   * `java.util.Base64` encode/decode for the `dataBase64` wire payload.
//!   * `java.security.MessageDigest.getInstance("MD5")` for the ETag of
//!     single-part uploads (an integrity tag, not authentication — see
//!     the .NET kernel's note).
//!   * `java.util.HexFormat.of().withUpperCase()` for hex encoding
//!     (uppercase to match `System.Convert.ToHexString`; `storage.l`
//!     lowercases the result on both targets).
//!   * `java.io.File.getCanonicalPath()` for the path-traversal
//!     defence-in-depth check.  Canonicalisation resolves symlinks where
//!     `System.IO.Path.GetFullPath` does not — strictly stronger for the
//!     containment check `storage.l` performs.
//!   * `java.io.FileInputStream` / `FileOutputStream` for raw
//!     `slice[Byte]` round-tripping; UTF-8 text I/O via whole-file bytes
//!     + `String(byte[], "UTF-8")` / the `stringToUtf8Bytes` intrinsic.
//!   * `java.io.File` existence probes, deletion, `mkdirs()`, and
//!     `listFiles()` enumeration filtered by kind (absolute paths, like
//!     the BCL's `Directory.GetFiles` for the absolute inputs the data
//!     plane uses).
//!
//! Failures follow the JDK contracts: read/write on a missing or
//! unreadable path throws `IOException` (surfaced to Lyric as a
//! catchable `Bug`), which `storage.l` wraps into `StorageError` — the
//! same division of labour as the .NET kernel.
//!
//! Internal: only `Storage` (lyric-storage/src/storage.l) should import
//! this; see `docs/14-native-stdlib-plan.md` for the kernel boundary
//! contract.
@axiom("java.util.Base64 / java.security.MessageDigest / java.util.HexFormat / java.io.File and its streams conform to their documented JVM contracts")
@cfg(feature = "jvm")
package Storage.Kernel.Jvm

import Std.Core

// ── JDK extern types ──────────────────────────────────────────────────────────
extern type JB64 = "java.util.Base64"

extern type JMessageDigest = "java.security.MessageDigest"

extern type JHexFormat = "java.util.HexFormat"

extern type JFile = "java.io.File"

extern type JFIS = "java.io.FileInputStream"

extern type JFOS = "java.io.FileOutputStream"

extern type JString = "java.lang.String"

// ── Base64 — Lyric `String <-> slice[Byte]` wire-format encoding ─────────────
/// Decode a base64-encoded string into raw bytes.  Throws
/// `IllegalArgumentException` for malformed base64 input; callers in
/// `storage.l` wrap in `try { … } catch Bug as b { … }` and surface
/// failures as `StorageError(code = "INVALID_BASE64")`.
pub func hostFromBase64(data: in String): slice[Byte] {
  val dec = JB64.getDecoder()
  dec.decode(data)
}

/// Encode raw bytes as base64.  Never throws under normal operation.
pub func hostToBase64(bytes: in slice[Byte]): String {
  val enc = JB64.getEncoder()
  enc.encodeToString(bytes)
}

// ── MD5 — ETag computation for single-part uploads ───────────────────────────
pub func hostMd5(bytes: in slice[Byte]): slice[Byte] {
  val md = JMessageDigest.getInstance("MD5")
  md.digest(bytes)
}

/// Hex-encode a byte slice (uppercase, matching the .NET kernel's
/// `Convert.ToHexString`).  `storage.l` lowercases the result so the
/// on-disk ETag convention is lowercase-hex on both targets.
pub func hostBytesToHexUpper(bytes: in slice[Byte]): String {
  val hf = JHexFormat.of()
  val up = hf.withUpperCase()
  up.formatHex(bytes)
}

// ── Path canonicalisation — defence-in-depth path-traversal check ────────────
/// Return the canonical path for `path`.  Normalises `.` / `..` segments
/// (and resolves symlinks — stronger than the BCL's `GetFullPath`) so the
/// storage backend can detect keys that smuggled `..` past the substring
/// check.  `Storage.isSafeKey` is the primary check; this is the second
/// layer.
pub func hostPathGetFullPath(path: in String): String {
  val f = JFile.new(path)
  f.getCanonicalPath()
}

// ── Raw file I/O — `slice[Byte]` round-tripping ───────────────────────────────
pub func hostReadAllBytes(path: in String): slice[Byte] {
  val fis = JFIS.new(path)
  // Close on the failure path too (#4780): keeps the stream from leaking
  // until GC when readAllBytes throws mid-read.  A constructor failure
  // (missing file) needs no close and propagates unchanged.
  try {
    val all = fis.readAllBytes()
    fis.close()
    all
  } catch Bug as b {
    fis.close()
    panic(b.message)
  }
}

pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit {
  val fos = JFOS.new(path)
  // Close on the failure path too (#4780) — see hostReadAllBytes.
  try {
    fos.write(bytes)
    fos.close()
  } catch Bug as b {
    fos.close()
    panic(b.message)
  }
}

pub func hostWriteAllText(path: in String, contents: in String): Unit {
  hostWriteAllBytes(path, stringToUtf8Bytes(contents))
}

pub func hostReadAllText(path: in String): String {
  val bytes = hostReadAllBytes(path)
  JString.new(bytes, "UTF-8")
}

pub func hostFileExists(path: in String): Bool {
  val f = JFile.new(path)
  f.isFile()
}

pub func hostDeleteFile(path: in String): Unit {
  val f = JFile.new(path)
  f.delete()
}

// ── Directory operations ──────────────────────────────────────────────────────
pub func hostDirectoryExists(path: in String): Bool {
  val f = JFile.new(path)
  f.isDirectory()
}

/// Creates `path` and any missing parents.  `mkdirs()` returns false when
/// the directory already exists; creation is idempotent and the data
/// plane discards the result on both targets (the .NET twin returns the
/// BCL's `DirectoryInfo`, likewise discarded).
pub func hostCreateDirectory(path: in String): Unit {
  val f = JFile.new(path)
  f.mkdirs()
}

pub func hostGetFiles(path: in String): slice[String] {
  listChildren(path, 1)
}

pub func hostGetDirectories(path: in String): slice[String] {
  listChildren(path, 2)
}

// kind: 1 = files only, 2 = directories only.
func listChildren(path: in String, kind: in Int): slice[String] {
  val d = JFile.new(path)
  val out2: List[String] = newList()
  // `listFiles()` returns NULL for a non-directory or an I/O error (#4781)
  // — treat both as "no children" rather than NPE.
  val children = d.listFiles()
  match children {
    case null -> {
      return out2.toArray()
    }
    case _ -> ()
  }
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
