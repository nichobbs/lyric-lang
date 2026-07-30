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
//! JVM-only, by design: the MSIL backend has never adopted this UFCS
//! routing at all (it always lowers `.indexOf`/`.lastIndexOf` to the raw
//! BCL `Int`-returning intrinsic regardless of imports — tracked
//! separately as #5625) — so this file's `Option[Int]`-returning
//! `findColonOpt` crashes on `--target dotnet` with an
//! `AccessViolationException` (the BCL `int` gets reinterpreted as an
//! `Option[Int]` reference). That is a pre-existing, unrelated MSIL gap,
//! not a regression from this PR (which touches only
//! `lyric-compiler/jvm/codegen/`) — confirmed by `--target dotnet` failing
//! identically before and after these commits. Run via native `lyric test`:
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
