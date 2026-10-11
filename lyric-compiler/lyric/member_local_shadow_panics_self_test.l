//! member_local_shadow_panics_self_test.l — a protected type's invariant
//! catches a breach of its field where a parameter shares the field's name
//! (#8264).  The invariant is about the type's state, so it reads the field
//! even where the member's parameter hides it from the body.  Needs `try`,
//! so it runs on dotnet and the JVM; the non-panicking shapes are in
//! `member_local_shadow_self_test.l`, which runs on every target.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/member_local_shadow_panics_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/member_local_shadow_panics_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.MemberLocalShadowPanicsSelfTest

import Std.Core
import Std.Testing

protected type Acc {
  var total: Int = 0
  invariant: total >= 0
  entry breach(total: in Int): Int {
    self.total = -1
    total
  }
}

test "a field breach is caught where a parameter shares the field's name" {
  val a = Acc()
  var caught = false
  try {
    val _ = a.breach(4)
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "breach(4) leaves total = -1, violating the invariant")
}
