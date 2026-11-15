//! Testing.Conformance.Storage — conformance suite for `Storage.StorageBucket`.
//!
//! `run(factory)`: `factory` returns a fresh, empty bucket every call.
//!
//! Payloads are base64 text, as the interface takes them.  `presignedUrl` may
//! succeed or answer `NOT_SUPPORTED` (a local filesystem cannot sign a URL);
//! either is conformant, any other error is not.  Likewise `put` with user
//! metadata either stores it or answers `USER_META_UNSUPPORTED`; it never
//! silently drops it.
@runtime_checked
@io
package Testing.Conformance.Storage

import Std.Core
import Std.Collections
import Testing.Conformance
import Storage as StorageLib

// "hello world" and "Lyric" in base64, and their decoded sizes.
val HELLO_B64: String = "aGVsbG8gd29ybGQ="

val HELLO_LEN: Long = 11i64

val LYRIC_B64: String = "THlyaWM="

val LYRIC_LEN: Long = 5i64

/// Run the `StorageBucket` contract against buckets from `factory`.
@stable(since = "0.1")
pub func run(factory: () -> StorageLib.StorageBucket): Checks {
  val c = newChecks("StorageBucket")
  runCase(c, "put then get returns the payload and content type", { -> putGet(c, factory()) })
  runCase(c, "put reports the payload size", { -> putSize(c, factory()) })
  runCase(c, "user metadata round-trips", { -> userMeta(c, factory()) })
  runCase(c, "put overwrites an existing object", { -> overwrite(c, factory()) })
  runCase(c, "keys with path separators are distinct objects", { -> nestedKeys(c, factory()) })
  runCase(c, "get of a missing key is NOT_FOUND", { -> getMissing(c, factory()) })
  runCase(c, "delete removes the object and is idempotent", { -> deleteKey(c, factory()) })
  runCase(c, "exists reflects put and delete", { -> existsKey(c, factory()) })
  runCase(c, "list filters by prefix in key order", { -> listPrefix(c, factory()) })
  runCase(c, "list pages with maxKeys and a continuation token", { -> listPaging(c, factory()) })
  runCase(c, "list of an empty bucket is empty", { -> listEmpty(c, factory()) })
  runCase(c, "unsafe keys are rejected with INVALID_KEY", { -> unsafeKeys(c, factory()) })
  runCase(c, "presignedUrl succeeds or answers NOT_SUPPORTED", { -> presigned(c, factory()) })
  runCase(c, "the convenience wrappers agree with the interface", { -> wrappers(c, factory()) })
  return c
}

func noMeta(): Map[String, String] {
  return newMap()
}

func putOrFail(c: in Checks, bucket: in StorageLib.StorageBucket, key: in String, b64: in String): Unit {
  match bucket.put(key, b64, "text/plain", noMeta()) {
    case Ok(_) -> expectTrue(c, true, "put " + key)
    case Err(e) -> failCase(c, "put " + key + " failed: " + e.code + " " + e.message)
  }
}

func errCode(r: in Result[StorageLib.StorageObject, StorageLib.StorageError]): String {
  match r {
    case Err(e) -> return e.code
    case Ok(_) -> return "(Ok)"
  }
}

func putGet(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  match bucket.put("docs/hello.txt", HELLO_B64, "text/plain", noMeta()) {
    case Err(e) -> failCase(c, "put failed: " + e.code + " " + e.message)
    case Ok(_) -> {
      match bucket.get("docs/hello.txt") {
        case Err(e) -> failCase(c, "get failed: " + e.code + " " + e.message)
        case Ok(obj) -> {
          expectEqual(c, obj.dataBase64, HELLO_B64, "the payload")
          expectEqual(c, obj.metadata.contentType, "text/plain", "the content type")
          expectEqual(c, obj.key, "docs/hello.txt", "the key")
        }
      }
    }
  }
}

func putSize(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  match bucket.put("sized.bin", HELLO_B64, "application/octet-stream", noMeta()) {
    case Err(e) -> failCase(c, "put failed: " + e.code)
    case Ok(meta) -> {
      expectEqualLong(c, meta.contentLength, HELLO_LEN, "contentLength returned by put")
      expectTrue(c, meta.etag.length > 0, "put returns an etag")
    }
  }
  match bucket.get("sized.bin") {
    case Err(e) -> failCase(c, "get failed: " + e.code)
    case Ok(obj) -> expectEqualLong(c, obj.metadata.contentLength, HELLO_LEN, "contentLength returned by get")
  }
}

func userMeta(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  val meta: Map[String, String] = newMap()
  meta["owner"] = "alice"
  meta["purpose"] = "test"
  match bucket.put("meta.txt", LYRIC_B64, "text/plain", meta) {
    case Err(e) -> {
      // A backend that cannot store user metadata must refuse it, not drop it.
      expectEqual(c, e.code, "USER_META_UNSUPPORTED", "the only acceptable refusal of user metadata")
    }
    case Ok(_) -> {
      match bucket.get("meta.txt") {
        case Err(e) -> failCase(c, "get failed: " + e.code)
        case Ok(obj) -> {
          expectSome(c, mapGet(obj.metadata.userMeta, "owner"), "alice", "user metadata owner")
          expectSome(c, mapGet(obj.metadata.userMeta, "purpose"), "test", "user metadata purpose")
        }
      }
    }
  }
}

func overwrite(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  putOrFail(c, bucket, "k", HELLO_B64)
  putOrFail(c, bucket, "k", LYRIC_B64)
  match bucket.get("k") {
    case Err(e) -> failCase(c, "get failed: " + e.code)
    case Ok(obj) -> expectEqual(c, obj.dataBase64, LYRIC_B64, "the second put wins")
  }
  match bucket.list("", "", 100) {
    case Err(e) -> failCase(c, "list failed: " + e.code)
    case Ok(r) -> expectEqualInt(c, r.entries.length, 1, "an overwrite does not add an entry")
  }
}

func nestedKeys(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  putOrFail(c, bucket, "a/b", HELLO_B64)
  putOrFail(c, bucket, "a/c/d", LYRIC_B64)
  match bucket.get("a/b") {
    case Ok(obj) -> expectEqual(c, obj.dataBase64, HELLO_B64, "a/b")
    case Err(e) -> failCase(c, "get a/b failed: " + e.code)
  }
  match bucket.get("a/c/d") {
    case Ok(obj) -> expectEqual(c, obj.dataBase64, LYRIC_B64, "a/c/d")
    case Err(e) -> failCase(c, "get a/c/d failed: " + e.code)
  }
}

func getMissing(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  expectEqual(c, errCode(bucket.get("never/stored")), "NOT_FOUND", "get of a missing key")
}

func deleteKey(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  putOrFail(c, bucket, "gone", HELLO_B64)
  match bucket.delete("gone") {
    case Ok(_) -> expectTrue(c, true, "delete")
    case Err(e) -> failCase(c, "delete failed: " + e.code)
  }
  expectEqual(c, errCode(bucket.get("gone")), "NOT_FOUND", "get after delete")
  match bucket.delete("gone") {
    case Ok(_) -> expectTrue(c, true, "deleting again")
    case Err(e) -> failCase(c, "delete is idempotent but failed: " + e.code)
  }
  match bucket.delete("never-stored") {
    case Ok(_) -> expectTrue(c, true, "deleting a missing key")
    case Err(e) -> failCase(c, "deleting a missing key failed: " + e.code)
  }
}

func existsKey(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  match bucket.exists("e") {
    case Ok(b) -> expectTrue(c, not b, "exists before put")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
  putOrFail(c, bucket, "e", HELLO_B64)
  match bucket.exists("e") {
    case Ok(b) -> expectTrue(c, b, "exists after put")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
  match bucket.delete("e") {
    case Ok(_) -> ()
    case Err(e) -> failCase(c, "delete failed: " + e.code)
  }
  match bucket.exists("e") {
    case Ok(b) -> expectTrue(c, not b, "exists after delete")
    case Err(e) -> failCase(c, "exists failed: " + e.code)
  }
}

func listPrefix(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  putOrFail(c, bucket, "logs/2026/b.txt", HELLO_B64)
  putOrFail(c, bucket, "logs/2026/a.txt", HELLO_B64)
  putOrFail(c, bucket, "other/x.txt", HELLO_B64)
  match bucket.list("logs/", "", 100) {
    case Err(e) -> failCase(c, "list failed: " + e.code)
    case Ok(r) -> {
      expectEqualInt(c, r.entries.length, 2, "entries under the prefix")
      expectTrue(c, not r.isTruncated, "a short listing is not truncated")
      if r.entries.length == 2 {
        expectEqual(c, r.entries[0].key, "logs/2026/a.txt", "first key in order")
        expectEqual(c, r.entries[1].key, "logs/2026/b.txt", "second key in order")
      }
    }
  }
  match bucket.list("", "", 100) {
    case Err(e) -> failCase(c, "list failed: " + e.code)
    case Ok(r) -> expectEqualInt(c, r.entries.length, 3, "the empty prefix lists everything")
  }
}

func listPaging(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  for k in ["k1", "k2", "k3", "k4", "k5"] {
    putOrFail(c, bucket, k, HELLO_B64)
  }
  val seen: List[String] = newList()
  var token = ""
  var pages = 0
  var more = true
  while more and pages < 10 {
    match bucket.list("", token, 2) {
      case Err(e) -> {
        failCase(c, "list failed: " + e.code)
        more = false
      }
      case Ok(r) -> {
        pages = pages + 1
        expectTrue(c, r.entries.length <= 2, "a page holds at most maxKeys entries")
        for e in r.entries {
          seen.add(e.key)
        }
        if r.isTruncated {
          match r.nextContinuationToken {
            case Some(t) -> {
              token = t
            }
            case None -> {
              failCase(c, "a truncated listing must carry a continuation token")
              more = false
            }
          }
        } else {
          more = false
        }
      }
    }
  }
  expectEqualInt(c, pages, 3, "5 keys at 2 per page is 3 pages")
  expectEqualInt(c, seen.count, 5, "every key is listed exactly once across the pages")
  if seen.count == 5 {
    expectEqual(c, seen[0], "k1", "paging starts at the first key")
    expectEqual(c, seen[4], "k5", "paging ends at the last key")
  }
}

func listEmpty(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  match bucket.list("", "", 10) {
    case Err(e) -> failCase(c, "list failed: " + e.code)
    case Ok(r) -> {
      expectEqualInt(c, r.entries.length, 0, "an empty bucket lists nothing")
      expectTrue(c, not r.isTruncated, "an empty listing is not truncated")
    }
  }
}

func unsafeKeys(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  for key in ["../escape", "a/../../escape", "sidecar.meta.json"] {
    match bucket.put(key, HELLO_B64, "text/plain", noMeta()) {
      case Err(e) -> expectEqual(c, e.code, "INVALID_KEY", "put of \"" + key + "\"")
      case Ok(_) -> failCase(c, "put of \"" + key + "\" must be rejected")
    }
    expectEqual(c, errCode(bucket.get(key)), "INVALID_KEY", "get of \"" + key + "\"")
  }
}

func presigned(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  putOrFail(c, bucket, "p", HELLO_B64)
  match bucket.presignedUrl("p", 60) {
    case Ok(url) -> expectTrue(c, url.length > 0, "a presigned URL is non-empty")
    case Err(e) -> expectEqual(c, e.code, "NOT_SUPPORTED", "the only acceptable presignedUrl failure")
  }
}

func wrappers(c: in Checks, bucket: in StorageLib.StorageBucket): Unit {
  match StorageLib.put(bucket, "w", HELLO_B64, "text/plain") {
    case Ok(_) -> expectTrue(c, true, "Storage.put")
    case Err(e) -> failCase(c, "Storage.put failed: " + e.code)
  }
  match StorageLib.get(bucket, "w") {
    case Ok(obj) -> expectEqual(c, obj.dataBase64, HELLO_B64, "Storage.get")
    case Err(e) -> failCase(c, "Storage.get failed: " + e.code)
  }
  match StorageLib.exists(bucket, "w") {
    case Ok(b) -> expectTrue(c, b, "Storage.exists")
    case Err(e) -> failCase(c, "Storage.exists failed: " + e.code)
  }
  match StorageLib.list(bucket, "") {
    case Ok(r) -> expectEqualInt(c, r.entries.length, 1, "Storage.list")
    case Err(e) -> failCase(c, "Storage.list failed: " + e.code)
  }
  match StorageLib.delete(bucket, "w") {
    case Ok(_) -> expectTrue(c, true, "Storage.delete")
    case Err(e) -> failCase(c, "Storage.delete failed: " + e.code)
  }
}
