//! jvm_trio_positive_self_test.l — companion to `jvm_trio_self_test.l`'s
//! #6124 coverage: the POSITIVE path, confirming the fix did not regress the
//! working case it was built to preserve.
//!
//! `jvm_trio_self_test.l` pins that a file WITHOUT `import Std.String` gets
//! the raw JDK `.indexOf`/`.lastIndexOf` `Int` semantics even when
//! `Std.String` is imported elsewhere in the bundle. This file pins the
//! other half: a file that DOES import `Std.String` directly still gets the
//! `Option[Int]` UFCS routing — `ctx.importsStdString` gates on a REAL
//! per-file check, not an always-false / always-true shortcut. It needs
//! `Std.String` imported directly, which would defeat `jvm_trio_self_test.l`'s
//! deliberate no-direct-import setup for its negative cases, hence a separate
//! file.
//!
//! Dual-target since #6348: the MSIL backend now routes the method spelling
//! to the same `Option[Int]`-returning Std.String free functions when the
//! file has an UNALIASED `import Std.String` (it previously always lowered
//! to the raw BCL `Int` intrinsic — the #5625 mis-binding — which made this
//! file crash `--target dotnet` with an `AccessViolationException`).  The
//! remaining cross-target divergence is aliased imports only (#6496).
//! Run via native `lyric test`:
//!   lyric test --target jvm lyric-compiler/lyric/jvm_trio_positive_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.JvmTrioPositiveSelfTest

import Std.Core
import Std.Testing
import Std.String

func findColonOpt(line: in String): Option[Int] {
  line.indexOf(":")
}

test "String.indexOf WITH Std.String imported still returns Option[Int] (#6124 positive path)" {
  match findColonOpt("Content-Length: 7") {
    case Some(idx) -> assertEqualInt(idx, 14, "colon is at index 14")
    case None -> assertTrue(false, "expected Some, got None")
  }
}

test "String.indexOf WITH Std.String imported returns None for a missing needle (#6124 positive path)" {
  match findColonOpt("no colon here") {
    case Some(_) -> assertTrue(false, "expected None, got Some")
    case None -> ()
  }
}

test "String.lastIndexOf WITH Std.String imported still returns Option[Int] (#6124 positive path)" {
  match "a:b:c".lastIndexOf(":") {
    case Some(idx) -> assertEqualInt(idx, 3, "last colon is at index 3")
    case None -> assertTrue(false, "expected Some, got None")
  }
}
