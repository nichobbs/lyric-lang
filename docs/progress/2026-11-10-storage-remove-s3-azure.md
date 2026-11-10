# lyric-storage: remove the unimplemented S3 and Azure Blob backends (D552)

`connectS3` and `connectAzureBlob` never constructed a backend: after their
argument checks both returned `Err(StorageError(code = "NOT_IMPLEMENTED"))` on
every target (no `S3Bucket`/`AzureBucket` records, no extern bindings, no
`s3`/`azureblob` features or NuGet/Maven entries remained in `lyric.toml`).
They are removed from `Storage`, together with the four tests that only
asserted their argument rejection, and the README, `storage.l` header, kernel
headers, book chapter 29, docs/57 and the CLAUDE.md entry now describe the
local filesystem as the only backend. The README carries the migration note:
use `connectLocal` or implement `StorageBucket`, and delete any
`s3`/`azureblob` feature forwarding from an application manifest.

The local filesystem backend, both `host*` kernels and the `StorageBucket`
interface are unchanged. The `stability` manifest field is owned elsewhere
and was not edited.
