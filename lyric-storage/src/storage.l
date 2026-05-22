// Storage — object and file storage library for Lyric.
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
//   val bucket = Storage.connectS3()?
//   Storage.put(bucket, "uploads/photo.jpg", base64Data, "image/jpeg")?
//   match Storage.get(bucket, "uploads/photo.jpg") {
//     case Ok(obj) -> println(obj.metadata.contentType)
//     case Err(e)  -> println(e.message)
//   }
//   val listing = Storage.list(bucket, "uploads/")?
//
// Runtime config env vars (LYRIC_CONFIG_S3CONNECTION_*, etc.):
//   LYRIC_CONFIG_S3CONNECTION_REGION       — AWS region (required for S3)
//   LYRIC_CONFIG_S3CONNECTION_BUCKET       — S3 bucket name
//   LYRIC_CONFIG_S3CONNECTION_ACCESSKEY    — AWS access key (@sensitive)
//   LYRIC_CONFIG_S3CONNECTION_SECRETKEY    — AWS secret key (@sensitive)
//   LYRIC_CONFIG_S3CONNECTION_ENDPOINTURL  — custom endpoint URL (default: "")
//   LYRIC_CONFIG_AZURECONNECTION_CONNECTIONSTRING — Azure connection string
//   LYRIC_CONFIG_AZURECONNECTION_CONTAINERNAME    — Azure container name
//   LYRIC_CONFIG_LOCALCONNECTION_BASEPATH  — local base path (default: /tmp/lyric-storage)
//   LYRIC_CONFIG_LOCALCONNECTION_BUCKETNAME — local bucket directory name
//
// See docs/03-decision-log.md D056 and lyric-storage/README.md.

@runtime_checked
package Storage

import Std.Core
import Std.Collections
import Std.Json
import Std.Iter
import Std.String as Str

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
  if n.charAt(0).toString() == "/"      { return false }
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

// ─── Kernel boundary (inlined) ────────────────────────────────────────────────
// Declared here rather than imported from Storage.Kernel.Net because
// intra-project import resolution does not yet propagate function signatures
// to the caller's type-checker.  Storage.Kernel.Net still exports these for
// aspects and external consumers.
//
// Each provider gets its own `@cfg`-gated `extern package` block.  The shared
// data-plane functions (`storagePut`/`storageGet`/...) dispatch on the
// runtime bucket-handle type, so we declare them in a single non-feature-
// gated kernel namespace (`Lyric.Storage.Kernel`) that the host shim will
// resolve at link time once the storage backends are wired up (#733).

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3) — connectS3 opens a bucket handle")
@cfg(feature = "s3")
extern package AWSSDK.S3 {
  func storageConnectS3(region: String, bucket: String, accessKey: String, secretKey: String, endpointUrl: String): Result[Int, String]
    requires: region.length > 0
    requires: bucket.length > 0
}

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs) — connectAzure opens a container handle")
@cfg(feature = "azureblob")
extern package Azure.Storage.Blobs {
  func storageConnectAzure(connectionString: String, containerName: String): Result[Int, String]
    requires: connectionString.length > 0
    requires: containerName.length > 0
}

@axiom("Local filesystem storage using System.IO — connectLocal opens a directory-backed bucket handle")
@cfg(feature = "local")
extern package System.IO {
  func storageConnectLocal(basePath: String, bucketName: String): Result[Int, String]
    requires: basePath.length > 0
    requires: bucketName.length > 0
}

@axiom("Shared data-plane: Amazon.S3.AmazonS3Client / Azure.Storage.Blobs.BlobContainerClient / System.IO.File — dispatched by the runtime bucket-handle provider tag")
extern package Lyric.Storage.Kernel {
  /// Upload an object.  userMetaJson is a JSON object of string key-value pairs.
  /// Returns JSON-serialised StorageMetadata on success.
  func storagePut(bucketHandle: Int, key: String, dataBase64: String, contentType: String, userMetaJson: String): Result[String, String]
    requires: key.length > 0

  /// Download an object.  Returns JSON-serialised StorageObject on success.
  func storageGet(bucketHandle: Int, key: String): Result[String, String]
    requires: key.length > 0

  /// Delete an object.
  func storageDelete(bucketHandle: Int, key: String): Result[Unit, String]
    requires: key.length > 0

  /// List objects with an optional prefix.  Returns JSON-serialised ListResult.
  func storageList(bucketHandle: Int, prefix: String, continuationToken: String, maxKeys: Int): Result[String, String]
    requires: maxKeys >= 1
    requires: maxKeys <= 1000

  /// Generate a pre-signed URL that grants temporary access to the object.
  /// expiresInSeconds is clamped to the provider's maximum (S3: 7 days).
  func storagePresignedUrl(bucketHandle: Int, key: String, expiresInSeconds: Int): Result[String, String]
    requires: key.length > 0
    requires: expiresInSeconds >= 1

  /// Return true if an object with the given key exists in the bucket.
  func storageExists(bucketHandle: Int, key: String): Result[Bool, String]
    requires: key.length > 0
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

// ─── Native bucket wrapper (internal) ────────────────────────────────────────

// Integer handle issued by the kernel; opaque to consumers.
record NativeBucket { bucketHandle: Int; bucketName: String }

impl StorageBucket for NativeBucket {
  func put(
    key:         in String,
    dataBase64:  in String,
    contentType: in String,
    userMeta:    in Map[String, String]
  ): Result[StorageMetadata, StorageError] {
    val userMetaJson = serialiseStringMap(userMeta)
    match storagePut(self.bucketHandle, key, dataBase64, contentType, userMetaJson) {
      case Ok(json) -> parseMetadata(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "PUT_ERROR"))
    }
  }

  func get(key: in String): Result[StorageObject, StorageError] {
    match storageGet(self.bucketHandle, key) {
      case Ok(json) -> parseStorageObject(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "GET_ERROR"))
    }
  }

  func delete(key: in String): Result[Unit, StorageError] {
    match storageDelete(self.bucketHandle, key) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(StorageError(message = msg, code = "DELETE_ERROR"))
    }
  }

  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[ListResult, StorageError] {
    match storageList(self.bucketHandle, prefix, continuationToken, maxKeys) {
      case Ok(json) -> parseListResult(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "LIST_ERROR"))
    }
  }

  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, StorageError] {
    match storagePresignedUrl(self.bucketHandle, key, expiresInSeconds) {
      case Ok(url)  -> Ok(url)
      case Err(msg) -> Err(StorageError(message = msg, code = "PRESIGN_ERROR"))
    }
  }

  func exists(key: in String): Result[Bool, StorageError] {
    match storageExists(self.bucketHandle, key) {
      case Ok(b)    -> Ok(b)
      case Err(msg) -> Err(StorageError(message = msg, code = "EXISTS_ERROR"))
    }
  }
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open an Amazon S3 bucket.  Credentials and region are passed explicitly.
@stable(since="0.1")
pub func connectS3(region: in String, bucket: in String, accessKey: in String, secretKey: in String, endpointUrl: in String): Result[StorageBucket, StorageError] {
  match storageConnectS3(region, bucket, accessKey, secretKey, endpointUrl)
  {
    case Ok(handle) -> Ok(NativeBucket(bucketHandle = handle, bucketName = bucket))
    case Err(msg)   -> Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open an Azure Blob Storage container.  Connection string and container name are passed explicitly.
@stable(since="0.1")
pub func connectAzureBlob(connectionString: in String, containerName: in String): Result[StorageBucket, StorageError] {
  match storageConnectAzure(connectionString, containerName)
  {
    case Ok(handle) -> Ok(NativeBucket(bucketHandle = handle, bucketName = containerName))
    case Err(msg)   -> Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a local filesystem store.  Base path and bucket name are passed explicitly.
@stable(since="0.1")
pub func connectLocal(basePath: in String, bucketName: in String): Result[StorageBucket, StorageError] {
  match storageConnectLocal(basePath, bucketName)
  {
    case Ok(handle) -> Ok(NativeBucket(bucketHandle = handle, bucketName = bucketName))
    case Err(msg)   -> Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Dispatch to the configured backend.  Returns Err when provider is unrecognised.
@experimental
pub func connect(provider: in String): Result[StorageBucket, StorageError]
  requires: provider.length > 0
{
  if provider == "s3" {
    return connectS3("", "", "", "", "")
  } else if provider == "azure" {
    return connectAzureBlob("", "")
  } else if provider == "local" {
    return connectLocal("/tmp/lyric-storage", "")
  } else {
    return Err(StorageError(
      message = "unknown storage provider: " + provider,
      code    = "UNKNOWN_PROVIDER"))
  }
}

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

// ─── Private helpers ──────────────────────────────────────────────────────────

// Serialise a Map[String, String] to a JSON object string.
func serialiseStringMap(m: in Map[String, String]): String {
  var result = "{"
  var first  = true
  for k in m {
    match mapGet(m, k) {
      case Some(v) -> {
        if not first { result = result + "," }
        result = result + jsonString(k) + ":" + jsonString(v)
        first  = false
      }
      case None -> ()
    }
  }
  return result + "}"
}

// Deserialise the JSON returned by the kernel's `put` into StorageMetadata.
// JSON shape: {"contentType":"...","contentLength":N,"etag":"...","lastModified":"...","userMeta":{...}}
func parseMetadata(json: in String): Result[StorageMetadata, StorageError] {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  if valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected metadata JSON shape", code = "PARSE_ERROR"))
  }
  val ct  = getString(getProperty(root, "contentType"))
  val cl  = getInt64(getProperty(root, "contentLength"))
  val et  = getString(getProperty(root, "etag"))
  val lm  = getString(getProperty(root, "lastModified"))
  val um  = parseStringMap(getRawText(getProperty(root, "userMeta")))
  return Ok(StorageMetadata(
    contentType   = ct,
    contentLength = cl,
    etag          = et,
    lastModified  = lm,
    userMeta      = um))
}

// Deserialise the JSON returned by the kernel's `get` into StorageObject.
// JSON shape: {"bucket":"...","key":"...","metadata":{...},"dataBase64":"..."}
func parseStorageObject(json: in String): Result[StorageObject, StorageError] {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  if valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected object JSON shape", code = "PARSE_ERROR"))
  }
  val bucket = getString(getProperty(root, "bucket"))
  val key    = getString(getProperty(root, "key"))
  val data   = getString(getProperty(root, "dataBase64"))
  val metaEl = getProperty(root, "metadata")
  val metaJson = getRawText(metaEl)
  match parseMetadata(metaJson) {
    case Ok(meta) ->
      Ok(StorageObject(bucket = bucket, key = key, metadata = meta, dataBase64 = data))
    case Err(e) ->
      Err(e)
  }
}

// Deserialise the JSON returned by the kernel's `list` into ListResult.
// JSON shape: {"entries":[...],"nextContinuationToken":"..."|null,"isTruncated":bool}
func parseListResult(json: in String): Result[ListResult, StorageError] {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  if valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected list JSON shape", code = "PARSE_ERROR"))
  }
  val truncated = getBoolean(getProperty(root, "isTruncated"))
  val tokenEl   = getProperty(root, "nextContinuationToken")
  val tokenOpt  = if valueKind(tokenEl) == 7 { None } else { Some(value = getString(tokenEl)) }
  val arrEl     = getProperty(root, "entries")
  var entries: slice[ListEntry] = []
  var en = enumerateArray(arrEl)
  while arrayMoveNext(en) {
    val e   = arrayCurrent(en)
    val ek  = getString(getProperty(e, "key"))
    val ecl = getInt64(getProperty(e, "contentLength"))
    val elm = getString(getProperty(e, "lastModified"))
    val eet = getString(getProperty(e, "etag"))
    entries = concat(entries, [ListEntry(key = ek, contentLength = ecl, lastModified = elm, etag = eet)])
  }
  return Ok(ListResult(
    entries                = entries,
    nextContinuationToken  = tokenOpt,
    isTruncated            = truncated))
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
