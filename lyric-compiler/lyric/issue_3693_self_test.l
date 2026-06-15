//! issue_3693_self_test.l — regression test for issue #3693
//!
//! isOk/isErr over Result[interface, record] was not being specialised because
//! the monomorphiser's generic-function import list was filtering out
//! expression-bodied generics. Fixed by allowing expression-bodied functions
//! in collectStdlibGenericFuncs / collectInBundleGenericFuncs / 
//! collectRestoredGenericFuncs.
@test_module
package Lyric.Issue3693SelfTest

import Std.Core
import Std.Testing

interface StorageBucket {
  func list(prefix: in String): List[String]
}

record StorageError {
  code: Int
}

func makeErrorResult(): Result[StorageBucket, StorageError] {
  Err(error = StorageError(code = 1))
}

test "isErr with Result[interface, record]" {
  val r = makeErrorResult()
  assertTrue(isErr(r), "Result with interface type and record error should specialise isErr")
}
