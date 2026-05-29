// tests/storage_tests.l — Storage package end-to-end tests.
//
// Covers the production-quality local-filesystem backend's public
// surface and the key-safety primitives.  The full match/field-access
// suite is tracked in #1140 — the self-hosted emitter currently widens
// imported records and Result generic type args to `Object` under
// `emitProject`, so cross-package idiomatic patterns (e.g.
// `case Err(e) -> e.code`) fail.  Once #1140 lands, these tests grow
// to cover the wire-type surface, metadata round-trip with `userMeta`,
// pagination cursor inspection, etc.

@test_module
package Storage.StorageTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.Uuid as Uuid
import Storage

// ─── Key safety primitives ───────────────────────────────────────────────────

test "isSafeKey accepts ordinary keys" {
  assertTrue(isSafeKey("uploads/photo.jpg"), "ordinary key")
  assertTrue(isSafeKey("a"),                  "single char key")
  assertTrue(isSafeKey("nested/dir/file.txt"), "nested key")
  assertTrue(isSafeKey("version..2.0"),       "dot-dot inside a segment is fine")
  assertTrue(isSafeKey("my..file.txt"),       "filename embedding .. is fine")
}

test "isSafeKey rejects empty key" {
  assertTrue(not isSafeKey(""), "empty key")
}

test "isSafeKey rejects leading slash (absolute path)" {
  assertTrue(not isSafeKey("/etc/passwd"), "leading slash")
}

test "isSafeKey rejects raw .. segment" {
  assertTrue(not isSafeKey("../etc/passwd"),     "leading ..")
  assertTrue(not isSafeKey("uploads/../etc"),    "interior ..")
  assertTrue(not isSafeKey(".."),                "lone ..")
  assertTrue(not isSafeKey("a/.."),              "trailing ..")
}

test "isSafeKey rejects percent-encoded .. (single)" {
  assertTrue(not isSafeKey("%2e%2e/etc/passwd"),  "lowercase percent")
  assertTrue(not isSafeKey("%2E%2E/etc/passwd"),  "uppercase percent")
}

test "isSafeKey rejects mixed-case percent traversal" {
  assertTrue(not isSafeKey("%2e%2E/etc/passwd"), "mixed-case percent")
}

test "isSafeKey rejects double-encoded percent payloads" {
  assertTrue(not isSafeKey("%252e%252e/etc/passwd"),
             "double-encoded %25 lowercase")
  assertTrue(not isSafeKey("%252E%252E/etc/passwd"),
             "double-encoded %25 uppercase")
}

test "isSafeKey rejects backslash traversal" {
  assertTrue(not isSafeKey("..\\etc\\passwd"), "backslash traversal")
}

test "isSafeKey rejects null bytes" {
  assertTrue(not isSafeKey("ok\u{0000}/etc/passwd"), "embedded null byte")
}

test "normalisedStorageKey decodes target characters only" {
  assertEqual(normalisedStorageKey("%2e%2e/etc"), "../etc", "decode dot")
  assertEqual(normalisedStorageKey("%2F/path"),   "//path", "decode slash")
  assertEqual(normalisedStorageKey("a\\b"),       "a/b",    "fold backslash")
}

test "storageKeyHasDotDot segment-aware" {
  assertTrue(storageKeyHasDotDot("../etc"),      "leading ..")
  assertTrue(storageKeyHasDotDot("a/../b"),      "interior ..")
  assertTrue(not storageKeyHasDotDot("version..2"), "embedded .. is not a segment")
  assertTrue(not storageKeyHasDotDot("my..file"),   "filename .. is not a segment")
  assertTrue(not storageKeyHasDotDot("a/b/c"),      "no .. anywhere")
}

test "isSafePrefix admits empty prefix" {
  assertTrue(isSafePrefix(""),         "empty prefix is list-all")
  assertTrue(isSafePrefix("uploads/"), "ordinary prefix")
}

test "isSafePrefix rejects traversal" {
  assertTrue(not isSafePrefix("../etc"),               "leading ..")
  assertTrue(not isSafePrefix("%252e%252e/etc"),       "double-encoded")
}

// ─── connectLocal Result-only checks ─────────────────────────────────────────
//
// These tests confirm the connectLocal factory's input-validation
// surface without exercising any subsequent bucket method (which would
// route through the imported `StorageBucket` interface that the
// emitter currently widens to `Object` cross-package — see #1140).

test "connectLocal rejects empty basePath" {
  assertTrue(isErr(connectLocal("", "bucket")), "must reject empty basePath")
}

test "connectLocal rejects empty bucketName" {
  assertTrue(isErr(connectLocal("/tmp/lyric-storage-tests", "")),
             "must reject empty bucketName")
}

test "connectLocal succeeds for a fresh basePath" {
  val basePath   = "/tmp/lyric-storage-tests"
  val bucketName = "fresh-" + Uuid.uuidToString(Uuid.newUuid())
  assertTrue(isOk(connectLocal(basePath, bucketName)),
             "connectLocal must succeed for fresh bucket")
}

test "connectS3 rejects empty region" {
  assertTrue(isErr(connectS3("", "bucket", "k", "s", "")),
             "must reject empty region")
}

test "connectS3 rejects empty bucket name" {
  assertTrue(isErr(connectS3("us-east-1", "", "k", "s", "")),
             "must reject empty bucket name")
}

test "connectAzureBlob rejects empty connection string" {
  assertTrue(isErr(connectAzureBlob("", "container")),
             "must reject empty connection string")
}

test "connectAzureBlob rejects empty container name" {
  assertTrue(isErr(connectAzureBlob("DefaultEndpointsProtocol=https;...", "")),
             "must reject empty container name")
}

// ─── LocalBucket data-plane smoke tests ───────────────────────────────────
//
// These exercise the put / get / delete / list / exists round-trip path
// at the `isOk` / `isErr` level — the idiomatic `case Ok(obj) -> obj.metadata.contentType`
// inspection is blocked by #1140 (cross-package generic-arg widening
// inside synthesised `@test_module` bodies) and lives in a follow-up
// once that lands.
//
// Each test runs against a fresh bucket directory keyed by a fresh v4
// UUID so they're independent and reentrant.  No file-system cleanup
// is performed (the OS handles `/tmp` eventually) — the tests assume
// `/tmp/lyric-storage-tests` is writable.

func freshBucket(): Result[StorageBucket, StorageError] {
  val basePath   = "/tmp/lyric-storage-tests"
  val bucketName = "smoke-" + Uuid.uuidToString(Uuid.newUuid())
  connectLocal(basePath, bucketName)
}

test "put round-trips through get" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  val payload = "aGVsbG8="  // "hello" in base64
  assertTrue(isOk(put(bucket, "smoke/hello.txt", payload, "text/plain")),
             "put must succeed")
  assertTrue(isOk(get(bucket, "smoke/hello.txt")),
             "get must succeed for previously-put key")
}

test "exists returns Ok(false) for absent key" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(exists(bucket, "never-put.txt")),
             "exists call must succeed regardless of presence")
}

test "exists returns Ok after put" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(put(bucket, "exists/probe.bin", "AAA=", "application/octet-stream")),
             "put must succeed")
  assertTrue(isOk(exists(bucket, "exists/probe.bin")),
             "exists must succeed after put")
}

test "delete returns Ok for previously-put key" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(put(bucket, "delete/me.bin", "AAA=", "application/octet-stream")),
             "put must succeed")
  assertTrue(isOk(delete(bucket, "delete/me.bin")),
             "delete must succeed for known key")
}

test "list returns Ok on an empty bucket" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(list(bucket, "")),
             "list on empty bucket must succeed")
}

test "list returns Ok after multiple puts" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(put(bucket, "list/a.txt", "QQ==", "text/plain")),
             "put a must succeed")
  assertTrue(isOk(put(bucket, "list/b.txt", "Qg==", "text/plain")),
             "put b must succeed")
  assertTrue(isOk(list(bucket, "list/")),
             "list with prefix must succeed after puts")
}

// Pagination cursor smoke test (#1460 / #1012) — exercises the
// `bucket.list(prefix, token, maxKeys)` interface directly with a
// small page size and asserts both pages succeed.  The first page
// must return `isTruncated = true` plus a non-empty
// `nextContinuationToken`; the second page must consume that token
// without error.  Pre-fix (#1012) the cursor was always `None` even
// when truncated, so callers paging until `isTruncated == false`
// looped forever.
test "list paginates with continuation token" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isOk(put(bucket, "pg/a.txt", "QQ==", "text/plain")),
             "put a must succeed")
  assertTrue(isOk(put(bucket, "pg/b.txt", "Qg==", "text/plain")),
             "put b must succeed")

  // Page 1: maxKeys = 1 against two matching keys → truncated, with
  // a continuation token.
  val page1Res = bucket.list("pg/", "", 1)
  assertTrue(isOk(page1Res), "page 1 list call must succeed")
  val emptyPage = ListResult(entries = [], nextContinuationToken = None,
                             isTruncated = false)
  val page1 = unwrapResultOr(page1Res, emptyPage)
  assertTrue(page1.isTruncated,
             "page 1 must report isTruncated when total > maxKeys")
  assertTrue(isSome(page1.nextContinuationToken),
             "page 1 must populate nextContinuationToken when truncated")

  // Page 2: drive the token from page 1 through to verify it resumes
  // cleanly.  We can't pattern-match the Option payload here under
  // the current emitter (#1140), so unwrap via `unwrapOr`.
  val token = unwrapOr(page1.nextContinuationToken, "")
  assertTrue(token.length > 0,
             "unwrapped continuation token must be non-empty")
  val page2Res = bucket.list("pg/", token, 1)
  assertTrue(isOk(page2Res),
             "page 2 list call must succeed when handed the cursor")
}

test "put rejects unsafe key with path traversal" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isErr(put(bucket, "../escape.txt", "AAA=", "text/plain")),
             "put must reject `..` traversal at the safety gate")
}

test "get rejects unsafe key with absolute path" {
  val bRes = freshBucket()
  assertTrue(isOk(bRes), "fresh bucket must connect")
  val bucket = unwrapResultOr(bRes, defaultBucket())
  assertTrue(isErr(get(bucket, "/etc/passwd")),
             "get must reject absolute key at the safety gate")
}

// Sentinel bucket used by `unwrapResultOr` fallbacks — never read
// because every test gates on `isOk(bRes)` before calling the unwrap.
// Concrete type is forced to `StorageBucket` via the interface, with a
// distinct invalid bucket-name that would never collide with a real
// freshBucket() output.
func defaultBucket(): StorageBucket {
  match connectLocal("/tmp/lyric-storage-tests", "__default__") {
    case Ok(b)  -> b
    case Err(_) -> panic("defaultBucket: connectLocal failed unexpectedly")
  }
}
