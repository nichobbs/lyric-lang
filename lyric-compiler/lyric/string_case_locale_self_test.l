//! string_case_locale_self_test.l — case conversion ignores the process
//! locale on every target (#7261, #5557).
//!
//! JVM `s.toLower()`/`s.toUpper()` used to lower to the no-argument
//! `toLowerCase()`/`toUpperCase()`, and the .NET `Std.Char.toUpper`/`toLower`
//! kernel bound the culture-sensitive `Char.ToUpper`/`ToLower`. Under a
//! Turkish locale both map 'I' to dotless 'ı' and 'i' to dotted 'İ', so
//! results depended on the machine. CI runs this module with a Turkish
//! default locale on dotnet (`LANG`/`LC_ALL=tr_TR.UTF-8`) and on the JVM
//! (`-Duser.language=tr -Duser.country=TR`); under any other locale it
//! simply passes.
//!
//!   LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8 lyric test --target dotnet lyric-compiler/lyric/string_case_locale_self_test.l
//!   JAVA_TOOL_OPTIONS="-Duser.language=tr -Duser.country=TR" lyric test --target jvm lyric-compiler/lyric/string_case_locale_self_test.l
@test_module
package Lyric.StringCaseLocaleSelfTest

import Std.Core
import Std.Char
import Std.String
import Std.Testing

test "String toLower and toUpper map I and i without locale tailoring" {
  assertEqual("TITLE".toLower(), "title", "toLower")
  assertEqual("title".toUpper(), "TITLE", "toUpper")
}

test "Char toLower and toUpper map I and i without locale tailoring" {
  assertTrue(Std.Char.toLower('I') == 'i', "Char.toLower")
  assertTrue(Std.Char.toUpper('i') == 'I', "Char.toUpper")
}

// #7269: equalsCaseInsensitive folds ASCII in place and only lowercases
// whole strings when either side has a non-ASCII character.
test "equalsCaseInsensitive folds ASCII without locale tailoring" {
  assertTrue(Std.String.equalsCaseInsensitive("TITLE", "title"), "I and i fold under any locale")
  assertTrue(Std.String.equalsCaseInsensitive("Content-Length", "content-length"), "header name")
  assertTrue(Std.String.equalsCaseInsensitive("", ""), "empty strings")
  assertTrue(not Std.String.equalsCaseInsensitive("Host", "Hosts"), "length differs")
  assertTrue(not Std.String.equalsCaseInsensitive("[a]", "{A}"), "only letters fold")
}

test "equalsCaseInsensitive falls back to full lowercasing for non-ASCII text" {
  assertTrue(Std.String.equalsCaseInsensitive("ÉCOLE", "école"), "E-acute folds")
  assertTrue(not Std.String.equalsCaseInsensitive("École", "ecole"), "E-acute is not e")
  assertTrue(not Std.String.equalsCaseInsensitive("abc", "abé"), "one side non-ASCII")
}
