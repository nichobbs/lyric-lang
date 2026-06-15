//! quantifier_ident_self_test.l — regression for the forall/exists parser fix.
//!
//! `forall` and `exists` are contract quantifiers, but they are not reserved
//! words: a library may legitimately define and call a function named `exists`
//! (e.g. `StorageBucket.exists(bucket, key)`).  The parser used to treat any
//! `forall(`/`exists(` in expression position as a quantifier, so such a call
//! failed with P0301 ("expected ':' in quantifier binder").  A quantifier is
//! always `forall( IDENT : Type ...)`; a call is `forall( <expr> , ...)`, so the
//! parser now only takes the quantifier path when the tokens after `(` are
//! `IDENT :`.  This is a front-end (parser) fix and is target-independent.
//!
//! Run in CI via native `lyric test` on the dotnet target; imports only `Std.*`.
//! Not JVM-wired: the JVM backend hits a pre-existing stdlib-bundling gap
//! (#3709, docs/44 band J003 / VerifyError) on this module shape, unrelated to
//! the parser fix.
@test_module
package QuantifierIdentSelfTest

import Std.Core
import Std.Testing

// Functions named after the quantifier keywords, with non-binder argument
// shapes that previously mis-parsed as quantifiers.
func exists(a: in Int, b: in Int): Bool {
  return a == b
}

func forall(a: in Int, b: in Int): Int {
  return a + b
}

test "a function named exists is callable in expression position" {
  assertTrue(exists(3, 3), "exists(3, 3) is true")
  assertFalse(exists(3, 4), "exists(3, 4) is false")
}

test "exists nested inside another call parses as a call" {
  // `assertTrue(exists(...))` is the shape lyric-storage used (isOk(exists(...))).
  assertTrue(exists(7, 7), "nested exists call evaluates")
}

test "a function named forall is callable" {
  assertEqualInt(forall(2, 3), 5, "forall(2, 3) returns 5")
}
