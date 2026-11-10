# lyric-storage

**Stability:** `incomplete`

Object and file storage with pluggable backend support.

## Platform parity

The local filesystem backend is the only backend, and it is production-ready
on both targets: `dotnet` through `Storage.Kernel.Net` and `jvm` through
`Storage.Kernel.Jvm`, which needs nothing beyond `java.base`. There are no
placeholder backends: every backend this library exposes works.

| Feature flag | Backend          | Status    |
|--------------|------------------|-----------|
| `dotnet`     | Local filesystem | Available |
| `jvm`        | Local filesystem | Available |

Select exactly one flag, matching `--target` (`--target jvm
--no-default-features --features jvm`).

## Migration: S3 and Azure Blob removed

`connectS3` and `connectAzureBlob` were removed (docs/decisions/D552, docs/71).
They only ever returned `Err(StorageError(code = "NOT_IMPLEMENTED"))`, so code
that called them could never have run against a real bucket; calls now fail to
compile instead of failing at run time. Replace them with `connectLocal`, or
implement `StorageBucket` for the remote store in your own package.

The `s3` and `azureblob` feature flags, and the AWS and Azure NuGet or Maven
entries that went with them, no longer mean anything. They had already been
dropped from this library's own `lyric.toml`, so only an application that
forwarded them (for example `storage = ["s3"]` in its own `[features]`)
needs a change: delete those entries.

## Packages

| Package | Purpose |
|---|---|
| `Storage` | Core types, `StorageBucket` interface, and public API |
| `Storage.Aspects` | Reusable aspect templates: `AuditAccess` and `ValidateKey` |

## Quick start

```lyric
import Storage

val bucket = Storage.connectLocal("/var/data", "uploads")?

// Upload a file
Storage.put(bucket, "path/to/file.txt", base64Data, "text/plain")?

// Download a file
match Storage.get(bucket, "path/to/file.txt") {
  case Ok(obj) -> println(obj.metadata.contentType)
  case Err(e)  -> println(e.message)
}

// List objects
val listing = Storage.list(bucket, "path/")?
for entry in listing.entries {
  println(entry.key)
}
```

## Supported backends

- `local` - local filesystem (production-ready on `dotnet` and `jvm`)

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
Storage.connectLocal(basePath: in String, bucketName: in String)
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

### Local Filesystem

`Storage.connectLocal(basePath, bucketName)` uses `basePath/bucketName` as the storage root, creating it if missing.
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
