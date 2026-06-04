// cli_suggest.l — command-name suggestion helpers for the Lyric CLI.
//
// Extracted from cli.l so the pure suggestion logic is unit-testable in
// isolation (see cli_suggest_self_test.l) without importing the whole
// Lyric.Cli package and its heavy emitter/bridge dependency graph.
//
// `knownCommands` lists the user-facing commands eligible for a
// "did you mean …?" suggestion.  It deliberately excludes `lsp`: the
// language-server command is editor-invoked, not hand-typed, and is not
// shown in the CLI help text, so suggesting it would point a user at an
// undocumented command (#1989).

package Lyric.CliSuggest

import Std.Core
import Std.Collections

// The set of command names eligible for did-you-mean suggestions.  Kept in
// sync with cli.l's dispatcher (minus the editor-only `lsp`).
pub func knownCommands(): List[String] {
  val cmds: List[String] = newList()
  cmds.add("build")
  cmds.add("run")
  cmds.add("fmt")
  cmds.add("lint")
  cmds.add("prove")
  cmds.add("doc")
  cmds.add("public-api-diff")
  cmds.add("restore")
  cmds.add("add")
  cmds.add("publish")
  cmds.add("search")
  cmds.add("repl")
  cmds.add("test")
  cmds.add("bench")
  cmds.add("openapi")
  cmds.add("help")
  cmds
}

func minInt(a: in Int, b: in Int): Int { if a < b { a } else { b } }

// Levenshtein edit distance — small two-row DP.  Inputs are short command
// names, so the O(n*m) cost is negligible.
pub func editDistance(a: in String, b: in String): Int {
  val n = a.length
  val m = b.length
  if n == 0 { return m }
  if m == 0 { return n }
  var prev: List[Int] = newList()
  var j = 0
  while j <= m { prev.add(j); j += 1 }
  var i = 1
  while i <= n {
    val cur: List[Int] = newList()
    cur.add(i)
    var k = 1
    while k <= m {
      val cost = if a[i - 1] == b[k - 1] { 0 } else { 1 }
      val del = prev[k] + 1
      val ins = cur[k - 1] + 1
      val sub = prev[k - 1] + cost
      cur.add(minInt(minInt(del, ins), sub))
      k += 1
    }
    prev = cur
    i += 1
  }
  prev[m]
}

// Return the closest known command to `cmd` when it is within edit distance 2,
// for "did you mean 'build'?" suggestions on an unknown command.
pub func suggestCommand(cmd: in String): Option[String] {
  val cmds = knownCommands()
  var best: Option[String] = None
  var bestDist = 1000000
  var i = 0
  while i < cmds.count {
    val c = cmds[i]
    val d = editDistance(cmd, c)
    if d < bestDist {
      bestDist = d
      best = Some(value = c)
    }
    i += 1
  }
  if bestDist <= 2 { best } else { None }
}
