//! string_bounds_self_test.l — `Std.String.indexOfFrom`/`indexOfFromRaw`
//! reject an out-of-range start through their `requires:` clause (#7258).
//!
//! The hosts disagree here (.NET `IndexOf` throws, JVM `indexOf` clamps), so
//! the contract is what makes the targets agree. Uses `assertPanics`, which
//! needs try/catch, so it runs on dotnet and the JVM only (native has no
//! unwinding, D-N-003; `lyric_string_index_of_from` panics on the same bound
//! and is covered by the lyric-rt C tests).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/string_bounds_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_bounds_self_test.l
@test_module
package Lyric.StringBoundsSelfTest

import Std.Core
import Std.String
import Std.Testing

test "indexOfFromRaw rejects a negative start" {
  assertPanics("negative from", { -> val _ = indexOfFromRaw("abc", "a", -1) })
}

test "indexOfFrom rejects a start past the end" {
  assertPanics("from past the end", { -> val _ = indexOfFrom("abc", "a", 4) })
}

test "a start equal to the length is accepted" {
  assertEqualInt(indexOfFromRaw("abc", "a", 3), -1, "no match at end")
  assertEqualInt(indexOfFromRaw("abc", "", 3), 3, "empty needle at end")
}
