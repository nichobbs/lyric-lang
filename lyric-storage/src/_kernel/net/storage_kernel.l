/// Storage.Kernel.Net — extern boundary for object/file storage providers.
///
/// Bridges Lyric's Storage package to .NET storage libraries:
///   AWSSDK.S3              — Amazon S3               (@cfg feature = "s3")
///   Azure.Storage.Blobs    — Azure Blob Storage       (@cfg feature = "azureblob")
///   System.IO.Storage      — Local filesystem         (@cfg feature = "local")
///   System.Diagnostics.Audit — Audit logging          (always available)
///
/// All storage operations use opaque Int handles returned by `connect*`.
///
/// JSON wire formats:
///   put returns:  {"contentType":"...","contentLength":N,"etag":"...","lastModified":"...","userMeta":{...}}
///   get returns:  {"bucket":"...","key":"...","metadata":{...},"dataBase64":"..."}
///   list returns: {"entries":[{"key":"...","contentLength":N,"lastModified":"...","etag":"..."},...],
///                  "nextContinuationToken":"..." | null, "isTruncated":true|false}
///
/// Error strings contain the provider error message and, where available, the
/// provider-specific error code.
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Storage.Kernel.Net

// ─── Amazon S3 provider ───────────────────────────────────────────────────────

@axiom("Amazon S3 SDK for .NET")
@cfg(feature = "s3")
extern package AWSSDK.S3 {
  /// Open an S3 client for the given bucket.  Returns an opaque bucket handle.
  /// Pass empty strings for accessKey/secretKey to use the ambient IAM role.
  /// Pass an empty endpointUrl to use the default AWS regional endpoint.
  pub func connect(
    region:      String,
    bucket:      String,
    accessKey:   String,
    secretKey:   String,
    endpointUrl: String
  ): Result[Int, String]

  /// Upload an object.  userMetaJson is a JSON object of string key-value pairs.
  /// Returns JSON-serialised StorageMetadata on success.
  pub func put(
    bucketHandle: Int,
    key:          String,
    dataBase64:   String,
    contentType:  String,
    userMetaJson: String
  ): Result[String, String]

  /// Download an object.  Returns JSON-serialised StorageObject on success.
  pub func get(bucketHandle: Int, key: String): Result[String, String]

  /// Delete an object.
  pub func delete(bucketHandle: Int, key: String): Result[Unit, String]

  /// List objects with an optional prefix.  Returns JSON-serialised ListResult.
  pub func list(
    bucketHandle:      Int,
    prefix:            String,
    continuationToken: String,
    maxKeys:           Int
  ): Result[String, String]

  /// Generate a pre-signed URL valid for `expiresInSeconds` seconds.
  pub func presignedUrl(
    bucketHandle:     Int,
    key:              String,
    expiresInSeconds: Int
  ): Result[String, String]

  /// Check whether an object exists.
  pub func exists(bucketHandle: Int, key: String): Result[Bool, String]
}

// ─── Azure Blob Storage provider ─────────────────────────────────────────────

@axiom("Azure Blob Storage SDK for .NET")
@cfg(feature = "azureblob")
extern package Azure.Storage.Blobs {
  /// Open an Azure Blob Storage container client.  Returns an opaque bucket handle.
  pub func connect(connectionString: String, containerName: String): Result[Int, String]

  /// Upload a blob.  Returns JSON-serialised StorageMetadata on success.
  pub func put(
    bucketHandle: Int,
    key:          String,
    dataBase64:   String,
    contentType:  String,
    userMetaJson: String
  ): Result[String, String]

  /// Download a blob.  Returns JSON-serialised StorageObject on success.
  pub func get(bucketHandle: Int, key: String): Result[String, String]

  /// Delete a blob.
  pub func delete(bucketHandle: Int, key: String): Result[Unit, String]

  /// List blobs with an optional prefix.  Returns JSON-serialised ListResult.
  pub func list(
    bucketHandle:      Int,
    prefix:            String,
    continuationToken: String,
    maxKeys:           Int
  ): Result[String, String]

  /// Generate a SAS URL valid for `expiresInSeconds` seconds.
  pub func presignedUrl(
    bucketHandle:     Int,
    key:              String,
    expiresInSeconds: Int
  ): Result[String, String]

  /// Check whether a blob exists.
  pub func exists(bucketHandle: Int, key: String): Result[Bool, String]
}

// ─── Local filesystem provider ────────────────────────────────────────────────

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
extern package System.IO.Storage {
  /// Open a local filesystem store rooted at basePath/bucketName.
  pub func connect(basePath: String, bucketName: String): Result[Int, String]

  /// Write a file.  Returns JSON-serialised StorageMetadata on success.
  pub func put(
    bucketHandle: Int,
    key:          String,
    dataBase64:   String,
    contentType:  String,
    userMetaJson: String
  ): Result[String, String]

  /// Read a file.  Returns JSON-serialised StorageObject on success.
  pub func get(bucketHandle: Int, key: String): Result[String, String]

  /// Delete a file.
  pub func delete(bucketHandle: Int, key: String): Result[Unit, String]

  /// List files with an optional prefix.  Returns JSON-serialised ListResult.
  pub func list(
    bucketHandle:      Int,
    prefix:            String,
    continuationToken: String,
    maxKeys:           Int
  ): Result[String, String]

  /// Return a file:// URL; expiresInSeconds is ignored for local storage.
  pub func presignedUrl(
    bucketHandle:     Int,
    key:              String,
    expiresInSeconds: Int
  ): Result[String, String]

  /// Check whether a file exists.
  pub func exists(bucketHandle: Int, key: String): Result[Bool, String]
}

// ─── Audit logging ────────────────────────────────────────────────────────────

@axiom("Audit logging via System.Diagnostics")
extern package System.Diagnostics.Audit {
  /// Emit a structured audit log entry for a storage operation.
  pub func auditLog(operation: String, level: String, detail: String): Unit
}

// ─── Re-exports with `in` mode ────────────────────────────────────────────────

/// Connect to an Amazon S3 bucket.
@cfg(feature = "s3")
pub func connectS3(
  region:      in String,
  bucket:      in String,
  accessKey:   in String,
  secretKey:   in String,
  endpointUrl: in String
): Result[Int, String] {
  AWSSDK.S3.connect(region, bucket, accessKey, secretKey, endpointUrl)
}

/// Connect to an Azure Blob Storage container.
@cfg(feature = "azureblob")
pub func connectAzure(
  connectionString: in String,
  containerName:    in String
): Result[Int, String] {
  Azure.Storage.Blobs.connect(connectionString, containerName)
}

/// Connect to a local filesystem storage store.
@cfg(feature = "local")
pub func connectLocal(basePath: in String, bucketName: in String): Result[Int, String] {
  System.IO.Storage.connect(basePath, bucketName)
}

/// Upload an object to the provider identified by `bucketHandle`.
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
  @cfg(feature = "local")     return System.IO.Storage.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
}

/// Download an object.
pub func get(bucketHandle: in Int, key: in String): Result[String, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.get(bucketHandle, key)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.get(bucketHandle, key)
  @cfg(feature = "local")     return System.IO.Storage.get(bucketHandle, key)
}

/// Delete an object.
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.delete(bucketHandle, key)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.delete(bucketHandle, key)
  @cfg(feature = "local")     return System.IO.Storage.delete(bucketHandle, key)
}

/// List objects.
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.list(bucketHandle, prefix, continuationToken, maxKeys)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.list(bucketHandle, prefix, continuationToken, maxKeys)
  @cfg(feature = "local")     return System.IO.Storage.list(bucketHandle, prefix, continuationToken, maxKeys)
}

/// Generate a pre-signed or SAS URL.
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.presignedUrl(bucketHandle, key, expiresInSeconds)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.presignedUrl(bucketHandle, key, expiresInSeconds)
  @cfg(feature = "local")     return System.IO.Storage.presignedUrl(bucketHandle, key, expiresInSeconds)
}

/// Check whether an object exists.
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] {
  @cfg(feature = "s3")        return AWSSDK.S3.exists(bucketHandle, key)
  @cfg(feature = "azureblob") return Azure.Storage.Blobs.exists(bucketHandle, key)
  @cfg(feature = "local")     return System.IO.Storage.exists(bucketHandle, key)
}

/// Emit an audit log entry.
pub func auditLog(operation: in String, level: in String, detail: in String): Unit {
  System.Diagnostics.Audit.auditLog(operation, level, detail)
}
