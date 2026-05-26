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
