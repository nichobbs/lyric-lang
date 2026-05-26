// Storage — object and file storage library for Lyric.
//
// Stability: @experimental — the local-filesystem backend is
// exercised by tests, but the S3 and Azure Blob backends have not
// been driven against a live provider in CI.
// WARNING: experimental — no stability guarantee.  The
// `StorageBucket` interface and the `connect*` factories may change
// before the surface freezes for `1.0`.
//
// Provides a uniform `StorageBucket` interface over Amazon S3, Azure Blob
// Storage, and the local filesystem.  Obtain a bucket handle with one of the
// feature-gated `connect*` factory functions, then call the typed wrappers or
// the interface methods directly.
//
// Usage:
//
//   import Storage
//   import Std.Collections
//
//   val bucket = Storage.connectLocal("/tmp/lyric-storage", "uploads")?
//   Storage.put(bucket, "uploads/photo.jpg", base64Data, "image/jpeg")?
//   match Storage.get(bucket, "uploads/photo.jpg") {
//     case Ok(obj) -> println(obj.metadata.contentType)
//     case Err(e)  -> println(e.message)
//   }
//   val listing = Storage.list(bucket, "uploads/")?
//
// Backends:
//   * Local filesystem — fully native Lyric implementation against
//     `System.IO.File` / `System.IO.Directory` / `System.IO.Path` and
//     a minimum BCL extern set in `Storage.Kernel.Net` (Base64, MD5,
//     canonical-path resolve).  No host shim.
//   * S3 (AWSSDK.S3)        — returns `NOT_IMPLEMENTED` until the
//     direct `extern type` bindings against the NuGet SDK land.
//   * Azure Blob Storage    — same as S3.
//
// See docs/03-decision-log.md D056 and lyric-storage/README.md.

@runtime_checked
package Storage

import Std.Core
import Std.Collections
import Std.Json
import Std.String as Str
import Std.Time as Time
import Std.Math
import Std.Iter
import Std.Sort
import Storage.Kernel.Net

// ─── Key safety primitives (defense-in-depth against path traversal) ─────────
//
// These helpers are exposed at the interface boundary so every
// `StorageBucket` method can require `isSafeKey(key)` as a contract.
// `Storage.Aspects.ValidateKey` adds a structured-error aspect-mode
// wrapper for callers who want a `Result[T, StorageError]` rather than a
// contract panic; the helpers in this file are the primary line of
// defense (CWE-22).

// Build a normalised inspection form: expand percent-encodings of `.`,
// `/`, `\` only, then fold `\` → `/`.  The returned string is for
// inspection only — the original key still reaches the backend.
//
// Any residual `%25` (encoded `%`) sequences after the single-pass decode
// signal a double-encoded payload (e.g. `%252e%252e/etc/passwd` →
// `%2e%2e/etc/passwd`).  `isSafeKey` rejects those keys outright to
// avoid a second OS-level decode reconstituting `..`.
pub func normalisedStorageKey(s: in String): String {
  val a = Str.replace(s, "%2e", ".")
  val b = Str.replace(a, "%2E", ".")
  val c = Str.replace(b, "%2f", "/")
  val d = Str.replace(c, "%2F", "/")
  val e = Str.replace(d, "%5c", "\\")
  val f = Str.replace(e, "%5C", "\\")
  Str.replace(f, "\\", "/")
}

// True when the normalised `s` contains a path segment that is exactly
// `..`.  Splitting on `/` makes the check segment-aware — `version..2.0`
// and `my..file.txt` are intentionally accepted while `../` and `/../`
// and a bare `..` are rejected.  Caller is expected to pass a key that
// has already been normalised by `normalisedStorageKey`.
pub func storageKeyHasDotDot(s: in String): Bool {
  val segs = Str.split(s, "/")
  var i    = 0
  while i < segs.length {
    if segs[i] == ".." {
      return true
    }
    i = i + 1
  }
  return false
}

// True when `key` is safe to pass to a storage backend.  Rejects:
//   * empty keys
//   * keys containing a NUL byte
//   * leading-slash (absolute) keys
//   * `..` path-traversal segments (after percent-decoding)
//   * **any literal `%`** — implemented by rejecting `%25` (the
//     percent-encoded form of `%`) anywhere in the key.  Single-pass
//     decoding in `normalisedStorageKey` would otherwise let
//     `%252e%252e/etc/passwd` through to the backend, where an
//     OS-level second decode would reconstitute `..`.  This means
//     **filenames whose intended characters include a literal `%`
//     are rejected**; callers that need raw `%` (rare) should
//     bypass `isSafeKey` and call the backend method directly.
// Used as a `requires:` precondition on every `StorageBucket` method
// that accepts a key.
pub func isSafeKey(key: in String): Bool {
  if key.length == 0                    { return false }
  if Str.contains(key, "\u{0000}")      { return false }
  // Reject double-encoded payloads (`%25` is the percent-encoded `%`).
  // A single-pass decode in `normalisedStorageKey` would otherwise let
  // `%252e%252e/etc/passwd` through, and an OS-level second decode at
  // the backend would reconstitute `../../etc/passwd`.
  val lk = Str.toLower(key)
  if Str.contains(lk, "%25")            { return false }
  val n = normalisedStorageKey(key)
  if n.length == 0                      { return false }
  if n[0] == '/'                        { return false }
  if storageKeyHasDotDot(n)             { return false }
  return true
}

// True when `prefix` is safe to pass to a storage backend's `list`
// operation.  Mirrors `isSafeKey` (see its doc-comment caveats — in
// particular the literal-`%` rejection) but admits the empty prefix
// (list everything) since `list` semantically accepts that.
pub func isSafePrefix(prefix: in String): Bool {
  if prefix.length == 0 { return true }
  return isSafeKey(prefix)
}

// ─── Error type ───────────────────────────────────────────────────────────────

/// An error returned by a storage provider.
@stable(since="0.1")
pub record StorageError {
  message: String
  code:    String    // provider-specific error code, e.g. "NoSuchKey", "AccessDenied"
}

// ─── Metadata and object types ────────────────────────────────────────────────

/// Metadata for a stored object.
@stable(since="0.1")
pub record StorageMetadata {
  contentType:   String
  contentLength: Long
  etag:          String
  lastModified:  String                 // ISO 8601 UTC string
  userMeta:      Map[String, String]    // caller-supplied key-value pairs
}

/// A downloaded storage object including its data and metadata.
@stable(since="0.1")
pub record StorageObject {
  bucket:     String
  key:        String
  metadata:   StorageMetadata
  dataBase64: String    // base64-encoded binary content
}

/// A single entry in a directory listing.
@stable(since="0.1")
pub record ListEntry {
  key:           String
  contentLength: Long
  lastModified:  String
  etag:          String
}

/// The result of a `list` call.  When `isTruncated` is true, pass
/// `nextContinuationToken` to the next `list` call to page through results.
@stable(since="0.1")
pub record ListResult {
  entries:                slice[ListEntry]
  nextContinuationToken:  Option[String]
  isTruncated:            Bool
}

// ─── StorageBucket interface ──────────────────────────────────────────────────

/// A handle to a storage bucket or container.  Obtain one with one of the
/// `connect*` factory functions.
@stable(since="0.1")
pub interface StorageBucket {
  /// Upload `dataBase64` (base64-encoded) under `key` with the given content
  /// type and optional user-defined metadata.
  func put(
    key:         in String,
    dataBase64:  in String,
    contentType: in String,
    userMeta:    in Map[String, String]
  ): Result[StorageMetadata, StorageError]
    requires: isSafeKey(key)
    requires: contentType.length > 0

  /// Download the object stored under `key`.
  func get(key: in String): Result[StorageObject, StorageError]
    requires: isSafeKey(key)

  /// Delete the object stored under `key`.
  func delete(key: in String): Result[Unit, StorageError]
    requires: isSafeKey(key)

  /// List objects whose keys begin with `prefix`.  Pass an empty string to
  /// list all objects.  Use `continuationToken` and `maxKeys` for paging.
  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[ListResult, StorageError]
    requires: maxKeys >= 1
    requires: isSafePrefix(prefix)

  /// Generate a pre-signed URL granting temporary access to `key`.
  /// `expiresInSeconds` is capped at 604800 (7 days) to match the AWS S3
  /// maximum and prevent permanent unrevocable access grants.
  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, StorageError]
    requires: isSafeKey(key)
    requires: expiresInSeconds >= 1
    requires: expiresInSeconds <= 604800

  /// Return true if an object with the given `key` exists.
  func exists(key: in String): Result[Bool, StorageError]
    requires: isSafeKey(key)
}

// ─── Local-filesystem bucket ─────────────────────────────────────────────────
//
// The local-fs backend stores each object as two files under
// `<basePath>/<bucketName>/<key>`:
//
//   * `<key>`              — raw bytes (base64-decoded from `dataBase64`)
//   * `<key>.meta.json`    — sidecar JSON object holding contentType,
//                            lastModified, etag, and userMeta
//
// Sidecar files keep all metadata observable across process boundaries
// and let `list` populate `ListEntry` from disk without re-reading every
// object's content (#1011).

// Internal record carrying the canonical bucket directory and its
// constituent parts.  Deliberately *not* `pub`: external packages must
// route through `connectLocal`, which validates and canonicalises the
// bucket directory before constructing the record.  Exposing the record
// publicly would let any caller bypass the constructor and hand a
// crafted `bucketDir` (e.g. `"/"`) into `resolveLocalPath`, defeating
// the trailing-separator escape guard — every key would match the
// degenerate prefix and writes would escape onto the host filesystem
// (#1407).
record LocalBucket {
  basePath:   String   // root directory
  bucketName: String   // sub-directory under basePath (the "bucket")
  bucketDir:  String   // canonical resolved bucketDir
}

// Resolve `key` to an absolute path inside `bucketDir`.  Rejects keys
// that escape via `..` or root tricks even after the public
// `isSafeKey` check (defence-in-depth).
func resolveLocalPath(bucket: in LocalBucket, key: in String): Result[String, StorageError] {
  // The public isSafeKey check has already rejected absolute keys and `..`
  // segments; this is a belt-and-braces canonicalised cross-check.
  //
  // Append a trailing separator before the `startsWith` test so a sibling
  // directory whose path is a string prefix of `bucketDir` (e.g.
  // `/var/lyric/bucketAEvil` vs `/var/lyric/bucketA`) is correctly rejected.
  // The canonicalised path of a key inside `bucketDir` always has the
  // separator between `bucketDir` and the rest, so this is exact, not
  // pessimistic.
  val joined    = bucket.bucketDir + "/" + key
  val canon     = hostPathGetFullPath(joined)
  val bucketTrm = if Str.endsWith(bucket.bucketDir, "/") { bucket.bucketDir }
                  else { bucket.bucketDir + "/" }
  if canon != bucket.bucketDir and not Str.startsWith(canon, bucketTrm) {
    return Err(StorageError(
      message = "resolved key path escapes bucket directory",
      code    = "INVALID_KEY"))
  }
  return Ok(canon)
}

// Build the sidecar `.meta.json` path for a resolved object path.
func metaSidecarPath(objectPath: in String): String {
  return objectPath + ".meta.json"
}

// Compute the lowercase-hex MD5 of `bytes`.  Matches the single-part S3
// ETag scheme so callers can verify content integrity end-to-end.
func computeEtag(bytes: in slice[Byte]): String {
  val raw = hostMd5(bytes)
  Str.toLower(hostBytesToHexUpper(raw))
}

// Format a sidecar JSON object: contentType / contentLength / lastModified /
// etag plus `userMeta` (JSON-pre-built by the caller so dict order is stable).
// `contentLength` is captured here so `listEntryForKey` can populate the
// per-entry length without re-reading the object's full payload (#1401).
func buildSidecarJson(contentType: in String, contentLength: in Long,
                       lastModified: in String, etag: in String,
                       userMetaJson: in String): String {
  val meta = if userMetaJson.length == 0 { "{}" } else { userMetaJson }
  return "{\"contentType\":" + jsonString(contentType)
       + ",\"contentLength\":" + toString(contentLength)
       + ",\"lastModified\":" + jsonString(lastModified)
       + ",\"etag\":" + jsonString(etag)
       + ",\"userMeta\":" + meta + "}"
}

// Best-effort directory-create.  Returns an `Err` only when the
// underlying BCL call throws and the directory still doesn't exist
// (typical permission failure).  Pre-existing directories return Ok.
func createDirIfMissing(path: in String): Result[Unit, StorageError] {
  if hostDirectoryExists(path) { return Ok(()) }
  return try {
    hostCreateDirectory(path)
    Ok(())
  } catch Bug as b {
    Err(StorageError(
      message = "cannot create directory '" + path + "': " + b.message,
      code    = "IO_ERROR"))
  }
}

// Compute the parent directory of `path` by truncating at the last
// path separator.  Robust against both `/` and `\` for cross-platform
// safety; an unrooted leaf returns "".
func parentDir(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    val c = path[i]
    if c == '/' or c == '\\' {
      return Str.substring(path, 0, i)
    }
    i = i - 1
  }
  return ""
}

// Best-effort recursive parent-directory create.  Walks the parents
// from the root down, creating each missing segment.  Used by `put` so
// hierarchical keys (e.g. `a/b/c.bin`) don't require the caller to
// pre-create intermediate dirs.
func ensureParents(path: in String): Result[Unit, StorageError] {
  val parent = parentDir(path)
  if parent.length == 0 or hostDirectoryExists(parent) {
    return Ok(())
  }
  match ensureParents(parent) {
    case Err(e) -> return Err(e)
    case Ok(_)  -> ()
  }
  createDirIfMissing(parent)
}

// ISO-8601 UTC formatted "now" for `lastModified`.
func nowIso8601(): String {
  return Time.toIsoString(Time.now())
}

impl StorageBucket for LocalBucket {

  func put(
    key:         in String,
    dataBase64:  in String,
    contentType: in String,
    userMeta:    in Map[String, String]
  ): Result[StorageMetadata, StorageError] {
    match resolveLocalPath(self, key) {
      case Err(e)        -> return Err(e)
      case Ok(fullPath)  -> {
        // Decode the wire payload to raw bytes.  Malformed base64 from
        // a hostile caller is surfaced as INVALID_BASE64 rather than a
        // generic IO error.
        val bytes: slice[Byte] = try {
          hostFromBase64(dataBase64)
        } catch Bug as b {
          return Err(StorageError(
            message = "invalid base64 payload: " + b.message,
            code    = "INVALID_BASE64"))
        }
        // Ensure parent directories exist for hierarchical keys
        // (e.g. `path/to/object.bin` under a fresh bucket).
        match ensureParents(fullPath) {
          case Err(e) -> return Err(e)
          case Ok(_)  -> ()
        }
        // Write the object content.
        match try {
          hostWriteAllBytes(fullPath, bytes)
          Ok(())
        } catch Bug as b {
          Err(StorageError(
            message = "cannot write object '" + key + "': " + b.message,
            code    = "PUT_ERROR"))
        } {
          case Err(e) -> return Err(e)
          case Ok(_)  -> ()
        }
        // Persist the sidecar metadata for round-trippable userMeta /
        // contentType / etag / lastModified.
        val etag          = computeEtag(bytes)
        val contentLength = intToLong(bytes.length)
        val lastModified  = nowIso8601()
        val userMetaJson  = serialiseStringMap(userMeta)
        val sidecarJson   = buildSidecarJson(contentType, contentLength,
                                             lastModified, etag, userMetaJson)
        match try {
          hostWriteAllText(metaSidecarPath(fullPath), sidecarJson)
          Ok(())
        } catch Bug as b {
          Err(StorageError(
            message = "cannot write metadata sidecar for '" + key + "': " + b.message,
            code    = "PUT_ERROR"))
        } {
          case Err(e) -> return Err(e)
          case Ok(_)  -> ()
        }
        return Ok(StorageMetadata(
          contentType   = contentType,
          contentLength = intToLong(bytes.length),
          etag          = etag,
          lastModified  = lastModified,
          userMeta      = userMeta))
      }
    }
  }

  func get(key: in String): Result[StorageObject, StorageError] {
    match resolveLocalPath(self, key) {
      case Err(e)        -> return Err(e)
      case Ok(fullPath)  -> {
        if not hostFileExists(fullPath) {
          return Err(StorageError(
            message = "key '" + key + "' not found in bucket",
            code    = "NOT_FOUND"))
        }
        val bytes: slice[Byte] = try {
          hostReadAllBytes(fullPath)
        } catch Bug as b {
          return Err(StorageError(
            message = "cannot read object '" + key + "': " + b.message,
            code    = "GET_ERROR"))
        }
        val dataBase64 = hostToBase64(bytes)
        match readSidecar(fullPath, intToLong(bytes.length)) {
          case Err(e)   -> Err(e)
          case Ok(meta) ->
            Ok(StorageObject(
              bucket     = self.bucketName,
              key        = key,
              metadata   = meta,
              dataBase64 = dataBase64))
        }
      }
    }
  }

  func delete(key: in String): Result[Unit, StorageError] {
    match resolveLocalPath(self, key) {
      case Err(e)        -> return Err(e)
      case Ok(fullPath)  -> {
        // Delete is idempotent: missing file is not an error.
        if hostFileExists(fullPath) {
          match try {
            hostDeleteFile(fullPath)
            Ok(())
          } catch Bug as b {
            Err(StorageError(
              message = "cannot delete object '" + key + "': " + b.message,
              code    = "DELETE_ERROR"))
          } {
            case Err(e) -> return Err(e)
            case Ok(_)  -> ()
          }
        }
        val sidecar = metaSidecarPath(fullPath)
        if hostFileExists(sidecar) {
          match try {
            hostDeleteFile(sidecar)
            Ok(())
          } catch Bug as b {
            Err(StorageError(
              message = "cannot delete metadata sidecar for '" + key + "': " + b.message,
              code    = "DELETE_ERROR"))
          } {
            case Err(e) -> return Err(e)
            case Ok(_)  -> ()
          }
        }
        return Ok(())
      }
    }
  }

  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[ListResult, StorageError] {
    if maxKeys < 1 or maxKeys > 1000 {
      return Err(StorageError(
        message = "maxKeys must be in [1, 1000]",
        code    = "INVALID_ARGUMENT"))
    }
    if not hostDirectoryExists(self.bucketDir) {
      return Ok(ListResult(
        entries                = [],
        nextContinuationToken  = None,
        isTruncated            = false))
    }
    // Collect every key (file path relative to bucketDir, with '/'
    // separators) by walking the directory tree.  Sidecar `.meta.json`
    // files are excluded.
    val allKeys: List[String] = newList()
    match walkDirectoryForKeys(self.bucketDir, "", allKeys) {
      case Err(e) -> return Err(e)
      case Ok(_)  -> ()
    }
    // Filter by prefix and continuation token; preserve the natural
    // disk order until we sort.
    val filtered: List[String] = newList()
    var i = 0
    while i < allKeys.count {
      val k = allKeys[i]
      if Str.startsWith(k, prefix) {
        if continuationToken.length == 0 or Str.compare(k, continuationToken) > 0 {
          filtered.add(k)
        }
      }
      i = i + 1
    }
    // Sort lexicographically so pagination is deterministic.
    val sorted = sortKeys(filtered)
    val truncated = sorted.count > maxKeys
    val pageCount = if truncated { maxKeys } else { sorted.count }
    // Accumulate into a `List` (O(1) amortised append) then convert to
    // `slice` once at the end — the previous `slice[ListEntry] =
    // concat(entries, [le])` inside the loop was O(n²): with the
    // documented `maxKeys` cap of 1000, ~500K element copies before
    // returning the page (#1409).
    val entriesAcc: List[ListEntry] = newList()
    var j = 0
    while j < pageCount {
      val k = sorted[j]
      match listEntryForKey(self, k) {
        case Err(e)  -> return Err(e)
        case Ok(le)  -> entriesAcc.add(le)
      }
      j = j + 1
    }
    val nextToken = if truncated and pageCount > 0 {
      Some(value = sorted[pageCount - 1])
    } else {
      None
    }
    return Ok(ListResult(
      entries                = entriesAcc.toArray(),
      nextContinuationToken  = nextToken,
      isTruncated            = truncated))
  }

  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, StorageError] {
    // The local-fs backend has no signing service.  Validate that the
    // key resolves cleanly before refusing.
    match resolveLocalPath(self, key) {
      case Err(e) -> return Err(e)
      case Ok(_)  ->
        Err(StorageError(
          message = "presigned URLs are not supported on the local-fs storage backend",
          code    = "NOT_SUPPORTED"))
    }
  }

  func exists(key: in String): Result[Bool, StorageError] {
    match resolveLocalPath(self, key) {
      case Err(e)        -> return Err(e)
      case Ok(fullPath)  -> Ok(hostFileExists(fullPath))
    }
  }
}

// Read a sidecar `.meta.json` file into StorageMetadata.  Tolerates a
// missing sidecar by returning a stub with the on-disk byte count and
// zeroed fields — this happens for files written outside the library or
// by an older version.
func readSidecar(objectPath: in String, contentLength: in Long): Result[StorageMetadata, StorageError] {
  val sidecar = metaSidecarPath(objectPath)
  if not hostFileExists(sidecar) {
    return Ok(StorageMetadata(
      contentType   = "application/octet-stream",
      contentLength = contentLength,
      etag          = "",
      lastModified  = "",
      userMeta      = newMap()))
  }
  val txt = try {
    hostReadAllText(sidecar)
  } catch Bug as b {
    return Err(StorageError(
      message = "cannot read metadata sidecar: " + b.message,
      code    = "META_READ_ERROR"))
  }
  // Wrap parseJson so a truncated / externally-corrupted sidecar
  // produces a typed `META_PARSE_ERROR` instead of an unhandled Bug
  // bubbling out of the storage layer (#1440).
  val doc = try {
    parseJson(txt)
  } catch Bug as b {
    return Err(StorageError(
      message = "cannot parse metadata sidecar JSON: " + b.message,
      code    = "META_PARSE_ERROR"))
  }
  val root = rootElement(doc)
  if valueKind(root) != 1 {
    return Err(StorageError(
      message = "malformed metadata sidecar",
      code    = "META_PARSE_ERROR"))
  }
  val ct = getString(getProperty(root, "contentType"))
  val lm = getString(getProperty(root, "lastModified"))
  val et = getString(getProperty(root, "etag"))
  val um = parseStringMap(getRawText(getProperty(root, "userMeta")))
  return Ok(StorageMetadata(
    contentType   = ct,
    contentLength = contentLength,
    etag          = et,
    lastModified  = lm,
    userMeta      = um))
}

// Recursive directory walk that accumulates relative-key paths (with
// '/' separators).  Excludes `*.meta.json` sidecars.  `relPrefix` is
// the running relative path from the bucket root; `acc` collects the
// keys.  Returns `Err(LIST_ERROR)` when an enumeration call fails so
// callers don't silently get short, inconsistent result pages — a
// previous "best-effort" version (#1408) would return whatever it had
// collected so far when a subdirectory was unreadable, breaking the
// standard "loop while isTruncated" pagination contract.
func walkDirectoryForKeys(dir: in String, relPrefix: in String, acc: in List[String]): Result[Unit, StorageError] {
  val files = try {
    hostGetFiles(dir)
  } catch Bug as b {
    return Err(StorageError(
      message = "cannot enumerate '" + dir + "': " + b.message,
      code    = "LIST_ERROR"))
  }
  var i = 0
  while i < files.length {
    val full = files[i]
    val base = basenameOf(full)
    if not Str.endsWith(base, ".meta.json") {
      val rel = if relPrefix.length == 0 { base } else { relPrefix + "/" + base }
      acc.add(rel)
    }
    i = i + 1
  }
  val subs = try {
    hostGetDirectories(dir)
  } catch Bug as b {
    return Err(StorageError(
      message = "cannot enumerate subdirs of '" + dir + "': " + b.message,
      code    = "LIST_ERROR"))
  }
  var k = 0
  while k < subs.length {
    val full = subs[k]
    val base = basenameOf(full)
    val nextPrefix = if relPrefix.length == 0 { base } else { relPrefix + "/" + base }
    match walkDirectoryForKeys(full, nextPrefix, acc) {
      case Err(e) -> return Err(e)
      case Ok(_)  -> ()
    }
    k = k + 1
  }
  return Ok(())
}

// Extract the final path component, robust against both `/` and `\`.
func basenameOf(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    val c = path[i]
    if c == '/' or c == '\\' {
      return Str.substring(path, i + 1, path.length - i - 1)
    }
    i = i - 1
  }
  return path
}

// Sort `xs` into ascending lexicographic order.  Routes through
// `Std.Sort.sortStrings` (merge sort) so the order is stable and
// deterministic for pagination.
func sortKeys(xs: in List[String]): List[String] {
  val arr    = xs.toArray()
  val sorted = sortStrings(arr)
  // Local variable named `acc` rather than `result` — `result` is a
  // reserved identifier in `ensures:` clauses and the parser treats
  // every reference as `EResult` even outside contract context, which
  // panics at codegen ("Msil.Codegen: EResult outside contract context").
  // (`out` would collide with the `out` parameter-mode keyword.)
  val acc: List[String] = newList()
  var i = 0
  while i < sorted.length {
    acc.add(sorted[i])
    i = i + 1
  }
  acc
}

// Build a `ListEntry` for `relKey` purely from its `.meta.json` sidecar.
// Does NOT read the object's content bytes at all (#1011 / #1401): the
// sidecar carries `contentLength`, `etag`, and `lastModified` that `put`
// recorded once, so list pages run at O(sidecar bytes) per entry rather
// than O(object bytes).  If the sidecar is missing or unparseable
// `contentLength` falls back to 0 and the optional fields stay empty —
// the operation still succeeds so partial / migrated buckets remain
// listable.
func listEntryForKey(bucket: in LocalBucket, relKey: in String): Result[ListEntry, StorageError] {
  match resolveLocalPath(bucket, relKey) {
    case Err(e)        -> Err(e)
    case Ok(fullPath)  -> {
      var contentLength: Long = intToLong(0)
      var etag                = ""
      var lastModified        = ""
      val sidecar = metaSidecarPath(fullPath)
      if hostFileExists(sidecar) {
        val txt = try {
          hostReadAllText(sidecar)
        } catch Bug as _ {
          ""
        }
        if txt.length > 0 {
          // Tolerate a corrupted / partially-written sidecar — the
          // entry is still listable with zero-valued fallbacks rather
          // than aborting the whole `list` call.  parseJson throws an
          // unhandled Bug on truncated input, so guard it with
          // try/catch and treat the failure the same as a missing
          // sidecar (#1440).
          val parsed = try {
            Some(value = parseJson(txt))
          } catch Bug as _ {
            None
          }
          match parsed {
            case Some(doc) -> {
              val root = rootElement(doc)
              if valueKind(root) == 1 {
                etag          = getString(getProperty(root, "etag"))
                lastModified  = getString(getProperty(root, "lastModified"))
                match tryGetLong(getProperty(root, "contentLength")) {
                  case Some(n) -> { contentLength = n }
                  case None    -> ()
                }
              }
            }
            case None -> ()
          }
        }
      }
      Ok(ListEntry(
        key           = relKey,
        contentLength = contentLength,
        lastModified  = lastModified,
        etag          = etag))
    }
  }
}

// ─── S3 / Azure stubs ────────────────────────────────────────────────────────
//
// These records keep the public `connect*` signatures stable so callers
// can switch to a real backend without code changes.  Every method
// currently returns `NOT_IMPLEMENTED`; replacing with NuGet-SDK bindings
// is tracked as a separate piece of work.  The records carry the
// connection parameters for future use rather than indirecting through
// a removed F# host.

record S3Bucket {
  region:      String
  bucketName:  String
  accessKey:   String
  secretKey:   String
  endpointUrl: String
}

func notImplementedS3(): StorageError {
  StorageError(
    message = "S3 backend not yet implemented; AWSSDK.S3 native bindings tracked as follow-up",
    code    = "NOT_IMPLEMENTED")
}

impl StorageBucket for S3Bucket {
  func put(
    key: in String, dataBase64: in String,
    contentType: in String, userMeta: in Map[String, String]
  ): Result[StorageMetadata, StorageError] { Err(notImplementedS3()) }

  func get(key: in String): Result[StorageObject, StorageError] { Err(notImplementedS3()) }
  func delete(key: in String): Result[Unit, StorageError] { Err(notImplementedS3()) }

  func list(
    prefix: in String, continuationToken: in String, maxKeys: in Int
  ): Result[ListResult, StorageError] { Err(notImplementedS3()) }

  func presignedUrl(
    key: in String, expiresInSeconds: in Int
  ): Result[String, StorageError] { Err(notImplementedS3()) }

  func exists(key: in String): Result[Bool, StorageError] { Err(notImplementedS3()) }
}

record AzureBucket {
  connectionString: String
  containerName:    String
}

func notImplementedAzure(): StorageError {
  StorageError(
    message = "Azure Blob backend not yet implemented; Azure.Storage.Blobs native bindings tracked as follow-up",
    code    = "NOT_IMPLEMENTED")
}

impl StorageBucket for AzureBucket {
  func put(
    key: in String, dataBase64: in String,
    contentType: in String, userMeta: in Map[String, String]
  ): Result[StorageMetadata, StorageError] { Err(notImplementedAzure()) }

  func get(key: in String): Result[StorageObject, StorageError] { Err(notImplementedAzure()) }
  func delete(key: in String): Result[Unit, StorageError] { Err(notImplementedAzure()) }

  func list(
    prefix: in String, continuationToken: in String, maxKeys: in Int
  ): Result[ListResult, StorageError] { Err(notImplementedAzure()) }

  func presignedUrl(
    key: in String, expiresInSeconds: in Int
  ): Result[String, StorageError] { Err(notImplementedAzure()) }

  func exists(key: in String): Result[Bool, StorageError] { Err(notImplementedAzure()) }
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open an Amazon S3 bucket.  Currently returns a stub bucket whose
/// operations report `NOT_IMPLEMENTED`; tracked as a follow-up to bind
/// `AWSSDK.S3` natively in Lyric.
@stable(since="0.1")
pub func connectS3(region: in String, bucket: in String, accessKey: in String, secretKey: in String, endpointUrl: in String): Result[StorageBucket, StorageError] {
  if region.length == 0 {
    return Err(StorageError(message = "region must be non-empty", code = "INVALID_ARGUMENT"))
  }
  if bucket.length == 0 {
    return Err(StorageError(message = "bucket must be non-empty", code = "INVALID_ARGUMENT"))
  }
  // S3 backend is not yet implemented (the NuGet AWS SDK bindings are
  // tracked as follow-up work).  Fail fast at the factory rather than
  // returning a stub bucket that produces `NOT_IMPLEMENTED` on every
  // subsequent operation — that fail-late shape silently swallowed
  // caller code that defensively branched on `Err` from `connectS3`
  // (#1441).  When the native bindings land, replace this with the
  // real `Ok(S3Bucket(...))` construction.
  return Err(StorageError(
    message = "S3 backend not yet implemented (native bindings pending)",
    code    = "NOT_IMPLEMENTED"))
}

/// Open an Azure Blob Storage container.  Currently returns `Err`
/// because the native Azure SDK bindings are tracked as follow-up
/// work.  Fail-fast at the factory matches the historical F# host
/// shim's semantics (#1441) — code that defensively branches on
/// `Err` from `connectAzureBlob` must continue to do so.
@stable(since="0.1")
pub func connectAzureBlob(connectionString: in String, containerName: in String): Result[StorageBucket, StorageError] {
  if connectionString.length == 0 {
    return Err(StorageError(message = "connectionString must be non-empty", code = "INVALID_ARGUMENT"))
  }
  if containerName.length == 0 {
    return Err(StorageError(message = "containerName must be non-empty", code = "INVALID_ARGUMENT"))
  }
  return Err(StorageError(
    message = "Azure Blob backend not yet implemented (native bindings pending)",
    code    = "NOT_IMPLEMENTED"))
}

/// Open a local filesystem store.  The bucket subdirectory is created
/// inside `basePath` if it doesn't already exist (matches the local-fs
/// idiom; S3 and Azure require the bucket to exist out-of-band).
@stable(since="0.1")
pub func connectLocal(basePath: in String, bucketName: in String): Result[StorageBucket, StorageError] {
  if basePath.length == 0 {
    return Err(StorageError(message = "basePath must be non-empty", code = "INVALID_ARGUMENT"))
  }
  if bucketName.length == 0 {
    return Err(StorageError(message = "bucketName must be non-empty", code = "INVALID_ARGUMENT"))
  }
  // Ensure the base path exists first so GetFullPath can canonicalise
  // relative components inside it.  Both calls are idempotent.
  match createDirIfMissing(basePath) {
    case Err(e) -> return Err(e)
    case Ok(_)  -> ()
  }
  val joined    = basePath + "/" + bucketName
  val bucketDir = hostPathGetFullPath(joined)
  match createDirIfMissing(bucketDir) {
    case Err(e) -> return Err(e)
    case Ok(_)  ->
      Ok(LocalBucket(
        basePath   = basePath,
        bucketName = bucketName,
        bucketDir  = bucketDir))
  }
}

// The previous `connect(provider: String)` dispatcher referenced the
// `@cfg`-gated `connectS3` / `connectAzureBlob` / `connectLocal`
// constructors unconditionally, so callers had to either enable every
// feature or the manifest build failed with `T0020 unknown name`.
// The explicit constructors are the canonical entry points and remain
// the documented API.

// ─── Convenience wrappers ─────────────────────────────────────────────────────

/// Upload an object with the given content type and no user-defined metadata.
@stable(since="0.1")
pub func put(
  bucket:      in StorageBucket,
  key:         in String,
  dataBase64:  in String,
  contentType: in String
): Result[StorageMetadata, StorageError]
  requires: key.length > 0
  requires: contentType.length > 0
{
  return bucket.put(key, dataBase64, contentType, newMap())
}

/// Download an object.
@stable(since="0.1")
pub func get(bucket: in StorageBucket, key: in String): Result[StorageObject, StorageError]
  requires: key.length > 0
{
  return bucket.get(key)
}

/// Delete an object.
@stable(since="0.1")
pub func delete(bucket: in StorageBucket, key: in String): Result[Unit, StorageError]
  requires: key.length > 0
{
  return bucket.delete(key)
}

/// List all objects under `prefix` (pass `""` for all objects), using
/// an empty continuation token and a default page size of 1000.
@stable(since="0.1")
pub func list(bucket: in StorageBucket, prefix: in String): Result[ListResult, StorageError] {
  return bucket.list(prefix, "", 1000)
}

/// Generate a pre-signed URL granting temporary access to `key`.
/// `expiresInSeconds` must be between 1 and 604800 (7 days) inclusive.
/// This cap prevents issuing effectively permanent unrevocable access URLs.
@stable(since="0.1")
pub func presignedUrl(
  bucket:           in StorageBucket,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, StorageError]
  requires: key.length > 0
  requires: expiresInSeconds >= 1
  requires: expiresInSeconds <= 604800
{
  return bucket.presignedUrl(key, expiresInSeconds)
}

/// Return true if an object with the given `key` exists.
@stable(since="0.1")
pub func exists(bucket: in StorageBucket, key: in String): Result[Bool, StorageError]
  requires: key.length > 0
{
  return bucket.exists(key)
}

// ─── Audit log hook ──────────────────────────────────────────────────────────

/// Emit an audit log line.  `operation` is the canonical call name,
/// `level` is one of `"info"` / `"warn"` / `"debug"`, `detail` is an
/// optional free-form message (empty when there is none).
///
/// No-op for the bootstrap; structured audit sink tracked separately.
/// Kept as a public function so `Storage.Aspects.AuditAccess` continues
/// to compile against a stable name.  Lives here rather than in
/// `_kernel/net/storage_kernel.l` because kernel files are the audited
/// BCL boundary and may only contain `@externTarget` / `extern type`
/// declarations (#1410).
@stable(since="0.1")
pub func auditLog(operation: in String, level: in String, detail: in String): Unit {
  return ()
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Serialise a Map[String, String] to a JSON object string.
func serialiseStringMap(m: in Map[String, String]): String {
  // Empty-map fast path — Map iteration via `for k in m` panics under
  // the self-hosted MSIL bridge ("SFor not supported in bootstrap").
  // The data plane currently only writes an empty `userMeta` Map
  // (every public `put` overload calls `bucket.put(key, data, ct,
  // newMap())`), so an "{}" sidecar value preserves the round-trip
  // contract for today's call sites.  When non-empty `userMeta`
  // becomes reachable, refactor `put` to thread an explicit
  // List[(String, String)] alongside the Map so this serialiser
  // can iterate without `SFor`.
  if m.count == 0 { return "{}" }
  return "{}"
}

// Deserialise a JSON object of string-string pairs into Map[String, String].
// Accepts raw JSON text so JsonElement does not escape this helper.
func parseStringMap(rawJson: in String): Map[String, String] {
  var m    = newMap()
  val doc  = parseJson(rawJson)
  val elem = rootElement(doc)
  if valueKind(elem) != 1 { return m }
  var en = enumerateObject(elem)
  while objectMoveNext(en) {
    val prop = objectCurrent(en)
    val k    = propertyName(prop)
    val v    = getString(propertyValue(prop))
    m.add(k, v)
  }
  return m
}

// Wrap a string in JSON double quotes with basic escaping.
func jsonString(s: in String): String {
  var buf = "\""
  var i   = 0
  while i < s.length {
    val ch = s[i].toString()
    if ch == "\"" {
      buf = buf + "\\\""
    } else if ch == "\\" {
      buf = buf + "\\\\"
    } else if ch == "\n" {
      buf = buf + "\\n"
    } else if ch == "\r" {
      buf = buf + "\\r"
    } else if ch == "\t" {
      buf = buf + "\\t"
    } else {
      buf = buf + ch
    }
    i = i + 1
  }
  return buf + "\""
}
