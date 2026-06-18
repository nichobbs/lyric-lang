// cli_suggest_self_test.l — exercises Lyric.CliSuggest (the CLI
// did-you-mean suggestion helpers) via the native `@test_module` runner.
//
// Runs in CI via:
//
//   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cli_suggest_self_test.l
//
// (CLAUDE.md no-new-F#-code policy: discovery is the native Lyric path,
// mirroring cfg_gate_self_test.l — no F# runner shim.)

@test_module
package Lyric.CliSuggestSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.CliSuggest as Suggest

// ── editDistance ────────────────────────────────────────────────────────────

test "editDistance: identical strings → 0" {
  assertEqualInt(Suggest.editDistance("build", "build"), 0, "identical")
}

test "editDistance: single substitution → 1" {
  assertEqualInt(Suggest.editDistance("buld", "build"), 1, "buld vs build")
}

test "editDistance: empty vs non-empty → length" {
  assertEqualInt(Suggest.editDistance("", "test"), 4, "empty lhs")
  assertEqualInt(Suggest.editDistance("test", ""), 4, "empty rhs")
}

test "editDistance: transposition costs 2 (no Damerau)" {
  // plain Levenshtein treats a swap as two substitutions
  assertEqualInt(Suggest.editDistance("ab", "ba"), 2, "swap")
}

// ── suggestCommand ───────────────────────────────────────────────────────────

test "suggestCommand: close typo → suggests the command" {
  match Suggest.suggestCommand("buld") {
    case Some(s) -> assertEqual(s, "build", "buld → build")
    case None    -> assertTrue(false, "expected a suggestion for 'buld'")
  }
}

test "suggestCommand: typo of help → suggests help" {
  match Suggest.suggestCommand("helo") {
    case Some(s) -> assertEqual(s, "help", "helo → help")
    case None    -> assertTrue(false, "expected a suggestion for 'helo'")
  }
}

test "suggestCommand: far string → no suggestion" {
  match Suggest.suggestCommand("xyzzy123") {
    case None    -> assertTrue(true, "no suggestion as expected")
    case Some(s) -> assertTrue(false, "unexpected suggestion '" + s + "' for far input")
  }
}

test "suggestCommand: lsp excluded from suggestions (#1989)" {
  // `lsp` is editor-invoked and absent from the help text, so even an exact
  // edit-distance-0 match must not be surfaced as a suggestion.
  match Suggest.suggestCommand("lsp") {
    case None    -> assertTrue(true, "lsp not suggested")
    case Some(s) -> assertTrue(false, "lsp should not be suggested, got '" + s + "'")
  }
}
