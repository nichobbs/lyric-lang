/// Lyric.Storage.Host — .NET host shim for the lyric-storage kernel.
///
/// Phase 2 of #733: local-filesystem backend only.  S3 (AWSSDK.S3) and
/// Azure Blob (Azure.Storage.Blobs) shims are tracked under #782 as
/// separate phases — adding them needs an external blob store
/// (LocalStack / Azurite) for the Testcontainers regression test, while
/// the local backend stays self-contained.
///
/// The kernel file `lyric-storage/src/storage.l` declares each entry
/// point with `@externTarget("Lyric.Storage.LocalHost.<method>")`; the
/// emitter resolves those references to the static methods below at
/// codegen time.
///
/// Result-shape contract (matches lyric-session/Lyric.Session.RedisStore):
///   - All methods translate exceptions into `Result<T, string> =
///     Error(msg)` so failures never escape the Lyric `Result[T,
///     String]` boundary.
///   - `int` storeHandle is an opaque key into the per-process
///     `LocalBackend.handles` ConcurrentDictionary.
///   - Data-plane functions (`storagePut`/`storageGet`/...) reject
///     handles registered by future S3 / Azure connect functions with
///     a clear "provider not yet implemented" error rather than
///     silently no-oping.
///
/// JSON wire format (mirrors the kernel's documented contract):
///   put returns:  {"contentType":"...","contentLength":N,"etag":"...","lastModified":"...","userMeta":{...}}
///   get returns:  {"bucket":"...","key":"...","metadata":{...},"dataBase64":"..."}
///   list returns: {"entries":[...],"nextContinuationToken":null,"isTruncated":false}

namespace Lyric.Storage

open System
open System.Collections.Concurrent
open System.IO
open System.Text
open System.Threading

/// Per-handle backend tag.  Phase 2 only fills `Local`; later phases
/// add S3/Azure constructors.
type private Backend =
    | Local of basePath:string * bucketName:string

type private StorageHandle =
    { Backend: Backend }

/// Internal registry shared by `LocalHost.storageConnectLocal` and the
/// data-plane dispatchers.  Per-process scope; not survivable across
/// AppDomain unloads (matches StackExchange.Redis's connection pool).
module private Registry =
    let handles : ConcurrentDictionary<int, StorageHandle> =
        ConcurrentDictionary<int, StorageHandle>()
    let nextHandle : int ref = ref 0
    let register (b: Backend) : int =
        let h = Interlocked.Increment(nextHandle)
        handles.[h] <- { Backend = b }
        h
    let lookup (h: int) : Result<StorageHandle, string> =
        match handles.TryGetValue(h) with
        | true, entry -> Ok entry
        | false, _    -> Error (sprintf "unknown bucket handle %d" h)

    /// Wrap `op` so all exceptions are caught and surfaced as `Error msg`.
    let safeCall (op: unit -> 'T) : Result<'T, string> =
        try Ok (op())
        with ex -> Error (sprintf "%s: %s" (ex.GetType().Name) ex.Message)

    /// Sanitise an object key into a safe filesystem path segment.  Refuses
    /// keys that try to escape via `..` segments.  The Lyric-side path-
    /// traversal contract guard (#741) catches this upstream too, but
    /// defence-in-depth at the host boundary matches the JVM kernel's
    /// behaviour.
    let resolveLocalPath (basePath: string) (bucketName: string) (key: string) : Result<string, string> =
        if key.Contains("..") then
            Error "key contains '..' — refusing to traverse outside bucket"
        elif Path.IsPathRooted(key) then
            Error "key must be relative (must not start with '/' or a drive letter)"
        else
            let bucketDir = Path.Combine(basePath, bucketName)
            let full      = Path.Combine(bucketDir, key)
            // Canonical form normalises trailing `..` segments that were
            // smuggled past the substring check (e.g. "a/..").
            let canonical = Path.GetFullPath(full)
            let canonicalBucket = Path.GetFullPath(bucketDir)
            if canonical.StartsWith(canonicalBucket, StringComparison.Ordinal) then
                Ok canonical
            else
                Error "resolved key path escapes bucket directory"

    /// Build the JSON `userMeta` field literally from a JSON object string
    /// the caller already produced.
    let jsonString (s: string) : string =
        let sb = StringBuilder()
        sb.Append('"') |> ignore
        for c in s do
            match c with
            | '\\' -> sb.Append("\\\\") |> ignore
            | '"'  -> sb.Append("\\\"") |> ignore
            | '\n' -> sb.Append("\\n")  |> ignore
            | '\r' -> sb.Append("\\r")  |> ignore
            | '\t' -> sb.Append("\\t")  |> ignore
            | _    -> sb.Append(c)      |> ignore
        sb.Append('"') |> ignore
        sb.ToString()

    /// MD5-style ETag for the file content.
    let computeEtag (bytes: byte[]) : string =
        use md5 = System.Security.Cryptography.MD5.Create()
        let hash = md5.ComputeHash(bytes)
        Convert.ToHexString(hash).ToLowerInvariant()

/// `Lyric.Storage.LocalHost` — the static class the kernel's
/// `@externTarget("Lyric.Storage.LocalHost.<method>")` references
/// resolve to at codegen time.
[<Sealed; AbstractClass>]
type LocalHost private () =

    /// Open a directory-backed bucket.  Creates the bucket directory if
    /// it doesn't exist (matches the local-fs idiom; S3/Azure require
    /// the bucket to exist out-of-band).
    static member storageConnectLocal(basePath: string, bucketName: string) : Result<int, string> =
        if String.IsNullOrEmpty(basePath) then
            Error "Lyric.Storage.LocalHost.storageConnectLocal: basePath must be non-empty"
        elif String.IsNullOrEmpty(bucketName) then
            Error "Lyric.Storage.LocalHost.storageConnectLocal: bucketName must be non-empty"
        else
            Registry.safeCall (fun () ->
                let bucketDir = Path.Combine(basePath, bucketName)
                Directory.CreateDirectory(bucketDir) |> ignore
                Registry.register (Local(basePath, bucketName)))

    /// Upload an object.  `dataBase64` is the base64-encoded object
    /// content; `userMetaJson` is a JSON object the caller pre-built.
    /// Returns JSON-serialised StorageMetadata.
    static member storagePut(bucketHandle: int, key: string, dataBase64: string,
                              contentType: string, userMetaJson: string) : Result<string, string> =
        if String.IsNullOrEmpty(key) then
            Error "Lyric.Storage.LocalHost.storagePut: key must be non-empty"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok entry ->
                match entry.Backend with
                | Local(basePath, bucketName) ->
                    match Registry.resolveLocalPath basePath bucketName key with
                    | Error e -> Error e
                    | Ok fullPath ->
                        Registry.safeCall (fun () ->
                            let parent = Path.GetDirectoryName(fullPath: string)
                            match Option.ofObj parent with
                            | Some p when p.Length > 0 -> Directory.CreateDirectory(p) |> ignore
                            | _ -> ()
                            let bytes = Convert.FromBase64String(dataBase64)
                            File.WriteAllBytes(fullPath, bytes)
                            // Also write the user-metadata sidecar so
                            // `get` can recover it on a later session.
                            File.WriteAllText(fullPath + ".meta.json", userMetaJson)
                            let etag         = Registry.computeEtag bytes
                            let lastModified = File.GetLastWriteTimeUtc(fullPath).ToString("O")
                            sprintf "{\"contentType\":%s,\"contentLength\":%d,\"etag\":%s,\"lastModified\":%s,\"userMeta\":%s}"
                                (Registry.jsonString contentType) bytes.LongLength (Registry.jsonString etag)
                                (Registry.jsonString lastModified)
                                (if String.IsNullOrEmpty(userMetaJson) then "{}" else userMetaJson))

    /// Download an object.  Returns JSON-serialised StorageObject.
    static member storageGet(bucketHandle: int, key: string) : Result<string, string> =
        if String.IsNullOrEmpty(key) then
            Error "Lyric.Storage.LocalHost.storageGet: key must be non-empty"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok entry ->
                match entry.Backend with
                | Local(basePath, bucketName) ->
                    match Registry.resolveLocalPath basePath bucketName key with
                    | Error e -> Error e
                    | Ok fullPath ->
                        if not (File.Exists(fullPath)) then
                            Error (sprintf "key '%s' not found in bucket" key)
                        else
                            Registry.safeCall (fun () ->
                                let bytes = File.ReadAllBytes(fullPath)
                                let metaPath = fullPath + ".meta.json"
                                let userMetaJson =
                                    if File.Exists(metaPath) then File.ReadAllText(metaPath) else "{}"
                                let etag         = Registry.computeEtag bytes
                                let lastModified = File.GetLastWriteTimeUtc(fullPath).ToString("O")
                                let metadata =
                                    sprintf "{\"contentType\":\"application/octet-stream\",\"contentLength\":%d,\"etag\":%s,\"lastModified\":%s,\"userMeta\":%s}"
                                        bytes.LongLength (Registry.jsonString etag) (Registry.jsonString lastModified) userMetaJson
                                let dataBase64 = Convert.ToBase64String(bytes)
                                sprintf "{\"bucket\":%s,\"key\":%s,\"metadata\":%s,\"dataBase64\":%s}"
                                    (Registry.jsonString bucketName) (Registry.jsonString key) metadata (Registry.jsonString dataBase64))

    /// Delete an object.  Idempotent: no error if absent.
    static member storageDelete(bucketHandle: int, key: string) : Result<unit, string> =
        if String.IsNullOrEmpty(key) then
            Error "Lyric.Storage.LocalHost.storageDelete: key must be non-empty"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok entry ->
                match entry.Backend with
                | Local(basePath, bucketName) ->
                    match Registry.resolveLocalPath basePath bucketName key with
                    | Error e -> Error e
                    | Ok fullPath ->
                        Registry.safeCall (fun () ->
                            if File.Exists(fullPath) then File.Delete(fullPath)
                            let metaPath = fullPath + ".meta.json"
                            if File.Exists(metaPath) then File.Delete(metaPath))

    /// List objects under `prefix`.  Returns JSON-serialised ListResult.
    /// `startAfterKey` is the raw key to start listing after (alphabetically);
    /// pass "" to start from the beginning.  Returns the actual last key
    /// as `nextContinuationToken` so callers can page correctly (#1012).
    static member storageList(bucketHandle: int, prefix: string,
                               startAfterKey: string, maxKeys: int) : Result<string, string> =
        if maxKeys < 1 || maxKeys > 1000 then
            Error "Lyric.Storage.LocalHost.storageList: maxKeys must be in [1, 1000]"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok entry ->
                match entry.Backend with
                | Local(basePath, bucketName) ->
                    let bucketDir = Path.Combine(basePath, bucketName)
                    Registry.safeCall (fun () ->
                        if not (Directory.Exists(bucketDir)) then
                            "{\"entries\":[],\"nextContinuationToken\":null,\"isTruncated\":false}"
                        else
                            let allFiles =
                                Directory.GetFiles(bucketDir, "*", SearchOption.AllDirectories)
                                |> Array.filter (fun f -> not (f.EndsWith(".meta.json", StringComparison.Ordinal)))
                                |> Array.map (fun f ->
                                    let rel = Path.GetRelativePath(bucketDir, f)
                                    rel.Replace(Path.DirectorySeparatorChar, '/'))
                                |> Array.filter (fun k -> k.StartsWith(prefix, StringComparison.Ordinal))
                                |> Array.filter (fun k ->
                                    // Skip keys up to and including startAfterKey for pagination.
                                    String.IsNullOrEmpty(startAfterKey) ||
                                    String.Compare(k, startAfterKey, StringComparison.Ordinal) > 0)
                                |> Array.sort
                            let truncated = allFiles.Length > maxKeys
                            let pageKeys  =
                                if truncated then Array.take maxKeys allFiles else allFiles
                            let entries =
                                pageKeys
                                |> Array.map (fun k ->
                                    let full = Path.Combine(bucketDir, k.Replace('/', Path.DirectorySeparatorChar))
                                    let info = FileInfo(full)
                                    let etag = Registry.computeEtag (File.ReadAllBytes(full))
                                    sprintf "{\"key\":%s,\"contentLength\":%d,\"lastModified\":%s,\"etag\":%s}"
                                        (Registry.jsonString k) info.Length
                                        (Registry.jsonString (info.LastWriteTimeUtc.ToString("O")))
                                        (Registry.jsonString etag))
                                |> String.concat ","
                            // Return the actual last key so callers can resume from here.
                            let nextTok =
                                if truncated then Registry.jsonString (Array.last pageKeys)
                                else "null"
                            sprintf "{\"entries\":[%s],\"nextContinuationToken\":%s,\"isTruncated\":%b}"
                                entries nextTok truncated)

    /// Pre-signed URLs are not supported on the local-fs backend —
    /// there's no signing service.  Returns a clear error.
    static member storagePresignedUrl(bucketHandle: int, key: string,
                                       expiresInSeconds: int) : Result<string, string> =
        if String.IsNullOrEmpty(key) then
            Error "Lyric.Storage.LocalHost.storagePresignedUrl: key must be non-empty"
        elif expiresInSeconds < 1 then
            Error "Lyric.Storage.LocalHost.storagePresignedUrl: expiresInSeconds must be >= 1"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok _ ->
                Error "presigned URLs are not supported on the local-fs storage backend"

    /// S3 backend is not yet wired up under the Phase-2 host-shim rollout.
    /// Tracked under #733; returns Err so callers see the gap immediately.
    static member storageConnectS3NotYet(region: string, bucket: string, accessKey: string,
                                          secretKey: string, endpointUrl: string) : Result<int, string> =
        Error "lyric-storage: S3 backend not yet implemented (Phase 2 of #733; track for follow-up)"

    /// Azure Blob backend is not yet wired up under the Phase-2 host-shim
    /// rollout.  Tracked under #733; returns Err so callers see the gap
    /// immediately.
    static member storageConnectAzureNotYet(connectionString: string,
                                             containerName: string) : Result<int, string> =
        Error "lyric-storage: Azure Blob backend not yet implemented (Phase 2 of #733; track for follow-up)"

    /// Return true if the key exists.
    static member storageExists(bucketHandle: int, key: string) : Result<bool, string> =
        if String.IsNullOrEmpty(key) then
            Error "Lyric.Storage.LocalHost.storageExists: key must be non-empty"
        else
            match Registry.lookup bucketHandle with
            | Error e -> Error e
            | Ok entry ->
                match entry.Backend with
                | Local(basePath, bucketName) ->
                    match Registry.resolveLocalPath basePath bucketName key with
                    | Error e -> Error e
                    | Ok fullPath -> Ok (File.Exists(fullPath))
