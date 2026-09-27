//! A distinct value as a `List` element and in generic equality (#7375).
//!
//! Distinct wrapper classes on dotnet and the JVM compare and hash by the
//! underlying value, so `List.contains` finds an element built separately
//! from the one added.  Map keys and operator equality are covered by
//! `distinct_ops_self_test.l`; `Set` keys by `lyric-stdlib/tests/set_tests.l`.
//! Native is not run here: `List.contains` on a non-`String` element fails
//! native codegen (#7429).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/distinct_collections_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/distinct_collections_self_test.l
@test_module
package Lyric.DistinctCollectionsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

type UserId = Long

type Email = String

test "List.contains finds an equal distinct value" {
  val ids: List[UserId] = newList()
  ids.add(UserId.from(1i64))
  ids.add(UserId.from(2i64))
  assertTrue(ids.contains(UserId.from(2i64)), "Long-backed element found by an equal value")
  assertTrue(not ids.contains(UserId.from(3i64)), "a different Long-backed element is not found")
  val emails: List[Email] = newList()
  emails.add(Email.from("a@example.com"))
  assertTrue(emails.contains(Email.from("a@" + "example.com")), "String-backed element found by an equal value")
}
