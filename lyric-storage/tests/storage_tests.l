// tests/storage_tests.l — unit tests for the Storage package's pure wire-type
// surface.  Covers StorageError, StorageMetadata, StorageObject, ListEntry, and
// ListResult construction and field access without touching any kernel backends.

@test_module
package Storage.StorageTests

import Std.Core
import Std.Testing
import Std.Collections
import Storage

// ─── StorageError ─────────────────────────────────────────────────────────────

test "StorageError construction and field access" {
  val e = Storage.StorageError(message = "object not found", code = "NOT_FOUND")
  assertEqual(e.message, "object not found", "error message")
  assertEqual(e.code,    "NOT_FOUND",        "error code")
}

test "StorageError with NOT_FOUND code" {
  val e = Storage.StorageError(message = "key does not exist", code = "NOT_FOUND")
  assertEqual(e.code, "NOT_FOUND", "NOT_FOUND code constant")
}

test "StorageError with ACCESS_DENIED code" {
  val e = Storage.StorageError(message = "permission denied", code = "ACCESS_DENIED")
  assertEqual(e.code, "ACCESS_DENIED", "ACCESS_DENIED code constant")
}

// ─── StorageMetadata ─────────────────────────────────────────────────────────

test "StorageMetadata construction with empty userMeta" {
  val meta = Storage.StorageMetadata(
    contentType   = "text/plain",
    contentLength = 42,
    etag          = "abc123",
    lastModified  = "2024-01-01T00:00:00Z",
    userMeta      = Map.empty())
  assertEqual(meta.contentType,  "text/plain",          "contentType")
  assertEqual(meta.etag,         "abc123",              "etag")
  assertEqual(meta.lastModified, "2024-01-01T00:00:00Z", "lastModified")
  assertEqualInt(meta.contentLength.toInt(), 42, "contentLength")
}

test "StorageMetadata.contentLength is Long — zero value" {
  val meta = Storage.StorageMetadata(
    contentType   = "application/octet-stream",
    contentLength = 0,
    etag          = "",
    lastModified  = "",
    userMeta      = Map.empty())
  assertEqualInt(meta.contentLength.toInt(), 0, "zero contentLength")
}

test "StorageMetadata.contentLength is Long — large value" {
  val large: Long = 5368709120   // 5 GiB
  val meta = Storage.StorageMetadata(
    contentType   = "video/mp4",
    contentLength = large,
    etag          = "etag-large",
    lastModified  = "",
    userMeta      = Map.empty())
  assertTrue(meta.contentLength == large, "large contentLength preserved as Long")
}

// ─── StorageObject ───────────────────────────────────────────────────────────

test "StorageObject construction with all fields" {
  val meta = Storage.StorageMetadata(
    contentType   = "image/png",
    contentLength = 1024,
    etag          = "etag-png",
    lastModified  = "2024-06-01T12:00:00Z",
    userMeta      = Map.empty())
  val obj = Storage.StorageObject(
    bucket     = "my-bucket",
    key        = "images/logo.png",
    metadata   = meta,
    dataBase64 = "aGVsbG8=")
  assertEqual(obj.bucket,            "my-bucket",        "bucket name")
  assertEqual(obj.key,               "images/logo.png",  "object key")
  assertEqual(obj.dataBase64,        "aGVsbG8=",         "base64 data")
  assertEqual(obj.metadata.etag,     "etag-png",         "nested metadata etag")
  assertEqual(obj.metadata.contentType, "image/png",     "nested metadata contentType")
}

// ─── ListEntry ───────────────────────────────────────────────────────────────

test "ListEntry construction and field access" {
  val entry = Storage.ListEntry(
    key           = "docs/readme.md",
    contentLength = 2048,
    lastModified  = "2024-03-15T09:30:00Z",
    etag          = "etag-readme")
  assertEqual(entry.key,          "docs/readme.md",       "key")
  assertEqual(entry.lastModified, "2024-03-15T09:30:00Z", "lastModified")
  assertEqual(entry.etag,         "etag-readme",          "etag")
  assertEqualInt(entry.contentLength.toInt(), 2048, "contentLength")
}

// ─── ListResult ──────────────────────────────────────────────────────────────

test "ListResult construction with empty entries" {
  val result = Storage.ListResult(
    entries               = [],
    nextContinuationToken = None,
    isTruncated           = false)
  assertEqualInt(result.entries.length, 0, "no entries")
  assertFalse(result.isTruncated, "not truncated")
  match result.nextContinuationToken {
    case None    -> ()
    case Some(_) -> assertTrue(false, "token must be None for empty result")
  }
}

test "ListResult with isTruncated false" {
  val e = Storage.ListEntry(key = "a.txt", contentLength = 10, lastModified = "", etag = "e1")
  val result = Storage.ListResult(
    entries               = [e],
    nextContinuationToken = None,
    isTruncated           = false)
  assertFalse(result.isTruncated, "isTruncated is false")
  assertEqualInt(result.entries.length, 1, "one entry")
}

test "ListResult with isTruncated true and continuation token" {
  val e = Storage.ListEntry(key = "b.txt", contentLength = 20, lastModified = "", etag = "e2")
  val result = Storage.ListResult(
    entries               = [e],
    nextContinuationToken = Some(value = "token-xyz"),
    isTruncated           = true)
  assertTrue(result.isTruncated, "isTruncated is true")
  match result.nextContinuationToken {
    case None    -> assertTrue(false, "continuation token must be Some")
    case Some(t) -> assertEqual(t, "token-xyz", "token value")
  }
}

// ─── Key safety primitives ───────────────────────────────────────────────────

test "isSafeKey accepts ordinary keys" {
  assertTrue(Storage.isSafeKey("uploads/photo.jpg"), "ordinary key")
  assertTrue(Storage.isSafeKey("a"),                  "single char key")
  assertTrue(Storage.isSafeKey("nested/dir/file.txt"), "nested key")
  assertTrue(Storage.isSafeKey("version..2.0"),       "dot-dot inside a segment is fine")
  assertTrue(Storage.isSafeKey("my..file.txt"),       "filename embedding .. is fine")
}

test "isSafeKey rejects empty key" {
  assertFalse(Storage.isSafeKey(""), "empty key")
}

test "isSafeKey rejects leading slash (absolute path)" {
  assertFalse(Storage.isSafeKey("/etc/passwd"), "leading slash")
}

test "isSafeKey rejects raw .. segment" {
  assertFalse(Storage.isSafeKey("../etc/passwd"),     "leading ..")
  assertFalse(Storage.isSafeKey("uploads/../etc"),    "interior ..")
  assertFalse(Storage.isSafeKey(".."),                "lone ..")
  assertFalse(Storage.isSafeKey("a/.."),              "trailing ..")
}

test "isSafeKey rejects percent-encoded .. (single)" {
  assertFalse(Storage.isSafeKey("%2e%2e/etc/passwd"),  "lowercase percent")
  assertFalse(Storage.isSafeKey("%2E%2E/etc/passwd"),  "uppercase percent")
}

test "isSafeKey rejects mixed-case percent traversal" {
  assertFalse(Storage.isSafeKey("%2e%2E/etc/passwd"), "mixed-case percent")
}

test "isSafeKey rejects double-encoded percent payloads" {
  assertFalse(Storage.isSafeKey("%252e%252e/etc/passwd"),
              "double-encoded %25 lowercase")
  assertFalse(Storage.isSafeKey("%252E%252E/etc/passwd"),
              "double-encoded %25 uppercase")
}

test "isSafeKey rejects backslash traversal" {
  assertFalse(Storage.isSafeKey("..\\etc\\passwd"), "backslash traversal")
}

test "isSafeKey rejects null bytes" {
  assertFalse(Storage.isSafeKey("ok\u{0000}/etc/passwd"), "embedded null byte")
}

test "normalisedStorageKey decodes target characters only" {
  assertEqual(Storage.normalisedStorageKey("%2e%2e/etc"), "../etc", "decode dot")
  assertEqual(Storage.normalisedStorageKey("%2F/path"),   "//path", "decode slash")
  assertEqual(Storage.normalisedStorageKey("a\\b"),       "a/b",    "fold backslash")
}

test "storageKeyHasDotDot segment-aware" {
  assertTrue(Storage.storageKeyHasDotDot("../etc"),      "leading ..")
  assertTrue(Storage.storageKeyHasDotDot("a/../b"),      "interior ..")
  assertFalse(Storage.storageKeyHasDotDot("version..2"), "embedded .. is not a segment")
  assertFalse(Storage.storageKeyHasDotDot("my..file"),   "filename .. is not a segment")
  assertFalse(Storage.storageKeyHasDotDot("a/b/c"),      "no .. anywhere")
}

test "isSafePrefix admits empty prefix" {
  assertTrue(Storage.isSafePrefix(""),         "empty prefix is list-all")
  assertTrue(Storage.isSafePrefix("uploads/"), "ordinary prefix")
}

test "isSafePrefix rejects traversal" {
  assertFalse(Storage.isSafePrefix("../etc"),               "leading ..")
  assertFalse(Storage.isSafePrefix("%252e%252e/etc"),       "double-encoded")
}
