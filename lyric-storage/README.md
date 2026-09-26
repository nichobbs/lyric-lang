# lyric-storage

Object and file storage with pluggable backend support.

## Platform parity

**Only the local filesystem backend is production-ready today, on both
targets.** `connectS3()` and `connectAzureBlob()` compile and type-check
on both `dotnet` and `jvm`, but every operation on the returned bucket
returns `Err(StorageError(code = "NOT_IMPLEMENTED"))` — they are not
stubs limited to one target, they simply have no working backend yet on
either. See `docs/57-stdlib-ecosystem-library-review.md` §3.

| Feature flag | Backend                                                              | Status                                  |
|--------------|----------------------------------------------------------------------|------------------------------------------|
| `dotnet`     | Local filesystem                                                      | Available                               |
| `dotnet`     | AWS SDK for .NET (S3), Azure Blob SDK                                | `NOT_IMPLEMENTED` — native bindings pending |
| `jvm`        | Local filesystem                                                      | Available                               |
| `jvm`        | AWS SDK for Java v2 (S3), Azure Blob SDK for Java                    | `NOT_IMPLEMENTED` — native bindings pending |

The JVM kernel (`Storage.Kernel.Jvm`) declares S3 / Azure Blob
bindings against `software.amazon.awssdk:s3` and
`com.azure:azure-storage-blob`, plus `lyric.storage.*` helpers; the
JVM helpers are supplied by the Lyric JVM stdlib JAR (out-of-repo).
Until that JAR ships, only the `dotnet` feature produces a runnable
artifact — and even there, only the local-filesystem path is real; S3
and Azure Blob need direct `extern type` bindings against their
respective SDKs before they do anything but return
`NOT_IMPLEMENTED` (see D056 below).

## Packages

| Package | Purpose |
|---|---|
| `Storage` | Core types, `StorageBucket` interface, and public API |
| `Storage.Aspects` | Reusable aspect templates: `AuditAccess` and `ValidateKey` |

## Quick start

```lyric
import Storage

val bucket = Storage.connectS3({
  region: "us-east-1",
  bucket: "my-data",
  accessKey: "AKIA...",
  secretKey: "..."
})

// Upload a file
Storage.put(bucket, "path/to/file.txt", "Hello, world!")

// Download a file
match Storage.get(bucket, "path/to/file.txt") {
  case Some(data) -> println(data)
  case None -> println("not found")
}

// List objects
val result = Storage.list(bucket, "path/")
for entry in result.entries {
  println(entry.key)
}

// Check existence
if Storage.exists(bucket, "path/to/file.txt") {
  println("file exists")
}
```

## Supported backends

Feature-gate the backend you need in `lyric.toml`:

```toml
[features]
storage = ["s3"]  # or "azureblob", "local"
```

- `s3` — Amazon S3 (`NOT_IMPLEMENTED` — see "Platform parity" above)
- `azureblob` — Azure Blob Storage (`NOT_IMPLEMENTED` — see "Platform parity" above)
- `local` — Local filesystem (production-ready)

## Core types and functions

### StorageBucket interface

```lyric
pub interface StorageBucket {
  func put(key: in String, data: in String): Result[Unit, StorageError]
  func get(key: in String): Result[Option[String], StorageError]
  func delete(key: in String): Result[Unit, StorageError]
  func list(prefix: in String): Result[ListResult, StorageError]
  func presignedUrl(key: in String, expiresInSeconds: in Int): Result[String, StorageError]
  func exists(key: in String): Result[Bool, StorageError]
}
```

### ListResult and ListEntry types

```lyric
pub record ListResult {
  entries: slice[ListEntry]
  continuationToken: Option[String]
}

pub record ListEntry {
  key: String
  size: Long
  lastModified: Instant
  etag: Option[String]
}
```

### StorageObject type

```lyric
pub record StorageObject {
  key: String
  data: String
  metadata: StorageMetadata
}

pub record StorageMetadata {
  contentType: String
  contentLength: Long
  lastModified: Instant
  etag: String
}
```

### Factory and core functions

```lyric
Storage.connectS3(config: in S3Config)
  -> Result[StorageBucket, StorageError]

Storage.connectAzureBlob(config: in AzureBlobConfig)
  -> Result[StorageBucket, StorageError]

Storage.connectLocal(rootPath: in String)
  -> Result[StorageBucket, StorageError]

Storage.put(bucket: in StorageBucket, key: in String, data: in String)
  -> Result[Unit, StorageError]

Storage.get(bucket: in StorageBucket, key: in String)
  -> Result[Option[String], StorageError]

Storage.delete(bucket: in StorageBucket, key: in String)
  -> Result[Unit, StorageError]

Storage.list(bucket: in StorageBucket, prefix: in String)
  -> Result[ListResult, StorageError]

Storage.presignedUrl(bucket: in StorageBucket, key: in String, expiresInSeconds: in Int)
  -> Result[String, StorageError]

Storage.exists(bucket: in StorageBucket, key: in String)
  -> Result[Bool, StorageError]
```

## Configuration

### S3

Config for `Storage.connectS3()`:

```lyric
pub record S3Config {
  region: String
  bucket: String
  accessKey: String
  secretKey: String
  endpoint: Option[String]
}
```

Environment variable defaults (env prefix `LYRIC_CONFIG_STORAGE_S3_`):

| Env var | Default | Meaning |
|---|---|---|
| `REGION` | `us-east-1` | AWS region |
| `BUCKET` | `""` | S3 bucket name |
| `ACCESSKEY` | `""` | AWS Access Key ID |
| `SECRETKEY` | `""` | AWS Secret Access Key |
| `ENDPOINT` | `""` | Custom S3 endpoint (optional) |

### Azure Blob

Config for `Storage.connectAzureBlob()`:

```lyric
pub record AzureBlobConfig {
  accountName: String
  containerName: String
  accountKey: String
}
```

Environment variable defaults (env prefix `LYRIC_CONFIG_STORAGE_AZUREBLOB_`):

| Env var | Default | Meaning |
|---|---|---|
| `ACCOUNTNAME` | `""` | Storage account name |
| `CONTAINERNAME` | `""` | Container name |
| `ACCOUNTKEY` | `""` | Storage account key |

### Local Filesystem

`Storage.connectLocal(rootPath)` uses a local directory as the storage root.
Every backend checks each key with `Storage.isSafeKey` and returns
`Err(StorageError(code = "INVALID_KEY"))` for a rejected one: empty keys,
control characters, absolute keys, `..`, `.` and empty path segments
(including percent-encoded forms), double-encoded `%25` payloads,
`.meta.json` sidecar names, and names Windows would not store as written: a
segment ending in `.` or a space, a device name (`CON`, `NUL`, `COM1`,
`lpt2.txt`), and `:` (an NTFS alternate data stream). The `ValidateKey` aspect applies the same check
earlier, before a handler runs.

## Aspect templates (`Storage.Aspects`)

### AuditAccess

Logs each matched call through `Std.Log`, before the call and again with
its outcome (`:ok`, or `:err` at warn level with the error message). Each
line carries `audit=storage` and the operation name as structured fields;
keys and object data are not logged.

```lyric
import Storage.Aspects

aspect LogAllAccess from Storage.Aspects.AuditAccess {
  matches: name like "*Bucket"
  config { logLevel: String = "info" }
}
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `logLevel` | `String` | `"info"` | Log level for the before and `:ok` lines: `info`, `debug` or `warn`, in any case |

### ValidateKey

Rejects any key `Storage.isSafeKey` rejects (see Local Filesystem above)
with `Err(StorageError(code = "INVALID_KEY"))` before the handler runs. The
handler must take a `key: String` parameter and return
`Result[T, StorageError]`.

```lyric
import Storage.Aspects

aspect GuardPaths from Storage.Aspects.ValidateKey {
  matches: name like "*Bucket"
}
```

`ValidateKey` has no configuration fields. Aspect config is settable from the
environment (`LYRIC_ASPECT_<INSTANTIATION>_<FIELD>`), so any switch would let
whoever controls the environment turn the traversal check off; the former
`allowDots` field and `enabled` master switch were removed for that reason.
An instantiation that still sets `enabled` fails to build; delete the
setting, or the instantiation if the check is really unwanted.

## Decision log

See `docs/03-decision-log.md` D057.
