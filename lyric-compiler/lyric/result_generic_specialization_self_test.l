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
