//! Regression test for #3693: isOk/isErr specialization + nested-generic TypeSpec handling; runs --target dotnet and --target jvm.
@test_module
package Lyric.ResultGenericSpecializationSelfTest

import Std.Core
import Std.Testing

interface StorageBucket {
  func list(prefix: in String): List[String]
}

record LocalStorageBucket {
  basePath: String
}

impl StorageBucket for LocalStorageBucket {
  func list(prefix: in String): List[String] {
    val result: List[String] = newList()
    result
  }
}

record StorageError {
  code: Int
}

func makeErrorResult(): Result[StorageBucket, StorageError] {
  Err(error = StorageError(code = 1))
}

func makeOkResult(): Result[StorageBucket, StorageError] {
  val bucket: StorageBucket = LocalStorageBucket(basePath = "/tmp")
  Ok(value = bucket)
}

test "isErr with Result[interface, record]" {
  val r = makeErrorResult()
  assertTrue(isErr(r), "Result with interface type and record error should specialise isErr")
}

test "isOk with Result[interface, record]" {
  val r = makeOkResult()
  assertTrue(isOk(r), "Result with interface type and record error should specialise isOk")
}

test "isErr with nested generic Result[List[String], StorageError]" {
  val r: Result[List[String], StorageError] = Err(error = StorageError(code = 2))
  assertTrue(isErr(r), "Result with nested generic value type should specialise isErr")
}

test "isOk with nested generic Result[List[String], StorageError]" {
  val items: List[String] = newList()
  val r: Result[List[String], StorageError] = Ok(value = items)
  assertTrue(isOk(r), "Result with nested generic value type should specialise isOk")
}

// A generic whose `T` is bound by a `Result[Long, E]` argument and by an
// `Int` literal at a bare `T` parameter specialises at `Long`, the wider
// type, and the literal is widened (D-progress-968). Before, the conflict
// typed the call as an error and the specialisation took the literal's `Int`.
func pickOr[T](r: in Result[T, String], fallback: in T): T {
  match r {
    case Ok(v) -> v
    case Err(_) -> fallback
  }
}

func bigLong(ok: in Bool): Result[Long, String] {
  if ok {
    Ok(value = 5000000000i64)
  } else {
    Err(error = "none")
  }
}

test "a widening literal specialises a generic at the wider type (D-progress-968)" {
  val big: Long = pickOr(bigLong(true), 0)
  assertTrue(big == 5000000000i64, "the Ok payload above Int.MAX survives as a Long")
  val fallback: Long = pickOr(bigLong(false), 7)
  assertTrue(fallback == 7i64, "the Int literal fallback is widened to Long")
  assertEqual((big + fallback).toString(), "5000000007", "the specialisation's result is a Long")
}

// The same widening with the bare `T` parameter first: the specialisation
// must not bind `T` from the literal before it sees the `Result[Long, _]`
// argument (#7366).
func orPick[T](fallback: in T, r: in Result[T, String]): T {
  match r {
    case Ok(v) -> v
    case Err(_) -> fallback
  }
}

test "a widening literal before the pinning argument specialises at the wider type (#7366)" {
  val big: Long = orPick(0, bigLong(true))
  assertTrue(big == 5000000000i64, "the Ok payload above Int.MAX survives as a Long")
  val fallback: Long = orPick(7, bigLong(false))
  assertTrue(fallback == 7i64, "the Int literal fallback is widened to Long")
}
