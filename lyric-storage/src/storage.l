/// Storage — object and file storage library for Lyric.
///
/// Provides a uniform `StorageBucket` interface over Amazon S3, Azure Blob
/// Storage, and the local filesystem.  Obtain a bucket handle with one of the
/// feature-gated `connect*` factory functions, then call the typed wrappers or
/// the interface methods directly.
///
/// Usage:
///
///   import Storage
///   import Std.Collections
///
///   val bucket = Storage.connectS3()?
///   Storage.put(bucket, "uploads/photo.jpg", base64Data, "image/jpeg")?
///   match Storage.get(bucket, "uploads/photo.jpg") {
///     case Ok(obj) -> println(obj.metadata.contentType)
///     case Err(e)  -> println(e.message)
///   }
///   val listing = Storage.list(bucket, "uploads/")?
///
/// Runtime config env vars (LYRIC_CONFIG_S3CONNECTION_*, etc.):
///   LYRIC_CONFIG_S3CONNECTION_REGION       — AWS region (required for S3)
///   LYRIC_CONFIG_S3CONNECTION_BUCKET       — S3 bucket name
///   LYRIC_CONFIG_S3CONNECTION_ACCESSKEY    — AWS access key (@sensitive)
///   LYRIC_CONFIG_S3CONNECTION_SECRETKEY    — AWS secret key (@sensitive)
///   LYRIC_CONFIG_S3CONNECTION_ENDPOINTURL  — custom endpoint URL (default: "")
///   LYRIC_CONFIG_AZURECONNECTION_CONNECTIONSTRING — Azure connection string
///   LYRIC_CONFIG_AZURECONNECTION_CONTAINERNAME    — Azure container name
///   LYRIC_CONFIG_LOCALCONNECTION_BASEPATH  — local base path (default: /tmp/lyric-storage)
///   LYRIC_CONFIG_LOCALCONNECTION_BUCKETNAME — local bucket directory name
///
/// See docs/03-decision-log.md D056 and lyric-storage/README.md.

@runtime_checked
package Storage

import Std.Core
import Std.Collections
import Std.Json
import Storage.Kernel.Net as StorageKernel

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
  entries:                [ListEntry]
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
    requires: key.length > 0
    requires: contentType.length > 0

  /// Download the object stored under `key`.
  func get(key: in String): Result[StorageObject, StorageError]
    requires: key.length > 0

  /// Delete the object stored under `key`.
  func delete(key: in String): Result[Unit, StorageError]
    requires: key.length > 0

  /// List objects whose keys begin with `prefix`.  Pass an empty string to
  /// list all objects.  Use `continuationToken` and `maxKeys` for paging.
  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[ListResult, StorageError]
    requires: maxKeys >= 1

  /// Generate a pre-signed URL granting temporary access to `key`.
  /// `expiresInSeconds` is capped at 604800 (7 days) to match the AWS S3
  /// maximum and prevent permanent unrevocable access grants.
  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, StorageError]
    requires: key.length > 0
    requires: expiresInSeconds >= 1
    requires: expiresInSeconds <= 604800

  /// Return true if an object with the given `key` exists.
  func exists(key: in String): Result[Bool, StorageError]
    requires: key.length > 0
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
    match StorageKernel.put(bucketHandle, key, dataBase64, contentType, userMetaJson) {
      case Ok(json) -> parseMetadata(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "PUT_ERROR"))
    }
  }

  func get(key: in String): Result[StorageObject, StorageError] {
    match StorageKernel.get(bucketHandle, key) {
      case Ok(json) -> parseStorageObject(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "GET_ERROR"))
    }
  }

  func delete(key: in String): Result[Unit, StorageError] {
    match StorageKernel.delete(bucketHandle, key) {
      case Ok(_)    -> Ok(())
      case Err(msg) -> Err(StorageError(message = msg, code = "DELETE_ERROR"))
    }
  }

  func list(
    prefix:            in String,
    continuationToken: in String,
    maxKeys:           in Int
  ): Result[ListResult, StorageError] {
    match StorageKernel.list(bucketHandle, prefix, continuationToken, maxKeys) {
      case Ok(json) -> parseListResult(json)
      case Err(msg) -> Err(StorageError(message = msg, code = "LIST_ERROR"))
    }
  }

  func presignedUrl(
    key:              in String,
    expiresInSeconds: in Int
  ): Result[String, StorageError] {
    match StorageKernel.presignedUrl(bucketHandle, key, expiresInSeconds) {
      case Ok(url)  -> Ok(url)
      case Err(msg) -> Err(StorageError(message = msg, code = "PRESIGN_ERROR"))
    }
  }

  func exists(key: in String): Result[Bool, StorageError] {
    match StorageKernel.exists(bucketHandle, key) {
      case Ok(b)    -> Ok(b)
      case Err(msg) -> Err(StorageError(message = msg, code = "EXISTS_ERROR"))
    }
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// Amazon S3 connection settings.
config S3Connection {
  region:      String
  bucket:      String
  @sensitive
  accessKey:   String = ""
  @sensitive
  secretKey:   String = ""
  endpointUrl: String = ""   // empty = use the default AWS regional endpoint
}

/// Azure Blob Storage connection settings.
config AzureConnection {
  connectionString: String
  containerName:    String
}

/// Local filesystem storage settings.
config LocalConnection {
  basePath:   String = "/tmp/lyric-storage"
  bucketName: String
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open an Amazon S3 bucket using the S3Connection config block.
/// Requires the `s3` feature to be active (`[features] s3 = []`).
@stable(since="0.1")
@cfg(feature = "s3")
pub func connectS3(): Result[StorageBucket, StorageError] {
  match StorageKernel.connectS3(
    S3Connection.region,
    S3Connection.bucket,
    S3Connection.accessKey,
    S3Connection.secretKey,
    S3Connection.endpointUrl)
  {
    case Ok(handle) -> Ok(NativeBucket(bucketHandle = handle, bucketName = S3Connection.bucket))
    case Err(msg)   -> Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open an Azure Blob Storage container using the AzureConnection config block.
/// Requires the `azureblob` feature to be active (`[features] azureblob = []`).
@stable(since="0.1")
@cfg(feature = "azureblob")
pub func connectAzureBlob(): Result[StorageBucket, StorageError] {
  match StorageKernel.connectAzure(
    AzureConnection.connectionString,
    AzureConnection.containerName)
  {
    case Ok(handle) ->
      Ok(NativeBucket(bucketHandle = handle, bucketName = AzureConnection.containerName))
    case Err(msg) ->
      Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Open a local filesystem store using the LocalConnection config block.
/// Requires the `local` feature to be active (`[features] local = []`).
@stable(since="0.1")
@cfg(feature = "local")
pub func connectLocal(): Result[StorageBucket, StorageError] {
  match StorageKernel.connectLocal(
    LocalConnection.basePath,
    LocalConnection.bucketName)
  {
    case Ok(handle) ->
      Ok(NativeBucket(bucketHandle = handle, bucketName = LocalConnection.bucketName))
    case Err(msg) ->
      Err(StorageError(message = msg, code = "CONNECT_ERROR"))
  }
}

/// Dispatch `connect` by provider name: "s3", "azure", or "local".
/// Falls back to `Err` for unrecognised provider strings.
///
/// **Note:** this function calls the `@cfg`-gated `connectS3()`, `connectAzureBlob()`,
/// and `connectLocal()` helpers.  The caller must ensure that the matching
/// feature is active in the compiled binary; calling `connect("s3")` without
/// the `s3` feature will produce a link error.  For compile-time safety,
/// prefer calling the typed `connectS3()` / `connectAzureBlob()` / `connectLocal()`
/// directly.
@experimental
pub func connect(provider: in String): Result[StorageBucket, StorageError]
  requires: provider.length > 0
{
  if provider == "s3" {
    return connectS3()
  } else if provider == "azure" {
    return connectAzureBlob()
  } else if provider == "local" {
    return connectLocal()
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
  return bucket.put(key, dataBase64, contentType, Map.empty())
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
  for (k, v) in m {
    if not first { result = result + "," }
    result = result + jsonString(k) + ":" + jsonString(v)
    first  = false
  }
  return result + "}"
}

// Deserialise the JSON returned by the kernel's `put` into StorageMetadata.
// JSON shape: {"contentType":"...","contentLength":N,"etag":"...","lastModified":"...","userMeta":{...}}
func parseMetadata(json: in String): Result[StorageMetadata, StorageError] {
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  if Std.Json.valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected metadata JSON shape", code = "PARSE_ERROR"))
  }
  val ct  = Std.Json.getString(Std.Json.getProperty(root, "contentType"))
  val cl  = Std.Json.getInt64(Std.Json.getProperty(root, "contentLength"))
  val et  = Std.Json.getString(Std.Json.getProperty(root, "etag"))
  val lm  = Std.Json.getString(Std.Json.getProperty(root, "lastModified"))
  val um  = parseStringMap(Std.Json.getRawText(Std.Json.getProperty(root, "userMeta")))
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
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  if Std.Json.valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected object JSON shape", code = "PARSE_ERROR"))
  }
  val bucket = Std.Json.getString(Std.Json.getProperty(root, "bucket"))
  val key    = Std.Json.getString(Std.Json.getProperty(root, "key"))
  val data   = Std.Json.getString(Std.Json.getProperty(root, "dataBase64"))
  val metaEl = Std.Json.getProperty(root, "metadata")
  val metaJson = Std.Json.getRawText(metaEl)
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
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  if Std.Json.valueKind(root) != 1 {
    return Err(StorageError(message = "unexpected list JSON shape", code = "PARSE_ERROR"))
  }
  val truncated = Std.Json.getBoolean(Std.Json.getProperty(root, "isTruncated"))
  val tokenEl   = Std.Json.getProperty(root, "nextContinuationToken")
  val tokenOpt  = if Std.Json.valueKind(tokenEl) == 7 then None
                  else Some(value = Std.Json.getString(tokenEl))
  val arrEl     = Std.Json.getProperty(root, "entries")
  var entries: [ListEntry] = []
  var en = Std.Json.enumerateArray(arrEl)
  while Std.Json.arrayMoveNext(en) {
    val e   = Std.Json.arrayCurrent(en)
    val ek  = Std.Json.getString(Std.Json.getProperty(e, "key"))
    val ecl = Std.Json.getInt64(Std.Json.getProperty(e, "contentLength"))
    val elm = Std.Json.getString(Std.Json.getProperty(e, "lastModified"))
    val eet = Std.Json.getString(Std.Json.getProperty(e, "etag"))
    entries = entries + [ListEntry(key = ek, contentLength = ecl, lastModified = elm, etag = eet)]
  }
  return Ok(ListResult(
    entries                = entries,
    nextContinuationToken  = tokenOpt,
    isTruncated            = truncated))
}

// Deserialise a JSON object of string-string pairs into Map[String, String].
// Accepts raw JSON text so JsonElement does not escape this helper.
func parseStringMap(rawJson: in String): Map[String, String] {
  var m    = Map.empty()
  val doc  = Std.Json.parseJson(rawJson)
  val elem = Std.Json.rootElement(doc)
  if Std.Json.valueKind(elem) != 1 { return m }
  var en = Std.Json.enumerateObject(elem)
  while Std.Json.objectMoveNext(en) {
    val prop = Std.Json.objectCurrent(en)
    val k    = Std.Json.propertyName(prop)
    val v    = Std.Json.getString(Std.Json.propertyValue(prop))
    m = m.set(k, v)
  }
  return m
}

// Wrap a string in JSON double quotes with basic escaping.
func jsonString(s: in String): String {
  var out = "\""
  var i   = 0
  while i < s.length {
    val ch = s.charAt(i).toString()
    if ch == "\"" {
      out = out + "\\\""
    } else if ch == "\\" {
      out = out + "\\\\"
    } else if ch == "\n" {
      out = out + "\\n"
    } else if ch == "\r" {
      out = out + "\\r"
    } else if ch == "\t" {
      out = out + "\\t"
    } else {
      out = out + ch
    }
    i = i + 1
  }
  return out + "\""
}
