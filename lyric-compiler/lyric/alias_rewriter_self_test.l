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

// ── Bare multi-segment import referenced by its FULL dotted form (#6294) ──────
// `import Foo.Bar` (no `as`) registers BOTH the tail-only implicit alias
// (`Bar=Foo.Bar`, #2929 above) and a self-mapped full-path key
// (`Foo.Bar=Foo.Bar`, #6294): a call site can spell the qualifier out in
// full, `Foo.Bar.baz()`, not just the short `Bar.baz()` form. The parser
// produces the full form as a DEPTH-2 `EMember` chain
// (`EMember(EMember(EPath(["Foo"]), "Bar"), "baz")`) — before #6294 the
// rewriter's `EMember` arm only ever inspected a receiver that was itself a
// single-segment bare `EPath`, so a two-dot chain like this fell through
// unrewritten. That silently mistyped the whole expression: with no
// resolvable callee, `ECall`'s final fallback returns bare `TyError` with
// NO diagnostic (the same silent-wildcard mechanism `typeEquiv` uses
// everywhere else), so a cross-package call into a dotted-name package's
// function compiled clean yet its result satisfied ANY expected type at
// every call site (a `Result[...]` return silently accepted into an
// unrelated `slice[...]`-typed record field, for instance) — see
// docs/03-decision-log.md's #6294 entry for the full trace.
test "bare multi-segment import referenced by its full Foo.Bar.baz() form rewrites (#6294)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  assertEqualInt(rewritten.items.count, pr.file.items.count, "full-path form: item count preserved after rewrite")
  // Pre-rewrite receiver span, navigated from the UNREWRITTEN tree: the
  // synthesized `ModulePath`'s own span must match this exactly (just
  // `Foo.Bar`), not the whole call's span (`Foo.Bar.baz()`) — a synthesized
  // node using too wide a span is a real (if currently inert) regression
  // risk for any diagnostic or LSP feature that keys off it directly.
  val origReceiverSpan = match pr.file.items[0].kind {
    case IFunc(origDecl) -> match origDecl.body { case Some(origFb) -> match origFb { case FBBlock(origBlock) -> match origBlock.statements[0].kind { case SExpr(origCallExpr) -> match origCallExpr.kind { case ECall(origFn, _) -> match origFn.kind { case EMember(origReceiver, _) -> origReceiver.span; case _ -> origFn.span }; case _ -> origCallExpr.span }; case _ -> origBlock.span }; case FBExpr(origExpr) -> origExpr.span }; case None -> pointSpan(initialPosition()) }
    case _ -> pointSpan(initialPosition())
  }
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
                          assertEqualInt(p.segments.count, 3, "call fn is the fully-qualified Foo.Bar.baz path after rewrite")
                          assertEqual(p.segments[0], "Foo", "rewritten path keeps the real package's first segment")
                          assertEqual(p.segments[1], "Bar", "rewritten path keeps the real package's second segment")
                          assertEqual(p.segments[2], "baz", "rewritten path keeps the call's own member name")
                          assertEqualInt(
                            p.span.startPos.offset,
                            origReceiverSpan.startPos.offset,
                            "synthesized ModulePath span starts where the original Foo.Bar receiver started, not the whole call"
                          )
                          assertEqualInt(
                            p.span.endPos.offset,
                            origReceiverSpan.endPos.offset,
                            "synthesized ModulePath span ends where the original Foo.Bar receiver ended (excludes .baz() entirely)"
                          )
                        }
                        case EMember(_, _) -> assertTrue(false, "call fn is still a nested EMember — the full-path form was not collapsed (#6294)")
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

// A THREE-segment bare import (`import Foo.Bar.Baz`) referenced by its full
// form must also collapse — #6294's fix walks the whole `EMember` chain, not
// just one extra level, so this must not regress back to a depth-1-only fix.
test "bare three-segment import referenced by its full Foo.Bar.Baz.qux() form rewrites (#6294)" {
  val src = "package Test\nimport Foo.Bar.Baz\nfunc f(): Int {\n  Foo.Bar.Baz.qux()\n}\n"
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
                        case EPath(p) -> assertEqualInt(p.segments.count, 4, "call fn is the fully-qualified Foo.Bar.Baz.qux path after rewrite")
                        case EMember(_, _) -> assertTrue(false, "call fn is still a nested EMember — the three-segment full-path form was not collapsed (#6294)")
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

// A NON-call qualified reference (bare value/field access, no trailing
// `()`) into a multi-segment bare-imported package must NOT be touched by
// the #6294 generalization at all, even though the SAME dotted chain would
// collapse if it were a call. The deep-flatten rewrite lives only in the
// `ECall` arm's callee handling (`alias_rewriter.l`), specifically so a
// plain value/field-access chain keeps its existing, scope-aware resolution
// downstream (MSIL's `tryQualifiedStaticValNameMsil`, which guards against a
// LOCAL binding shadowing the chain's root — the aliaser itself has no scope
// information to do that check safely). An earlier version of this fix
// applied the generalization in the general `EMember` arm too, and broke
// `msil_project_bridge_self_test.l`'s "local shadowing a package name"
// regression case: a local `val ShadowVal = ...` whose own `Lib.secret`
// field chain collided with the unrelated bare-imported `ShadowVal.Lib`
// package's `pub val secret`, silently reading the wrong value. This test
// asserts the non-call chain survives `rewriteFile` completely unchanged
// (still the original nested `EMember`s) so that regression can't resurface.
test "bare multi-segment import referenced by its full form as a non-call value reference is left untouched (#6294)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  val x = Foo.Bar.someConst\n  0\n}\n"
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
                case SLocal(lb) -> {
                  match lb {
                    case LBVal(_, _, initExpr) -> {
                      match initExpr.kind {
                        case EMember(recv1, m1) -> {
                          assertEqual(m1, "someConst", "outermost node is still EMember (unrewritten) for a non-call chain")
                          match recv1.kind {
                            case EMember(recv0, m0) -> {
                              assertEqual(m0, "Bar", "middle node is still EMember (unrewritten)")
                              match recv0.kind {
                                case EPath(p0) -> {
                                  assertEqualInt(p0.segments.count, 1, "innermost node is still the bare single-segment EPath")
                                  assertEqual(p0.segments[0], "Foo", "innermost EPath still names the first raw segment")
                                }
                                case _ -> assertTrue(false, "innermost receiver is not EPath — chain was rewritten (#6294 regression)")
                              }
                            }
                            case EPath(_) -> assertTrue(false, "chain was flattened into EPath — non-call qualified reference must stay untouched (#6294 regression)")
                            case _ -> assertTrue(false, "middle receiver is unexpected ExprKind")
                          }
                        }
                        case EPath(_) -> assertTrue(false, "chain was flattened into EPath — non-call qualified reference must stay untouched (#6294 regression)")
                        case _ -> assertTrue(false, "val initializer is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "local binding is not LBVal")
                  }
                }
                case _ -> assertTrue(false, "first statement is not SLocal")
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

// Longest-match-wins precedence (#6294): with BOTH a bare `import Foo` and a
// bare `import Foo.Bar` in scope, `Foo.Bar.baz()` must resolve against the
// more specific `Foo.Bar` package, not as a member access into package
// `Foo`'s own exported `Bar` value. `rewriteQualifiedMemberChain` checks the
// WHOLE flattened receiver chain in one shot (never a partial prefix), so
// the 2-segment match against the full `Foo.Bar.baz` chain is tried before
// any shorter interpretation gets a chance via recursion — the more specific
// import always wins silently, with no ambiguity diagnostic, mirroring the
// codebase's existing no-diagnostic first-wins precedent for tail-alias
// collisions (#3250).
test "longest matching package prefix wins when a shorter sibling import is also in scope (#6294)" {
  val src = "package Test\nimport Foo\nimport Foo.Bar\nfunc f(): Int {\n  Foo.Bar.baz()\n}\n"
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
                          assertEqualInt(p.segments.count, 3, "call fn is the fully-qualified Foo.Bar.baz path after rewrite")
                          assertEqual(p.segments[0], "Foo", "rewritten path keeps the longer package's first segment")
                          assertEqual(
                            p.segments[1],
                            "Bar",
                            "rewritten path keeps the longer package's second segment (not collapsed as a member of bare Foo)"
                          )
                        }
                        case EMember(_, _) -> assertTrue(false, "call fn is still EMember — neither prefix length was matched (#6294)")
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

// An explicitly aliased import (#6294 follow-up) can ALSO still be called
// through its original dotted name, not just through the alias — the
// original name parses to exactly the same qualified-call `EMember` chain
// shape a bare multi-segment import's full form does, so it needs the same
// self-mapped full-path key `collectAliases` registers for bare imports.
test "explicit alias import is also callable via its original dotted name (#6294)" {
  val src = "package Test\nimport Foo.Bar as X\nfunc f(): Int {\n  Foo.Bar.baz()\n}\n"
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
                          assertEqualInt(p.segments.count, 3, "call fn is the fully-qualified Foo.Bar.baz path after rewrite")
                          assertEqual(p.segments[0], "Foo", "rewritten path keeps the real package's first segment")
                          assertEqual(p.segments[1], "Bar", "rewritten path keeps the real package's second segment")
                          assertEqual(p.segments[2], "baz", "rewritten path keeps the call's own member name")
                        }
                        case EMember(_, _) -> assertTrue(false, "call fn is still EMember — calling via the original dotted name after aliasing was not collapsed (#6294)")
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

// Scope-awareness regression (#6311): the `ECall`-callee generalization above
// (#6294) treats ANY multi-segment chain spelling out a known package's full
// dotted path as that package — but a local variable's own field-access call
// chain can spell out the exact same dotted name by coincidence. Depth-1
// collisions (`Bar.baz()` after `import Foo.Bar` with a local also named
// `Bar`) are a pre-existing, documented gap (this file's header) predating
// #6294 entirely — NOT what this test guards. This guards the NEW hazard
// #6294 introduced: a depth-2+ chain (`Foo.Bar.baz()`) whose ROOT segment
// (`Foo`) is a local in the SAME function must NOT be collapsed into the
// unrelated `Foo.Bar` package's `EPath`, even though `import Foo.Bar`
// registers exactly that dotted string as a self-mapped alias key. Before
// the #6311 fix, this collapsed unconditionally; the fix collects every name
// bound anywhere in the enclosing function and strips any alias whose key's
// first segment collides with one of them before rewriting the body — see
// `filterAliasesExcludingLocals` in alias_rewriter.l.
test "a local shadowing a bare-imported package's dotted name is left untouched, not collapsed into the package (#6311)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  val Foo = 0\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertEqualInt(block.statements.count, 2, "function body has the local decl plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(receiver, memberName) -> {
                          assertEqual(memberName, "baz", "outer member name is still the call's own 'baz'")
                          match receiver.kind {
                            case EMember(innerReceiver, innerMember) -> {
                              assertEqual(innerMember, "Bar", "inner member name is still 'Bar' — chain was not flattened")
                              match innerReceiver.kind {
                                case EPath(p) -> {
                                  assertEqualInt(p.segments.count, 1, "innermost receiver is still the bare single-segment 'Foo'")
                                  assertEqual(p.segments[0], "Foo", "innermost receiver segment is still 'Foo', unrewritten")
                                }
                                case _ -> assertTrue(false, "innermost receiver is not EPath — chain shape changed unexpectedly (#6311 regression)")
                              }
                            }
                            case _ -> assertTrue(false, "receiver is not EMember — chain was flattened despite the local shadow (#6311 regression)")
                          }
                        }
                        case EPath(_) -> assertTrue(false, "call fn was collapsed into a flat EPath — a local `Foo` should have suppressed the Foo.Bar package collapse (#6311 regression)")
                        case _ -> assertTrue(false, "call fn is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
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

// Scope-awareness regression, module scope (#6312): #6311 only collected
// names bound INSIDE a function's own body/params, so a module-level
// `val`/`const` whose name collides with a bare-imported package's first
// dotted segment was still silently collapsed and misrouted when called
// from a DIFFERENT function than the one it's textually declared next to —
// module-level `val`s are visible, unqualified, from every function in the
// file, not just a lexically-local one. `collectModuleLevelValueNames`
// (computed once in `rewriteFile`, before any item is rewritten) closes
// this the same way #6311 did for function-locals, just at file scope.
test "a module-level val shadowing a bare-imported package's dotted name is left untouched in every function, not collapsed into the package (#6312)" {
  val src = "package Test\nimport Foo.Bar\nval Foo = 0\nfunc f(): Int {\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  assertEqualInt(rewritten.items.count, 2, "module val item plus the function item")
  val fnItem = rewritten.items[1]
  match fnItem.kind {
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
                        case EMember(receiver, memberName) -> {
                          assertEqual(memberName, "baz", "outer member name is still the call's own 'baz'")
                          match receiver.kind {
                            case EMember(innerReceiver, innerMember) -> {
                              assertEqual(innerMember, "Bar", "inner member name is still 'Bar' — chain was not flattened")
                              match innerReceiver.kind {
                                case EPath(p) -> {
                                  assertEqualInt(p.segments.count, 1, "innermost receiver is still the bare single-segment 'Foo'")
                                  assertEqual(p.segments[0], "Foo", "innermost receiver segment is still 'Foo', unrewritten")
                                }
                                case _ -> assertTrue(false, "innermost receiver is not EPath — chain shape changed unexpectedly (#6312 regression)")
                              }
                            }
                            case _ -> assertTrue(false, "receiver is not EMember — chain was flattened despite the module-level val shadow (#6312 regression)")
                          }
                        }
                        case EPath(_) -> assertTrue(false, "call fn was collapsed into a flat EPath — a module-level val `Foo` should have suppressed the Foo.Bar package collapse (#6312 regression)")
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
    case _ -> assertTrue(false, "second item is not IFunc")
  }
}

// Scope-awareness regression, contract clauses (#6313): #6311's fix computes
// a scope-filtered `bodyAliases` in `rewriteFunctionDecl` and threads it into
// the function BODY rewrite — but `requires:`/`ensures:` clauses reference
// the function's own params directly too, and the original fix still passed
// them the raw, unfiltered `aliases`. A param whose name collides with a
// bare-imported package's dotted name would still silently misroute inside
// a `requires:`/`ensures:` clause even after #6311/#6312 closed the same
// hazard for the body. Fixed by reusing the SAME `bodyAliases` (which
// already includes every param name via `collectParamNames`) for
// `rewriteContracts` too.
test "a param shadowing a bare-imported package's dotted name is left untouched inside a requires: clause, not collapsed into the package (#6313)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(Foo: in Int): Int\n  requires: Foo.Bar.baz() > 0\n{\n  0\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      assertEqualInt(decl.contracts.count, 1, "function has exactly the one requires: clause")
      match decl.contracts[0] {
        case CCRequires(expr, _) -> {
          match expr.kind {
            case EBinop(_, lhs, _) -> {
              match lhs.kind {
                case ECall(fn, _) -> {
                  match fn.kind {
                    case EMember(receiver, memberName) -> {
                      assertEqual(memberName, "baz", "outer member name is still the call's own 'baz'")
                      match receiver.kind {
                        case EMember(innerReceiver, innerMember) -> {
                          assertEqual(innerMember, "Bar", "inner member name is still 'Bar' — chain was not flattened")
                          match innerReceiver.kind {
                            case EPath(p) -> {
                              assertEqualInt(p.segments.count, 1, "innermost receiver is still the bare single-segment 'Foo'")
                              assertEqual(p.segments[0], "Foo", "innermost receiver segment is still 'Foo', unrewritten")
                            }
                            case _ -> assertTrue(false, "innermost receiver is not EPath — chain shape changed unexpectedly (#6313 regression)")
                          }
                        }
                        case _ -> assertTrue(false, "receiver is not EMember — chain was flattened despite the param shadow (#6313 regression)")
                      }
                    }
                    case EPath(_) -> assertTrue(false, "requires: call was collapsed into a flat EPath — a param `Foo` should have suppressed the Foo.Bar package collapse (#6313 regression)")
                    case _ -> assertTrue(false, "requires: call is unexpected ExprKind after rewrite")
                  }
                }
                case _ -> assertTrue(false, "requires: lhs is not ECall")
              }
            }
            case _ -> assertTrue(false, "requires: expr is not EBinop")
          }
        }
        case _ -> assertTrue(false, "contract clause is not CCRequires")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// Scope-awareness regression, wire params (#6316): `WireDecl.params` is a
// function-like parameter scope — exactly analogous to `FunctionDecl.params`
// (#6311) — visible to every member's own `init` expression, but
// `rewriteWireDecl` never collected it into a locals set before this fix, so
// a wire param colliding with a bare-imported package's dotted name still
// collapsed unconditionally inside a `singleton` member's init.
test "a wire param shadowing a bare-imported package's dotted name is left untouched inside a singleton member's init, not collapsed into the package (#6316)" {
  val src = "package Test\nimport Foo.Bar\nwire W(Foo: in Int) {\n  singleton x: Int = Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IWire(decl) -> {
      assertEqualInt(decl.members.count, 1, "wire has exactly the one singleton member")
      match decl.members[0] {
        case WMSingleton(_, _, init, _) -> {
          match init.kind {
            case ECall(fn, _) -> {
              match fn.kind {
                case EMember(receiver, memberName) -> {
                  assertEqual(memberName, "baz", "outer member name is still the call's own 'baz'")
                  match receiver.kind {
                    case EMember(innerReceiver, innerMember) -> {
                      assertEqual(innerMember, "Bar", "inner member name is still 'Bar' — chain was not flattened")
                      match innerReceiver.kind {
                        case EPath(p) -> {
                          assertEqualInt(p.segments.count, 1, "innermost receiver is still the bare single-segment 'Foo'")
                          assertEqual(p.segments[0], "Foo", "innermost receiver segment is still 'Foo', unrewritten")
                        }
                        case _ -> assertTrue(false, "innermost receiver is not EPath — chain shape changed unexpectedly (#6316 regression)")
                      }
                    }
                    case _ -> assertTrue(false, "receiver is not EMember — chain was flattened despite the wire param shadow (#6316 regression)")
                  }
                }
                case EPath(_) -> assertTrue(false, "singleton init was collapsed into a flat EPath — a wire param `Foo` should have suppressed the Foo.Bar package collapse (#6316 regression)")
                case _ -> assertTrue(false, "singleton init is unexpected ExprKind after rewrite")
              }
            }
            case _ -> assertTrue(false, "singleton init is not ECall")
          }
        }
        case _ -> assertTrue(false, "wire member is not WMSingleton")
      }
    }
    case _ -> assertTrue(false, "first item is not IWire")
  }
}

// Scope-awareness regression, config field default (#6316): a config field's
// `default` expression can itself be an arbitrary lambda (a bare `{ ... }` in
// expression position parses as a zero-arg `ELambda`, not `EBlock` —
// `parsePrimaryExpr`'s `LBrace` arm always goes through `parseLambdaExpr`)
// introducing its own local bindings, exactly like `rewriteFixtureDecl`'s
// `init` (which already gets this self-referential filtering). Before this
// fix, `rewriteConfigField` rewrote `default` with the raw, unfiltered
// `aliases`.
test "a local bound inside a config field's default lambda shadows a bare-imported package's dotted name, left untouched (#6316)" {
  val src = "package Test\nimport Foo.Bar\nconfig C {\n  x: Int = {\n    val Foo = 0\n    Foo.Bar.baz()\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IConfig(decl) -> {
      assertEqualInt(decl.fields.count, 1, "config has exactly the one field")
      match decl.fields[0].default {
        case Some(defaultExpr) -> {
          match defaultExpr.kind {
            case ELambda(_, block) -> {
              assertEqualInt(block.statements.count, 2, "default lambda body has the local decl plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6316 regression)")
                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
              }
            }
            case _ -> assertTrue(false, "default expr is not ELambda")
          }
        }
        case None -> assertTrue(false, "config field has no default")
      }
    }
    case _ -> assertTrue(false, "first item is not IConfig")
  }
}

// Coverage follow-up (#6313): the fifth finding's fix threads `contractAliases`
// into an `AspectDecl`'s own top-level `contracts` too, not just its `around`
// body — this locks that in with a dedicated case (the #6313 test only
// covered function/entry/sig `requires:`). `argsName` is chosen as `Foo` so it
// collides with the bare-imported `Foo.Bar` package's first dotted segment;
// the aspect's own `requires:` references `Foo.Bar.baz()` directly.
test "an aspect's own requires: clause with an args-name colliding with a bare-imported package's dotted name is left untouched (#6313 coverage)" {
  val src = "package Test\nimport Foo.Bar\naspect Guard {\n  matches: name like \"handle*\"\n  requires: Foo.Bar.baz() > 0\n  around(Foo) -> ret {\n    ret = proceed(Foo)\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IAspect(decl) -> {
      assertEqualInt(decl.contracts.count, 1, "aspect has exactly the one requires: clause")
      match decl.contracts[0] {
        case CCRequires(expr, _) -> {
          match expr.kind {
            case EBinop(_, lhs, _) -> {
              match lhs.kind {
                case ECall(fn, _) -> {
                  match fn.kind {
                    case EMember(receiver, memberName) -> {
                      assertEqual(memberName, "baz", "outer member name is still the call's own 'baz'")
                      match receiver.kind {
                        case EMember(innerReceiver, innerMember) -> {
                          assertEqual(innerMember, "Bar", "inner member name is still 'Bar' — chain was not flattened")
                          match innerReceiver.kind {
                            case EPath(p) -> {
                              assertEqualInt(p.segments.count, 1, "innermost receiver is still the bare single-segment 'Foo'")
                              assertEqual(p.segments[0], "Foo", "innermost receiver segment is still 'Foo', unrewritten")
                            }
                            case _ -> assertTrue(false, "innermost receiver is not EPath — chain shape changed unexpectedly")
                          }
                        }
                        case _ -> assertTrue(false, "receiver is not EMember — chain was flattened despite the args-name shadow")
                      }
                    }
                    case EPath(_) -> assertTrue(false, "requires: call was collapsed into a flat EPath — the aspect's own args-name `Foo` should have suppressed the Foo.Bar package collapse")
                    case _ -> assertTrue(false, "requires: call is unexpected ExprKind after rewrite")
                  }
                }
                case _ -> assertTrue(false, "requires: lhs is not ECall")
              }
            }
            case _ -> assertTrue(false, "requires: expr is not EBinop")
          }
        }
        case _ -> assertTrue(false, "contract clause is not CCRequires")
      }
    }
    case _ -> assertTrue(false, "first item is not IAspect")
  }
}

// Coverage follow-up (#6316): `rewriteIncludeAdjusts`'s `IAProvided`/
// `IAConfigOverride`/`IAReplace` value-filtering shares the same
// `filterAliasesForExpr` call as the wire-singleton/config-default cases
// already tested — this locks in the `IAReplace` form specifically. The
// adjustment's own value is a lambda (`{ ... }`) binding a local `Foo` before
// calling `Foo.Bar.baz()`, exactly like the config-field-default case above.
test "an include adjustment's value binding its own local shadows a bare-imported package's dotted name, left untouched (#6316 coverage)" {
  val src = "package Test\nimport Foo.Bar\nwire W {\n  include Some.Template {\n    someName = {\n      val Foo = 0\n      Foo.Bar.baz()\n    }\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IWire(decl) -> {
      assertEqualInt(decl.members.count, 1, "wire has exactly the one include member")
      match decl.members[0] {
        case WMInclude(_, _, adjustments, _, _) -> {
          assertEqualInt(adjustments.count, 1, "include has exactly the one adjustment")
          match adjustments[0] {
            case IAReplace(_, value, _) -> {
              match value.kind {
                case ELambda(_, block) -> {
                  assertEqualInt(block.statements.count, 2, "adjustment lambda body has the local decl plus the call statement")
                  val stmt = block.statements[1]
                  match stmt.kind {
                    case SExpr(callExpr) -> {
                      match callExpr.kind {
                        case ECall(fn, _) -> {
                          match fn.kind {
                            case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                            case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6316 regression)")
                            case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                          }
                        }
                        case _ -> assertTrue(false, "statement expression is not ECall")
                      }
                    }
                    case _ -> assertTrue(false, "second statement is not SExpr")
                  }
                }
                case _ -> assertTrue(false, "adjustment value is not ELambda")
              }
            }
            case _ -> assertTrue(false, "adjustment is not IAReplace")
          }
        }
        case _ -> assertTrue(false, "wire member is not WMInclude")
      }
    }
    case _ -> assertTrue(false, "first item is not IWire")
  }
}

// Scope-awareness regression, param default (#6320): `rewriteParam`'s
// `dflt` can itself be a lambda (a bare `{ ... }`) introducing its own
// shadowing locals, exactly like the config-field-default and
// include-adjustment-value cases above.
test "a local bound inside a function param's default lambda shadows a bare-imported package's dotted name, left untouched (#6320)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(x: in Int = {\n  val Foo = 0\n  Foo.Bar.baz()\n}): Int {\n  x\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      assertEqualInt(decl.params.count, 1, "function has exactly the one param")
      match decl.params[0].dflt {
        case Some(defaultExpr) -> {
          match defaultExpr.kind {
            case ELambda(_, block) -> {
              assertEqualInt(block.statements.count, 2, "param default lambda body has the local decl plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6320 regression)")
                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
              }
            }
            case _ -> assertTrue(false, "param default is not ELambda")
          }
        }
        case None -> assertTrue(false, "param has no default")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// Scope-awareness regression, record field default (#6320): `rewriteFieldDecl`'s
// `dflt` shares the exact same self-referential hazard.
test "a local bound inside a record field's default lambda shadows a bare-imported package's dotted name, left untouched (#6320)" {
  val src = "package Test\nimport Foo.Bar\nrecord R {\n  x: Int = {\n    val Foo = 0\n    Foo.Bar.baz()\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IRecord(decl) -> {
      assertEqualInt(decl.members.count, 1, "record has exactly the one member")
      match decl.members[0] {
        case RMField(field) -> {
          match field.dflt {
            case Some(defaultExpr) -> {
              match defaultExpr.kind {
                case ELambda(_, block) -> {
                  assertEqualInt(block.statements.count, 2, "field default lambda body has the local decl plus the call statement")
                  val stmt = block.statements[1]
                  match stmt.kind {
                    case SExpr(callExpr) -> {
                      match callExpr.kind {
                        case ECall(fn, _) -> {
                          match fn.kind {
                            case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                            case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6320 regression)")
                            case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                          }
                        }
                        case _ -> assertTrue(false, "statement expression is not ECall")
                      }
                    }
                    case _ -> assertTrue(false, "second statement is not SExpr")
                  }
                }
                case _ -> assertTrue(false, "field default is not ELambda")
              }
            }
            case None -> assertTrue(false, "field has no default")
          }
        }
        case _ -> assertTrue(false, "record member is not RMField")
      }
    }
    case _ -> assertTrue(false, "first item is not IRecord")
  }
}

// Scope-awareness regression, wire singleton init (#6320): the reviewer
// flagged this as the most reachable form in practice — `singleton x: T =
// { ... }` is docs/58's idiomatic construction syntax. `rewriteWireMember`'s
// `init` now gets the same self-referential filtering on top of the
// wire-level `memberAliases` #6316 already threads in.
test "a local bound inside a wire singleton's init lambda shadows a bare-imported package's dotted name, left untouched (#6320)" {
  val src = "package Test\nimport Foo.Bar\nwire W {\n  singleton x: Int = {\n    val Foo = 0\n    Foo.Bar.baz()\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IWire(decl) -> {
      assertEqualInt(decl.members.count, 1, "wire has exactly the one singleton member")
      match decl.members[0] {
        case WMSingleton(_, _, init, _) -> {
          match init.kind {
            case ELambda(_, block) -> {
              assertEqualInt(block.statements.count, 2, "singleton init lambda body has the local decl plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6320 regression)")
                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
              }
            }
            case _ -> assertTrue(false, "singleton init is not ELambda")
          }
        }
        case _ -> assertTrue(false, "wire member is not WMSingleton")
      }
    }
    case _ -> assertTrue(false, "first item is not IWire")
  }
}

// Scope-awareness regression, module-level val/const init (#6321): a
// module-level `val`/`const`'s own `init` can itself be a lambda (a bare
// `{ ... }`) introducing its own shadowing locals, exactly like every
// other standalone-expression position #6316/#6320 already cover.
test "a local bound inside a module-level val's init lambda shadows a bare-imported package's dotted name, left untouched (#6321)" {
  val src = "package Test\nimport Foo.Bar\nval x: Int = {\n  val Foo = 0\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IVal(decl) -> {
      match decl.init.kind {
        case ELambda(_, block) -> {
          assertEqualInt(block.statements.count, 2, "val init lambda body has the local decl plus the call statement")
          val stmt = block.statements[1]
          match stmt.kind {
            case SExpr(callExpr) -> {
              match callExpr.kind {
                case ECall(fn, _) -> {
                  match fn.kind {
                    case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                    case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6321 regression)")
                    case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                  }
                }
                case _ -> assertTrue(false, "statement expression is not ECall")
              }
            }
            case _ -> assertTrue(false, "second statement is not SExpr")
          }
        }
        case _ -> assertTrue(false, "val init is not ELambda")
      }
    }
    case _ -> assertTrue(false, "first item is not IVal")
  }
}

// No analogous `const` case: `IConst`/`ConstDecl` has no keyword production
// in the lexer at all (no `KwConst` — confirmed by grepping the keyword
// table and every self-test suite in the repo for a real `"const ..."`
// source snippet; none exists). It is unreachable dead AST surface from
// real parsed source today, so a `const`-flavored regression test here
// would test nothing real. The `rewriteItem` `IConst` arm fix lands anyway
// (mirrors its `IVal` sibling, costs nothing, and is future-proofed for
// whenever/if `const` gains a real surface syntax) but isn't independently
// covered by a test for that reason.
// #6321 SUGGESTION follow-up: a record invariant clause's own expr can
// likewise be a lambda introducing its own shadowing locals.
test "a local bound inside a record invariant's lambda shadows a bare-imported package's dotted name, left untouched (#6321 coverage)" {
  val src = "package Test\nimport Foo.Bar\nrecord R {\n  x: Int\n  invariant: {\n    val Foo = 0\n    Foo.Bar.baz()\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IRecord(decl) -> {
      assertEqualInt(decl.members.count, 2, "record has the field plus the invariant member")
      match decl.members[1] {
        case RMInvariant(inv) -> {
          match inv.expr.kind {
            case ELambda(_, block) -> {
              assertEqualInt(block.statements.count, 2, "invariant lambda body has the local decl plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6321 regression)")
                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
              }
            }
            case _ -> assertTrue(false, "invariant expr is not ELambda")
          }
        }
        case _ -> assertTrue(false, "second record member is not RMInvariant")
      }
    }
    case _ -> assertTrue(false, "first item is not IRecord")
  }
}

// Scope-awareness regression, protected var-field init (#6323): `rewriteProtectedField`'s
// `PFVar`/`PFLet` `init` shares the exact same self-referential hazard every
// other standalone-expression position in this file already guards against.
test "a local bound inside a protected type's var-field init lambda shadows a bare-imported package's dotted name, left untouched (#6323)" {
  val src = "package Test\nimport Foo.Bar\nprotected type P {\n  var x: Int = {\n    val Foo = 0\n    Foo.Bar.baz()\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IProtected(decl) -> {
      assertEqualInt(decl.members.count, 1, "protected type has exactly the one var field")
      match decl.members[0] {
        case PMField(field) -> {
          match field {
            case PFVar(_, _, init, _, _, _) -> {
              match init {
                case Some(defaultExpr) -> {
                  match defaultExpr.kind {
                    case ELambda(_, block) -> {
                      assertEqualInt(block.statements.count, 2, "var-field init lambda body has the local decl plus the call statement")
                      val stmt = block.statements[1]
                      match stmt.kind {
                        case SExpr(callExpr) -> {
                          match callExpr.kind {
                            case ECall(fn, _) -> {
                              match fn.kind {
                                case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                                case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6323 regression)")
                                case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                              }
                            }
                            case _ -> assertTrue(false, "statement expression is not ECall")
                          }
                        }
                        case _ -> assertTrue(false, "second statement is not SExpr")
                      }
                    }
                    case _ -> assertTrue(false, "var-field init is not ELambda")
                  }
                }
                case None -> assertTrue(false, "var field has no init")
              }
            }
            case _ -> assertTrue(false, "protected field is not PFVar")
          }
        }
        case _ -> assertTrue(false, "protected member is not PMField")
      }
    }
    case _ -> assertTrue(false, "first item is not IProtected")
  }
}

// Scope-awareness regression, range-pattern bound (#6324): a `PRange`
// pattern's `hi` (or `lo`) bound is an ordinary Expr (`parseLiteralOrRangePat`
// calls the fully general `parseExpr`) and shares the exact same
// self-referential hazard every other standalone-expression position in
// this file already guards against.
test "a local bound inside a range pattern's hi-bound lambda shadows a bare-imported package's dotted name, left untouched (#6324)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(x: in Int): Int {\n  match x {\n    case 0..{\n      val Foo = 0\n      Foo.Bar.baz()\n    } -> 1\n    case _ -> 0\n  }\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertEqualInt(block.statements.count, 1, "function body has exactly the match statement")
              val stmt = block.statements[0]
              match stmt.kind {
                case SExpr(matchExpr) -> {
                  match matchExpr.kind {
                    case EMatch(_, arms) -> {
                      assertEqualInt(arms.count, 2, "match has exactly the range arm plus the wildcard arm")
                      match arms[0].pattern.kind {
                        case PRange(_, _, hi) -> {
                          match hi.kind {
                            case ELambda(_, hiBlock) -> {
                              assertEqualInt(hiBlock.statements.count, 2, "hi-bound lambda body has the local decl plus the call statement")
                              val hiStmt = hiBlock.statements[1]
                              match hiStmt.kind {
                                case SExpr(callExpr) -> {
                                  match callExpr.kind {
                                    case ECall(fn, _) -> {
                                      match fn.kind {
                                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6324 regression)")
                                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                                      }
                                    }
                                    case _ -> assertTrue(false, "statement expression is not ECall")
                                  }
                                }
                                case _ -> assertTrue(false, "second statement is not SExpr")
                              }
                            }
                            case _ -> assertTrue(false, "hi bound is not ELambda")
                          }
                        }
                        case _ -> assertTrue(false, "first arm's pattern is not PRange")
                      }
                    }
                    case _ -> assertTrue(false, "match statement's expr is not EMatch")
                  }
                }
                case _ -> assertTrue(false, "function body's single statement is not SExpr")
              }
            }
            case FBExpr(_) -> assertTrue(false, "function body is FBExpr, expected FBBlock")
          }
        }
        case None -> assertTrue(false, "function has no body")
      }
    }
    case _ -> assertTrue(false, "first item is not IFunc")
  }
}

// Scope-awareness regression, range-subtype declaration bound (#6325): a
// `type Age = Int range lo..=hi` declaration's own `hi` (or `lo`) bound is
// an ordinary Expr (`parseRangeBound` calls the fully general `parseExpr`)
// and shares the exact same self-referential hazard the #6324 pattern-range
// fix already closed for match-arm range patterns.
test "a local bound inside a range-subtype declaration's hi-bound lambda shadows a bare-imported package's dotted name, left untouched (#6325)" {
  val src = "package Test\nimport Foo.Bar\ntype Age = Int range 0 ..= {\n  val Foo = 0\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IDistinctType(decl) -> {
      match decl.rangeClause {
        case Some(rb) -> {
          match rb {
            case RBClosed(_, hi) -> {
              match hi.kind {
                case ELambda(_, block) -> {
                  assertEqualInt(block.statements.count, 2, "hi-bound lambda body has the local decl plus the call statement")
                  val stmt = block.statements[1]
                  match stmt.kind {
                    case SExpr(callExpr) -> {
                      match callExpr.kind {
                        case ECall(fn, _) -> {
                          match fn.kind {
                            case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                            case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6325 regression)")
                            case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                          }
                        }
                        case _ -> assertTrue(false, "statement expression is not ECall")
                      }
                    }
                    case _ -> assertTrue(false, "second statement is not SExpr")
                  }
                }
                case _ -> assertTrue(false, "hi bound is not ELambda")
              }
            }
            case _ -> assertTrue(false, "range clause is not RBClosed")
          }
        }
        case None -> assertTrue(false, "distinct type has no range clause")
      }
    }
    case _ -> assertTrue(false, "first item is not IDistinctType")
  }
}

// Scope-awareness regression, const-generic type-arg value (#6325): an
// `array[SIZE, Elem]` field's `SIZE` is a `TAValue` whose expr is parsed via
// the fully general `parseExpr` starting from a leading literal token, so a
// binop RHS embedded in that expr can itself be a lambda introducing its
// own shadowing local.
test "a local bound inside an array-size type-arg's embedded lambda shadows a bare-imported package's dotted name, left untouched (#6325 coverage)" {
  val src = "package Test\nimport Foo.Bar\nrecord Buf {\n  bytes: array[0 + {\n    val Foo = 0\n    Foo.Bar.baz()\n  }, Int]\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IRecord(decl) -> {
      assertEqualInt(decl.members.count, 1, "record has exactly the one field")
      match decl.members[0] {
        case RMField(field) -> {
          match field.ty.kind {
            case TArray(size, _) -> {
              match size {
                case TAValue(sizeExpr) -> {
                  match sizeExpr.kind {
                    case EBinop(_, _, rhs) -> {
                      match rhs.kind {
                        case ELambda(_, block) -> {
                          assertEqualInt(block.statements.count, 2, "size-arg lambda body has the local decl plus the call statement")
                          val stmt = block.statements[1]
                          match stmt.kind {
                            case SExpr(callExpr) -> {
                              match callExpr.kind {
                                case ECall(fn, _) -> {
                                  match fn.kind {
                                    case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the lambda-local `Foo` suppressed the collapse")
                                    case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — a lambda-local `Foo` should have suppressed the Foo.Bar package collapse (#6325 regression)")
                                    case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                                  }
                                }
                                case _ -> assertTrue(false, "statement expression is not ECall")
                              }
                            }
                            case _ -> assertTrue(false, "second statement is not SExpr")
                          }
                        }
                        case _ -> assertTrue(false, "binop rhs is not ELambda")
                      }
                    }
                    case _ -> assertTrue(false, "size expr is not EBinop")
                  }
                }
                case _ -> assertTrue(false, "array size is not TAValue")
              }
            }
            case _ -> assertTrue(false, "field type is not TArray")
          }
        }
        case _ -> assertTrue(false, "record member is not RMField")
      }
    }
    case _ -> assertTrue(false, "first item is not IRecord")
  }
}

// Review follow-up: the #6311/#6312 filtering has a beneficial side effect on
// the DEPTH-1 non-call `EMember` arm too, since it strips a shadowed alias
// from the shared `aliases` list before ANY arm (call or non-call) consults
// it. A tail alias (`Bar=Foo.Bar`, registered for the bare `import Foo.Bar`)
// that collides with a function-local `val Bar` now stays uncollapsed for a
// plain (non-call) value reference `Bar.baz`, not just for a call — this arm
// itself is unmodified (see its updated comment above), but the alias list it
// reads is already filtered by the time it runs. Locks in this side effect so
// a future change can't silently regress it.
test "a local shadowing a bare-imported package's tail alias also leaves a non-call value reference untouched (#6311/#6312 side effect)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  val Bar = 0\n  Bar.baz\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertEqualInt(block.statements.count, 2, "function body has the local decl plus the value-reference statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(refExpr) -> {
                  match refExpr.kind {
                    case EMember(receiver, memberName) -> {
                      assertEqual(memberName, "baz", "member name is still the reference's own 'baz'")
                      match receiver.kind {
                        case EPath(p) -> {
                          assertEqualInt(p.segments.count, 1, "receiver is still the bare single-segment 'Bar'")
                          assertEqual(p.segments[0], "Bar", "receiver segment is still 'Bar', unrewritten")
                        }
                        case _ -> assertTrue(false, "receiver is not EPath — chain shape changed unexpectedly")
                      }
                    }
                    case EPath(_) -> assertTrue(false, "value reference was collapsed into a flat EPath — a local `Bar` should have suppressed the Foo.Bar tail-alias collapse")
                    case _ -> assertTrue(false, "value reference is unexpected ExprKind after rewrite")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
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

// Review follow-up: locks in the documented, accepted coarse-scoping tradeoff
// (D-progress-718's "Third finding") — `filterAliasesExcludingLocals` collects
// names bound ANYWHERE in a function, not per-block, so a name bound only
// inside one `if` branch also suppresses the qualified-call collapse at an
// UNRELATED call site elsewhere in the same function that a real per-block
// scope analysis would consider unshadowed. This is an accepted false
// negative (falls back to the safe, pre-existing per-`EMember`-arm
// recursion — never a false positive/silent-miscompile), not a bug; this
// test exists so a future attempt at real per-block scoping has a concrete
// case to compare against, and so this over-suppression doesn't get
// "fixed" into a regression by accident.
test "a name bound only inside one branch still suppresses an unrelated call site elsewhere in the same function (accepted coarse-scoping tradeoff)" {
  val src = "package Test\nimport Foo.Bar\nfunc f(): Int {\n  if true {\n    val Foo = 0\n  }\n  Foo.Bar.baz()\n}\n"
  val pr = parse(src)
  val rewritten = rewriteFile(pr.file)
  val firstItem = rewritten.items[0]
  match firstItem.kind {
    case IFunc(decl) -> {
      match decl.body {
        case Some(fb) -> {
          match fb {
            case FBBlock(block) -> {
              assertEqualInt(block.statements.count, 2, "function body has the if-statement plus the call statement")
              val stmt = block.statements[1]
              match stmt.kind {
                case SExpr(callExpr) -> {
                  match callExpr.kind {
                    case ECall(fn, _) -> {
                      match fn.kind {
                        case EMember(_, _) -> assertTrue(true, "callee stays a nested EMember — the branch-local `Foo` conservatively suppressed the collapse here too")
                        case EPath(_) -> assertTrue(false, "callee was collapsed into a flat EPath — the coarse-scoping tradeoff should have suppressed this")
                        case _ -> assertTrue(false, "callee is unexpected ExprKind after rewrite")
                      }
                    }
                    case _ -> assertTrue(false, "statement expression is not ECall")
                  }
                }
                case _ -> assertTrue(false, "second statement is not SExpr")
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

// Runtime end-to-end for #6294: the SAME bare `import Std.Console`, but
// called via its full `Std.Console.println(...)` form instead of the
// tail-only `Console.println(...)` form above. Before #6294 this compiled
// with no diagnostic yet silently mistyped as `TyError` (never reaching
// codegen's real call), so this asserts the successful print as a live
// end-to-end check that the fix's flattening reaches actual codegen.
test "runtime: bare `import Std.Console` routes Std.Console.println correctly (#6294)" {
  Std.Console.println("alias rewriter #6294: bare multi-segment import's full form works")
  assertTrue(true, "Std.Console.println via a bare multi-segment import's full form did not throw")
}
