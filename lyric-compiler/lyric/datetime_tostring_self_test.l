//! datetime_tostring_self_test.l — regression test for the self-hosted MSIL
//! emitter's culture-invariant `toString(DateTime)` path (#2184).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`:
//! those `_tests.l` files are compiled and run by the **F# stage-0** emitter
//! (`Lyric.Emitter.Emitter` via `EmitTestKit.compileAndRun`), whose
//! `toString` builtin already pins InvariantCulture for DateTime — so they
//! would not exercise the *self-hosted* code path at all.  The fix in
//! `lyric-compiler/msil/codegen.l` only runs when the program is compiled by
//! the self-hosted pipeline, so the test program itself must be compiled by
//! it.  This file is run by the native `lyric test`:
//!
//!   lyric test lyric-compiler/lyric/datetime_tostring_self_test.l
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it IN-PROCESS through the self-hosted `Msil.Bridge` (lexer ->
//! parser -> type-checker -> mode-checker -> codegen -> MSIL PE), then
//! executes it and asserts every embedded assertion held.  No
//! `LYRIC_LOAD_COMPILER=1` is needed because this module imports only `Std.*`.
//!
//! What it pins: `toString(inst)` for a DateTime value must render via
//! `DateTime.ToString("o")` (ISO-8601 round-trip, e.g. "1970-01-01T00:00:00.0000000Z"),
//! matching the F# bootstrap emitter's Codegen.fs path byte-for-byte.
//! Before the fix the self-hosted emitter either boxed the address (not the value)
//! of the DateTime, or used CultureInfo.InvariantCulture which diverged from
//! Codegen.fs after it was updated to use ToString("o").
@test_module
package Lyric.DateTimeToStringSelfTest

import Std.Core
import Std.Time
import Std.Testing

test "toString(DateTime) at the Unix epoch renders ISO-8601" {
  // FromUnixTimeMilliseconds(0).UtcDateTime == 1970-01-01T00:00:00 (Utc).
  // DateTime.ToString("o") with Kind=Utc appends "Z" (ISO-8601 UTC marker).
  val inst: Instant = fromEpochMillis(0i64)
  assertEqual(toString(inst), "1970-01-01T00:00:00.0000000Z", "epoch-0 iso render")
}

test "toString(DateTime) for a non-zero epoch renders ISO-8601" {
  // 1_000_000_000_000 ms == 1_000_000_000 s == 2001-09-09T01:46:40Z.
  val inst: Instant = fromEpochMillis(1000000000000i64)
  assertEqual(toString(inst), "2001-09-09T01:46:40.0000000Z", "epoch-1e12 iso render")
}
