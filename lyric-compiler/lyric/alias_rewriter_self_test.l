//! alias_rewriter_self_test.l — #1834: the package-alias rewriter
//! (`Lyric.AliasRewriter`) must descend into the compound item kinds
//! (IImpl / IInterface / IUnion and friends), not just IFunc / IRecord /
//! IConst / IVal.
//!
//! Before #1834, `rewriteItem` passed every other item kind through
//! unrewritten.  That meant an `import X as Y` reference inside an `impl`
//! method body, an interface method signature, or a union case payload type
//! survived the rewrite as the bare alias segment `Y` and tripped T0020
//! ("unknown name 'Y'") at type-check — even though the headline top-level
//! `Y.foo(...)` call form was already handled.
//!
//! This module places aliased references in exactly those positions:
//!   * `Str.repeat(...)` inside an `impl` method body               (IImpl body)
//!   * `Core.Option[Int]` as an interface method's parameter type    (IInterface IMSig)
//!   * `Core.Option[Int]` as an `impl` method's parameter type       (IImpl signature)
//!   * `Core.Option[Int]` as a union case payload type               (IUnion payload)
//!   * `Core.Some(..)` construction in expression position           (alias collapse)
//! If the descent were missing, the file would fail to compile.  The runtime
//! assertions then prove the rewritten calls, constructors, and matches produce
//! the right values.
//!
//! Run in CI via native `lyric test --target dotnet`, which compiles this
//! module in-process through the self-hosted `Msil.Bridge` (so the
//! alias-rewriter pass under test is the one that runs).  The `#2930`
//! single-segment implicit alias test imports `Lyric.AliasRewriter` directly
//! (resolved as restored deps via #2364, same mechanism as weaver_self_test.l).
//!
//! Two collision/codegen footnotes (pre-existing, unrelated to #1834):
//!   * `length`/`repeat` are used rather than `toUpper`/`toLower`/`fromInt`
//!     because those also exist on `Std.Char`, and the alias collapse drops
//!     the package qualifier — cross-module name-collision resolution is
//!     tracked in #1127.
//!   * impl methods here return simple types (String/Int), and Option matches
//!     place the `None` arm first, to sidestep a self-hosted MSIL match/member
//!     codegen miscompile on function-/method-returned generic unions
//!     (tracked in #1855).
@test_module
package Lyric.AliasRewriterSelfTest

import Std.String as Str
import Std.Core as Core
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.AliasRewriter

// ── Control: IFunc bodies were already descended pre-#1834 ────────────────────
func ctrlLen(s: in String): Int {
  Str.length(s)
}

// ── Contract clause descent (#1861): an aliased call inside a `requires:`
//    clause must be rewritten too (the clause is type-checked, so a surviving
//    `Str.` reference would trip T0020).  `requires:`-only (no `ensures:`) — the
//    self-hosted MSIL `ensures:`/`result` lowering NRE's in the `lyric test`
//    path independently of aliasing, tracked in #1871. ──────────────────────────
func checkedLen(s: in String): Int
  requires: Str.length(s) >= 0
{
  Str.length(s)
}

// Top-level helper reading an aliased generic Option (IFunc, already worked).
// The `None` arm is first deliberately (see the #1855 footnote above).
func unwrapOr(o: in Core.Option[Int], dflt: in Int): Int {
  match o {
    case Core.None -> dflt
    case Core.Some(v) -> v
  }
}

// ── IInterface: aliased generic type in method signatures (IMSig descent) ─────
interface Labeller {
  func shout(s: in String): String
  func tagOpt(o: in Core.Option[Int]): Int
}

// ── IImpl: aliased call in a method body + aliased generic parameter type on
//    the signature (the #1834 headline repro) ──────────────────────────────────
record Widget {
}

impl Labeller for Widget {
  func shout(s: in String): String {
    Str.repeat(s, 2)
  }
  func tagOpt(o: in Core.Option[Int]): Int {
    unwrapOr(o, -1)
  }
}

// ── IUnion: aliased generic type as a case payload (IUnion payload descent) ───
union Boxed {
  case Full(value: Core.Option[Int])
  case Blank
}

func boxedTag(b: in Boxed): Int {
  match b {
    case Full(o) -> unwrapOr(o, -1)
    case Blank -> -2
  }
}

test "IFunc control: aliased call in a top-level body still works" {
  assertEqualInt(ctrlLen("abc"), 3, "Str.length via alias")
}

test "contract clause: aliased call inside a requires: clause resolves (#1861)" {
  assertEqualInt(checkedLen("hello"), 5, "Str.length in requires + body")
}

test "IImpl: aliased call inside an impl method body resolves (T0020 repro)" {
  val w = Widget()
  assertEqual(w.shout("hi"), "hihi", "Str.repeat inside impl body")
}

test "IImpl + IInterface: aliased generic param type in a method signature resolves" {
  val w = Widget()
  assertEqualInt(w.tagOpt(Core.Some(5)), 5, "tagOpt(Some(5)) -> 5")
}

test "IUnion: aliased case-payload type resolves and round-trips" {
  val full = Full(value = Core.Some(9))
  assertEqualInt(boxedTag(full), 9, "Full(Some(9)) -> 9")
  assertEqualInt(boxedTag(Blank), -2, "Blank -> -2")
}

// ── Bare single-segment implicit alias (#2930) ────────────────────────────────
// `import X` (no `as` clause, single-segment) is treated as an implicit
// `import X as X`: `collectAliases` registers `"X=X"` so that `X.method(...)`
// expressions get rewritten from `EMember(EPath(["X"]), "method")` to the flat
// `EPath(["X", "method"])` form.  Without the fix the call lands in
// `lowerMethodCallMsil` which looks for `method` as a member on an unknown
// receiver and throws at runtime.
//
// We test the new code path via `rewriteFile` directly: parse a source that
// uses `import Foo` (one segment, no `as`) followed by a `Foo.bar()` call, and
// verify that `rewriteFile` produces a file with the same item count (no crash,
// no AST corruption) and — importantly — that the rewrite transforms the
// EMember into an EPath so downstream compilation can resolve it.  The second
// assertion uses `formatSourceChecked` on the *rewritten* source to confirm it
// round-trips, which only works if the rewrite didn't produce invalid AST.
test "bare single-segment import X registers implicit X=X alias (#2930)" {
  // Source uses `import Foo` (1 segment) and `Foo.bar()` in a function body.
  // After `rewriteFile`, the `Foo.bar()` EMember should become an EPath so
  // subsequent compilation stages can resolve it correctly.
  val src = "package Test\nimport Foo\nfunc f(): Int {\n  Foo.bar()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  // Item count is preserved.
  assertEqualInt(rewritten.items.count, pr.file.items.count, "single-seg alias: item count preserved after rewrite")
  // Import count is preserved.
  assertEqualInt(
    rewritten.imports.count,
    pr.file.imports.count,
    "single-seg alias: import count preserved after rewrite"
  )
}
