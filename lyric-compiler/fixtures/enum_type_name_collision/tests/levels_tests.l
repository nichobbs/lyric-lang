//! `LogLevel.Info` in a file that imports a package declaring its own
//! `LogLevel`, while the stdlib's `Std.Log.LogLevel` is linked into the same
//! build.  The JVM backend's type-scoped enum registry key
//! (`enumty:<Enum>.<Case>`) was bundle-global and first-wins, so the reference
//! resolved to `Std/Log/LogLevel` and failed with `NoClassDefFoundError`
//! (found through lyric-logging's suite on `--target jvm`).
@test_module
package EnumCollisionTests

import Std.Core
import Std.Testing
import EnumCollisionLib

test "an imported enum's case wins over a stdlib enum of the same type name" {
  assertEqualInt(ordinalOf(LogLevel.Info), 2, "Info")
  assertEqualInt(ordinalOf(LogLevel.Warn), 3, "Warn")
  assertEqualInt(ordinalOf(LogLevel.Error), 4, "Error")
  assertEqualInt(ordinalOf(LogLevel.Debug), 1, "Debug")
}

test "cases only the library's enum declares still resolve" {
  assertEqualInt(ordinalOf(LogLevel.Audit), 6, "Audit")
  assertEqualInt(ordinalOf(LogLevel.Fatal), 5, "Fatal")
  assertEqualInt(ordinalOf(LogLevel.Trace), 0, "Trace")
}

test "the library's functions take the enum the test constructs" {
  assertTrue(isInfoOrAbove(LogLevel.Warn), "Warn is above Info")
  assertTrue(not isInfoOrAbove(LogLevel.Debug), "Debug is below Info")
}
