// Storage.Kernel.Net — extern boundary for object/file storage providers.
//
// Bridges Lyric's Storage package to .NET storage libraries:
//   AWSSDK.S3              — Amazon S3               (@cfg feature = "s3")
//   Azure.Storage.Blobs    — Azure Blob Storage       (@cfg feature = "azureblob")
//   Local filesystem       — Local filesystem         (@cfg feature = "local")
//   Audit logging          — Audit logging            (always available)
//
// All storage operations use opaque Int handles returned by `connect*`.
//
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package Storage.Kernel.Net

// ─── Amazon S3 provider ───────────────────────────────────────────────────────

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func connectS3(
  region:      in String,
  bucket:      in String,
  accessKey:   in String,
  secretKey:   in String,
  endpointUrl: in String
): Result[Int, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] = Err("")

@axiom("Amazon S3 SDK for .NET (AWSSDK.S3)")
@cfg(feature = "s3")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] = Err("")

// ─── Azure Blob Storage provider ─────────────────────────────────────────────

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func connectAzure(
  connectionString: in String,
  containerName:    in String
): Result[Int, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] = Err("")

@axiom("Azure Blob Storage SDK for .NET (Azure.Storage.Blobs)")
@cfg(feature = "azureblob")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] = Err("")

// ─── Local filesystem provider ────────────────────────────────────────────────

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func connectLocal(basePath: in String, bucketName: in String): Result[Int, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func put(
  bucketHandle: in Int,
  key:          in String,
  dataBase64:   in String,
  contentType:  in String,
  userMetaJson: in String
): Result[String, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func get(bucketHandle: in Int, key: in String): Result[String, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func delete(bucketHandle: in Int, key: in String): Result[Unit, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func list(
  bucketHandle:      in Int,
  prefix:            in String,
  continuationToken: in String,
  maxKeys:           in Int
): Result[String, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func presignedUrl(
  bucketHandle:     in Int,
  key:              in String,
  expiresInSeconds: in Int
): Result[String, String] = Err("")

@axiom("Local filesystem storage using System.IO")
@cfg(feature = "local")
pub func exists(bucketHandle: in Int, key: in String): Result[Bool, String] = Err("")

// ─── Audit logging ────────────────────────────────────────────────────────────

@axiom("Audit logging via System.Diagnostics")
pub func auditLog(operation: in String, level: in String, detail: in String): Unit = ()
