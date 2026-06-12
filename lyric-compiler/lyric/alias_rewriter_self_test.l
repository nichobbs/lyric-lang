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
import Std.Log as Log
import Std.Console
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.AliasRewriter

// ── Control: IFunc bodies were already descended pre-#1834 ────────────────────
func ctrlLen(s: in String): Int {
  Str.length(s)
}

// ── Contract clause descent (#1861): an aliased call inside a `requires:` or
//    `ensures:` clause must be rewritten too (the clauses are type-checked, so
//    a surviving `Str.` reference would trip T0020).  The `ensures:` clause
//    exercises the CCEnsures arm end-to-end (#1875). ──────────────────────────
func checkedLen(s: in String): Int
  requires: Str.length(s) >= 0
  ensures: result == Str.length(s)
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

// ── Where-bound descent (#1860 / #1874): `where T: Log.Logger` references the
//    trait through the `Std.Log as Log` alias; without `rewriteWhereBound` the
//    bound's ConstraintRef head would survive as the bare alias and fail
//    resolution (and a qualified rewrite would trip the type checker's T0051
//    "qualified constraint paths not yet supported").  `Std.Log` is used
//    rather than `Std.Stream` because its per-package runtime assembly is in
//    the staged stdlib set the in-process `lyric test` path can load. ─────────
record ProbeLogger {
}

impl Log.Logger for ProbeLogger {
  func log(level: in LogLevel, msg: in String, fields: in slice[LogField]): Unit {
    ()
  }
}

func logAndReport[T](x: in T): Int
  where T: Log.Logger
{
  x.log(Info, "where-bound probe", [])
  7
}

test "IFunc control: aliased call in a top-level body still works" {
  assertEqualInt(ctrlLen("abc"), 3, "Str.length via alias")
}

test "contract clause: aliased call inside requires: and ensures: resolves (#1861, #1875)" {
  assertEqualInt(checkedLen("hello"), 5, "Str.length in requires + ensures + body")
}

test "where-bound: aliased trait in `where T: Log.Logger` resolves (#1860, #1874)" {
  val p: ProbeLogger = ProbeLogger()
  assertEqualInt(logAndReport(p), 7, "logAndReport(ProbeLogger) -> 7")
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
// verify that `rewriteFile` collapses the `EMember` receiver into an `EPath`.
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
  // The `Foo.bar()` call in the function body must have been rewritten from
  // `ECall(fn=EMember(EPath(["Foo"]), "bar"), ...)` to
  // `ECall(fn=EPath(["Foo","bar"]), ...)`.
  // Navigate: items[0] -> IFunc -> body -> FBBlock -> statements[0] -> SExpr -> expr.
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              // Guard the index so a rewriter regression that empties the
              // block fails with an assertion message, not a panic (#3163).
              assertTrue(block.statements.count > 0, "function body block must have at least one statement")
              val stmt = block.statements[0]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EPath(_) -> assertTrue(true, "call fn is EPath after rewrite")
                        case EMember(_, _) -> assertTrue(false, "call fn is still EMember — rewrite did not collapse single-seg alias")
                        case _ -> assertTrue(false, "call fn is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "first statement is not SExpr")
              }
            }
            case FBExpr(_) -> assertTrue(false, "function body is FBExpr, expected FBBlock")
          }
        }
        case None -> assertTrue(false, "function decl has no body")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// ── Bare multi-segment implicit alias (#2929) ────────────────────────────────
// `import Foo.Bar` (no `as` clause, >1 segment) registers the tail segment as
// an implicit alias for the full dotted path, so `Bar.baz()` is rewritten from
// `EMember(EPath(["Bar"]), "baz")` to the flat `EPath(["Foo","Bar","baz"])`.
// Before the fix only single-segment bare imports got the implicit alias, so
// multi-segment forms still misrouted to `lowerMethodCallMsil` and threw at
// runtime.
test "bare multi-segment import Foo.Bar registers implicit Bar=Foo.Bar alias (#2929)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  assertEqualInt(rewritten.items.count, pr.file.items.count, "multi-seg alias: item count preserved after rewrite")
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertTrue(block.statements.count > 0, "function body block must have at least one statement")
              val stmt = block.statements[0]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EPath(p) -> assertEqualInt(p.segments.count, 3, "call fn is the fully-qualified Foo.Bar.baz path after rewrite")
                        case EMember(_, _) -> assertTrue(false, "call fn is still EMember — rewrite did not collapse the multi-seg bare-import alias")
                        case _ -> assertTrue(false, "call fn is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "first statement is not SExpr")
              }
            }
            case FBExpr(_) -> assertTrue(false, "function body is FBExpr, expected FBBlock")
          }
        }
        case None -> assertTrue(false, "function decl has no body")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// An explicit `as` alias claims its name before any bare import's implicit
// tail alias: with `import Other.Thing as Bar` + bare `import Foo.Bar`, the
// `Bar` head must rewrite to `Other.Thing`, not `Foo.Bar`.
test "explicit alias wins over a bare import's implicit tail alias (#2929)" {
  val src = "package Test\nimport Foo.Bar\nimport Other.Thing as Bar\nfunc f(): Int {\n  Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertTrue(block.statements.count > 0, "function body block must have at least one statement")
              val stmt = block.statements[0]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EPath(p) -> {
                          assertEqualInt(p.segments.count, 3, "call fn rewritten through the explicit alias")
                          assertEqual(p.segments[0], "Other", "explicit alias target package wins over the bare import")
                        }
                        case _ -> assertTrue(false, "call fn is not EPath after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "first statement is not SExpr")
              }
            }
            case FBExpr(_) -> assertTrue(false, "function body is FBExpr, expected FBBlock")
          }
        }
        case None -> assertTrue(false, "function decl has no body")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// Two bare imports sharing a tail segment resolve first-wins in source
// order with no diagnostic (documented in collectAliases, #3250): `Bar`
// routes to `Foo.Bar`, the earlier import.
test "duplicate bare import tails: first bare import wins deterministically (#3250)" {
  val src = "package Test\nimport Foo.Bar\nimport Other.Bar\nfunc f(): Int {\n  Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertTrue(block.statements.count > 0, "function body block must have at least one statement")
              val stmt = block.statements[0]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EPath(p) -> {
                          assertEqualInt(p.segments.count, 3, "call fn rewritten through the implicit tail alias")
                          assertEqual(p.segments[0], "Foo", "first bare import in source order wins the shared tail")
                        }
                        case _ -> assertTrue(false, "call fn is not EPath after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "first statement is not SExpr")
              }
            }
            case FBExpr(_) -> assertTrue(false, "function body is FBExpr, expected FBBlock")
          }
        }
        case None -> assertTrue(false, "function decl has no body")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// Runtime end-to-end for #2929: this module itself bare-imports `Std.Console`
// (multi-segment, no `as`) in its header.  Before the fix, `Console.println`
// compiled but threw "unsupported method 'println' on the receiver type" at
// runtime; with the implicit tail alias it routes to the static stdlib call.
test "runtime: bare `import Std.Console` routes Console.println correctly (#2929)" {
  Console.println("alias rewriter #2929: bare multi-segment import works")
  assertTrue(true, "Console.println via a bare multi-segment import did not throw")
}
