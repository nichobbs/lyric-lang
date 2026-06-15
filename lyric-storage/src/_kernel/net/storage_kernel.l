//! Storage.Kernel.Net — direct BCL extern boundary for the local-filesystem
//! storage backend.
//!
//! `Lyric.Storage.LocalHost` (the F# host shim previously at
//! `bootstrap/src/Lyric.Storage.Host/StorageHost.fs`) has been removed.  This
//! kernel binds the minimum BCL surface the Lyric-side data plane in
//! `storage.l` needs:
//!
//!   * Base64 encode/decode for the `dataBase64` wire payload
//!     (`System.Convert.ToBase64String` / `FromBase64String`).
//!   * MD5 hashing for the ETag of single-part uploads
//!     (`System.Security.Cryptography.MD5.HashData`).
//!   * Canonical-path resolution for path-traversal defence-in-depth
//!     (`System.IO.Path.GetFullPath`).
//!   * Raw `slice[Byte]` round-tripping for `File.ReadAllBytes` /
//!     `File.WriteAllBytes` (the `Std.File` wrappers shuttle through
//!     `List[Byte]`, which forces an O(n) per-byte copy in both
//!     directions — unacceptable for object storage payloads).
//!   * `File.Exists` / `File.Delete` for sidecar handling without the
//!     `Std.File` `IOError` wrapping (storage maps to `StorageError`).
//!   * `Directory.GetFiles` / `Directory.GetDirectories` for recursive
//!     `list` walks.
//!
//! S3 (AWSSDK.S3) and Azure Blob (Azure.Storage.Blobs) backends are
//! declared as Lyric stubs in `storage.l` that return "not yet
//! implemented" errors and are tracked as follow-up tickets.  Native
//! `extern type` bindings against the NuGet SDKs are a multi-day rewrite
//! of substantial surface area (S3: 30+ request/response types; Azure
//! Blob: similar) and have no `@cfg(feature=…)` users yet.
//!
//! Internal: only `Storage` (lyric-storage/src/storage.l) should import
//! this; see `docs/14-native-stdlib-plan.md` for the kernel boundary
//! contract.
@axiom("System.Convert / System.Security.Cryptography.MD5 / System.IO.Path / System.IO.File / System.IO.Directory conform to documented .NET semantics")
package Storage.Kernel.Net

// =====================================================================
// Base64 — Lyric `String <-> slice[Byte]` wire-format encoding.
// =====================================================================
/// Decode a base64-encoded string into raw bytes.  Throws `FormatException`
/// for malformed base64 input; callers in `storage.l` wrap in
/// `try { … } catch Bug as b { … }` and surface failures as
/// `StorageError(code = "INVALID_BASE64")`.
@externTarget("System.Convert.FromBase64String")
@externStatic
pub func hostFromBase64(data: in String): slice[Byte] = ()

/// Encode raw bytes as base64.  Never throws under normal operation.
@externTarget("System.Convert.ToBase64String")
@externStatic
pub func hostToBase64(bytes: in slice[Byte]): String = ()

// =====================================================================
// MD5 — ETag computation for single-part uploads (matches S3 single-part
// ETag scheme; multi-part uploads produce a different ETag shape that
// the local-fs backend does not currently emulate).
//
// MD5 is *not* cryptographically strong; it is used here strictly as an
// integrity tag, not for authentication or signing.
// =====================================================================
@externTarget("System.Security.Cryptography.MD5.HashData")
@externStatic
pub func hostMd5(bytes: in slice[Byte]): slice[Byte] = ()

/// Hex-encode a byte slice (uppercase).  `storage.l` lowercases the
/// result so the on-disk ETag convention is lowercase-hex.
@externTarget("System.Convert.ToHexString")
@externStatic
pub func hostBytesToHexUpper(bytes: in slice[Byte]): String = ()

// =====================================================================
// Path canonicalisation — defence-in-depth path-traversal check.
// =====================================================================
/// Return the canonical full path for `path`.  Normalises `.` / `..`
/// segments and trailing separators so the storage backend can detect
/// keys that smuggled `..` past the substring check (e.g. `a/..`).
/// `Storage.isSafeKey` is the primary check; this is the second layer.
@externTarget("System.IO.Path.GetFullPath")
@externStatic
pub func hostPathGetFullPath(path: in String): String = ()

// =====================================================================
// Raw file I/O — `slice[Byte]` round-tripping without the `Std.File`
// `List[Byte]` shuttle.
//
// These throw on host failure; `storage.l` wraps in `try { … } catch
// Bug as b { … }` and surfaces failures as `StorageError`.
// =====================================================================
@externTarget("System.IO.File.ReadAllBytes")
@externStatic
pub func hostReadAllBytes(path: in String): slice[Byte] = ()

@externTarget("System.IO.File.WriteAllBytes")
@externStatic
pub func hostWriteAllBytes(path: in String, bytes: in slice[Byte]): Unit = ()

@externTarget("System.IO.File.WriteAllText")
@externStatic
pub func hostWriteAllText(path: in String, contents: in String): Unit = ()

@externTarget("System.IO.File.ReadAllText")
@externStatic
pub func hostReadAllText(path: in String): String = ()

@externTarget("System.IO.File.Exists")
@externStatic
pub func hostFileExists(path: in String): Bool = ()

@externTarget("System.IO.File.Delete")
@externStatic
pub func hostDeleteFile(path: in String): Unit = ()

// =====================================================================
// Directory operations — `CreateDirectory` is idempotent (no error if
// the directory already exists); the enumerators return `slice[String]`
// of absolute paths.
// =====================================================================
@externTarget("System.IO.Directory.Exists")
@externStatic
pub func hostDirectoryExists(path: in String): Bool = ()

extern type DirectoryInfo = "System.IO.DirectoryInfo"

@externTarget("System.IO.Directory.CreateDirectory")
@externStatic
pub func hostCreateDirectory(path: in String): DirectoryInfo = ()

@externTarget("System.IO.Directory.GetFiles")
@externStatic
pub func hostGetFiles(path: in String): slice[String] = ()

@externTarget("System.IO.Directory.GetDirectories")
@externStatic
pub func hostGetDirectories(path: in String): slice[String] = ()

// Audit logging hook moved out of the kernel to `Storage.auditLog`
// (#1410): kernel files are the audited BCL boundary and must contain
// only `@externTarget` / `extern type` declarations.  The no-op stub
// is pure-Lyric, so it lives in `storage.l`.
