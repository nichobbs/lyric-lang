//! msil_self_test_m89.l — Stage M89: outer-var mutation from a `match` arm
//! nested inside an `if`-expression branch (issue #5049).
//!
//! `docs/57-stdlib-ecosystem-library-review.md` §8 and
//! `docs/10-bootstrap-progress.md` D-progress-591 record that a real-world
//! instance of this shape — a `var` of `Option[Record]` type declared
//! before an expression-position `if`, mutated from inside a `match` (used
//! in statement position, every arm assigning) nested inside the `if`'s
//! true-branch, then read back out after the `if` completes — was found in
//! `lyric-compiler/lyric/parser/parser_core.l::parseImportDecl`, and the
//! shipped fix sidestepped it entirely (extracted into a helper returning a
//! value, no outer-var mutation from nested scope) rather than confirming
//! the pattern actually compiles and runs correctly. Issue #5049 tracks the
//! open question of whether the self-hosted MSIL backend has a genuine
//! codegen gap for this specific nesting.
//!
//! A repeatable investigation (see the issue's discussion) restored the
//! original code verbatim into `parser_core.l`, rebuilt the self-hosted
//! toolchain, and ran it against real selector-group-import source
//! (including the exact file whose compilation first surfaced the crash) —
//! it did not reproduce. Whatever the original trigger was, it was not
//! purely this AST shape in isolation. Since the shape was confirmed
//! completely untested anywhere in the tree, this file locks it down as a
//! permanent regression guard regardless of the original root cause: if a
//! future codegen change reintroduces a miscompile for outer-var mutation
//! nested two control-flow levels deep, this test catches it.
//!
//! Run in CI via native `lyric test` (the `bitwise_self_test.l` background-
//! step wiring pattern — note that pattern's dual-target scope does NOT
//! carry over here: this test is intentionally `--target dotnet` only,
//! since the bug under test is specific to the self-hosted MSIL backend's
//! codegen, not a language-level construct needing JVM parity):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m89.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Msil.SelfTestM89

import Std.Core
import Std.Collections
import Std.Testing

record Pos {
  line: Int
}

record Tok {
  span: Pos
}

record St {
  pos: Int
}

func advance(st: inout St): Unit {
  st.pos = st.pos + 1
}

// Mirrors `tryEatPunct(st: inout ParseState, p: in Punct): Option[SpannedToken]`
// — mutates its `inout` state as a side effect, then reports Some/None.
func tryEatTok(st: inout St): Option[Tok] {
  advance(st)
  if st.pos == 1 {
    Some(value = Tok(span = Pos(line = 42)))
  } else {
    None
  }
}

// Mirrors `peekSpan(st: in ParseState): Span`.
func peekPos(st: in St): Pos {
  Pos(line = 0)
}

// Mirrors `joinSpans(a: in Span, b: in Span): Span` — the unrelated function
// that NRE'd in the original trigger when handed a corrupted/null value read
// back from the mutated outer var.
func joinPos(a: in Pos, b: in Pos): Pos {
  Pos(line = a.line + b.line)
}

// Mirrors `parseImportDecl`'s exact shape: an outer `var` of `Option[Record]`
// type, mutated from BOTH arms of a `match` (statement position) nested
// inside an `if`-expression's true branch (expression position, itself
// yielding an unrelated `Some(...)` value), read back via a second
// top-level `match` after the `if` completes, then immediately consumed by
// another function call in the same scope — all within a single function,
// with several ordinary locals declared beforehand to raise slot-table
// pressure, exactly as `parseImportDecl` does.
func buildAndJoin(st: inout St, cond: Bool, pathLine: Int): Pos {
  val flagA = true
  val flagB = false
  val pathPos = Pos(line = pathLine)
  var endPos: Option[Pos] = None
  val selector: Option[Pos] = if cond {
    val items: List[Int] = newList()
    var keepGoing = true
    while keepGoing {
      if items.count < 3 {
        items.add(items.count)
      } else {
        keepGoing = false
      }
    }
    match tryEatTok(st) {
      case Some(closeBrace) -> {
        endPos = Some(value = closeBrace.span)
      }
      case None -> {
        advance(st)
        endPos = Some(value = peekPos(st))
      }
    }
    Some(value = Pos(line = items.count))
  } else {
    None
  }
  val _ = selector
  val endSp = match endPos { case Some(sp) -> sp; case None -> pathPos }
  val joined = joinPos(pathPos, endSp)
  val _ = flagA
  val _ = flagB
  joined
}

test "match-inside-if outer-var mutation: Some arm reaches the read-back" {
  var st = St(pos = 0)
  val result = buildAndJoin(st, true, 5)
  assertEqualInt(result.line, 5 + 42, "some_arm_join")
}

test "match-inside-if outer-var mutation: None arm reaches the read-back" {
  var st = St(pos = 5)
  val result = buildAndJoin(st, true, 9)
  assertEqualInt(result.line, 9 + 0, "none_arm_join")
}

test "match-inside-if outer-var mutation: if-false branch never runs the match" {
  var st = St(pos = 0)
  val result = buildAndJoin(st, false, 7)
  assertEqualInt(result.line, 7 + 7, "if_false_uses_path_fallback")
}
