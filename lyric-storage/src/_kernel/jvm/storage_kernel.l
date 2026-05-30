//! Storage.Kernel.Jvm — JVM extern boundary for object/file storage providers.
//!
//! JVM implementation of the same contract as Storage.Kernel.Net.  All operations
//! resolve through provider-specific JVM libraries:
//!   software.amazon.awssdk:s3       — Amazon S3               (@cfg feature = "s3")
//!   com.azure:azure-storage-blob    — Azure Blob Storage       (@cfg feature = "azureblob")
//!   lyric.storage.LocalFs           — Local filesystem         (@cfg feature = "local")
//!
//! JSON wire formats are identical to the .NET kernel — the public `Storage`
//! package consumes either kernel without re-shaping.
//!
//! All storage operations use opaque Int handles returned by `connect*`.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Storage.Kernel.Jvm

// ─── Amazon S3 provider ───────────────────────────────────────────────────────

@axiom("AWS SDK for Java v2 — software.amazon.awssdk.services.s3.S3Client")
@cfg(feature = "s3")
extern package software.amazon.awssdk.services.s3.S3Client {
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

@axiom("Azure Storage Blob SDK for Java — com.azure.storage.blob.BlobServiceClient")
@cfg(feature = "azureblob")
extern package com.azure.storage.blob.BlobServiceClient {
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

@axiom("Local filesystem storage using java.nio.file.Files via lyric.storage.LocalFs")
@cfg(feature = "local")
extern package lyric.storage.LocalFs {
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

@axiom("Audit logging via java.util.logging")
extern package lyric.storage.Audit {
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
  software.amazon.awssdk.services.s3.S3Client.connect(region, bucket, accessKey, secretKey, endpointUrl)
}

/// Connect to an Azure Blob Storage container.
@cfg(feature = "azureblob")
pub func connectAzure(
  connectionString: in String,
  containerName:    in String
): Result[Int, String] {
  com.azure.storage.blob.BlobServiceClient.connect(connectionString, containerName)
}

/// Connect to a local filesystem storage store.
@cfg(feature = "local")
pub func connectLocal(basePath: in String, bucketName: in String): Result[Int, String] {
  lyric.storage.LocalFs.connect(basePath, bucketName)
}

/// Upload an object to the S3 bucket identified by `bucketHandle`.
@cfg(feature = "s3")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] {
  return software.amazon.awssdk.services.s3.S3Client.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
}

/// Upload an object to the Azure Blob container identified by `bucketHandle`.
@cfg(feature = "azureblob")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] {
  return com.azure.storage.blob.BlobServiceClient.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
}

/// Upload an object to the local filesystem store identified by `bucketHandle`.
@cfg(feature = "local")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] {
  return lyric.storage.LocalFs.put(bucketHandle, key, dataBase64, contentType, userMetaJson)
}

/// Download an object from the S3 bucket.
@cfg(feature = "s3")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] {
  return software.amazon.awssdk.services.s3.S3Client.get(bucketHandle, key)
}

/// Download an object from the Azure Blob container.
@cfg(feature = "azureblob")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] {
  return com.azure.storage.blob.BlobServiceClient.get(bucketHandle, key)
}

/// Download an object from the local filesystem store.
@cfg(feature = "local")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] {
  return lyric.storage.LocalFs.get(bucketHandle, key)
}

/// Delete an object from the S3 bucket.
@cfg(feature = "s3")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] {
  return software.amazon.awssdk.services.s3.S3Client.delete(bucketHandle, key)
}

/// Delete an object from the Azure Blob container.
@cfg(feature = "azureblob")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] {
  return com.azure.storage.blob.BlobServiceClient.delete(bucketHandle, key)
}

/// Delete an object from the local filesystem store.
@cfg(feature = "local")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] {
  return lyric.storage.LocalFs.delete(bucketHandle, key)
}

/// List objects in the S3 bucket.
@cfg(feature = "s3")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] {
  return software.amazon.awssdk.services.s3.S3Client.list(bucketHandle, prefix, continuationToken, maxKeys)
}

/// List objects in the Azure Blob container.
@cfg(feature = "azureblob")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] {
  return com.azure.storage.blob.BlobServiceClient.list(bucketHandle, prefix, continuationToken, maxKeys)
}

/// List objects in the local filesystem store.
@cfg(feature = "local")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] {
  return lyric.storage.LocalFs.list(bucketHandle, prefix, continuationToken, maxKeys)
}

/// Generate a pre-signed URL for the S3 bucket.
@cfg(feature = "s3")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] {
  return software.amazon.awssdk.services.s3.S3Client.presignedUrl(bucketHandle, key, expiresInSeconds)
}

/// Generate a SAS URL for the Azure Blob container.
@cfg(feature = "azureblob")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] {
  return com.azure.storage.blob.BlobServiceClient.presignedUrl(bucketHandle, key, expiresInSeconds)
}

/// Return a file:// URL for the local filesystem object.
@cfg(feature = "local")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] {
  return lyric.storage.LocalFs.presignedUrl(bucketHandle, key, expiresInSeconds)
}

/// Check whether an object exists in the S3 bucket.
@cfg(feature = "s3")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] {
  return software.amazon.awssdk.services.s3.S3Client.exists(bucketHandle, key)
}

/// Check whether an object exists in the Azure Blob container.
@cfg(feature = "azureblob")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] {
  return com.azure.storage.blob.BlobServiceClient.exists(bucketHandle, key)
}

/// Check whether an object exists in the local filesystem store.
@cfg(feature = "local")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] {
  return lyric.storage.LocalFs.exists(bucketHandle, key)
}

/// Emit an audit log entry.
pub func auditLog(operation: in String, level: in String, detail: in String): Unit {
  lyric.storage.Audit.auditLog(operation, level, detail)
}
