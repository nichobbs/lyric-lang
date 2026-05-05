// std/regex.l - Regex via System.Text.RegularExpressions.
//
// Bootstrap-grade surface: compile a pattern, test for matches,
// extract a captured group.  More elaborate APIs (named groups,
// match collections, replace with backreferences) live behind
// follow-up FFI work.
package Std.Regex

import Std.Core

extern type Regex = "System.Text.RegularExpressions.Regex"
extern type Match = "System.Text.RegularExpressions.Match"

@externTarget("System.Text.RegularExpressions.Regex..ctor")
pub func compile(pattern: in String): Regex = ()

@externTarget("System.Text.RegularExpressions.Regex.IsMatch")
pub func isMatch(r: in Regex, input: in String): Bool = ()

@externTarget("System.Text.RegularExpressions.Regex.Match")
pub func matchOne(r: in Regex, input: in String): Match = ()

@externTarget("System.Text.RegularExpressions.Regex.Replace")
pub func replace(r: in Regex, input: in String, replacement: in String): String = ()

// =====================================================================
// Match inspection (instance-method dispatch via BCL).
//
// Direct method-style works on a `Match` value:
//   m.success           — `Match.Success` (bool)
//   m.value             — `Match.Value`   (string — full match)
//   m.length            — `Match.Length`
//   m.index             — `Match.Index`
//
// Group access is a separate API (`m.Groups[i]`) that needs an
// indexer call into a non-array container; covered when we wire up
// `GroupCollection.get_Item` cleanly.
// =====================================================================
