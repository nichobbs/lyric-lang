//! propagate_hoist_entry_polarity_self_test.l — D-progress-769: AST-level
//! pin for `Lyric.HoistEngine`'s `asyncGated = false` axis as applied to
//! `protected type` ENTRY bodies, exercised via `Lyric.Propagate`'s `?`
//! operand-position hoist (#6448, `propagate_hoist_self_test.l`). Also
//! carries #6734's module-scope-val pin (via `Lyric.AwaitHoist`'s `await`
//! instantiation instead) for the same "blocked from runtime testing by an
//! unrelated codegen gap" reason — see that test's own header below.
//!
//! `Lyric.HoistEngine`'s five-axis `HoistConfig` (see that package's module
//! doc) has `asyncGated` gate whether `EntryDecl` bodies are visited at all:
//! `EntryDecl` carries no `isAsync` field, so under `asyncGated = true`
//! (`Lyric.AwaitHoist`'s instantiation) entries are PERMANENTLY ineligible;
//! under `asyncGated = false` (`Lyric.Propagate`'s instantiation, since `?`
//! is legal in plain functions too) entries are visited and rewritten
//! exactly like a function body — see `hzEntryNeedsHoist`/`hzRewriteEntry`
//! in `hoist_engine.l`. A regression that flipped this polarity (or
//! accidentally dropped the `PMEntry` arm from `hzItemNeedsHoist`/
//! `hzRewriteItem`'s `IProtected` cases) would silently stop hoisting `?`
//! inside entries while `propagate_hoist_self_test.l`'s 35 plain-`func`
//! cases kept passing — nothing there exercises an `EntryDecl` at all.
//!
//! This pin could NOT be added as a runtime `test` to
//! `propagate_hoist_self_test.l` itself (the natural home, and where it was
//! first attempted): `?` inside a `protected type` entry — hoisted or not,
//! stacked-operand or not — hits two unrelated, pre-existing bugs that
//! block it from ever RUNNING today, on both targets:
//!
//!   * MSIL: a non-tail `return` statement reachable from inside an entry
//!     body's `if`/`match`/`while` (exactly the shape `e?`'s
//!     `-> { return Err(x) }` match arm produces, regardless of whether the
//!     `?` itself was in stacked-operand position) throws
//!     `System.InvalidProgramException` at the call site. Confirmed with
//!     zero involvement of propagate/hoist/`?`: a bare
//!     `entry f(): Int { if cond { return 1 }; 2 }` crashes identically,
//!     while a `return` as the entry's own LITERAL LAST statement
//!     (`entry f(): Int { return 1 }`) is fine — `lowerProtectedMsil`'s
//!     `entryFctx.epilogueLabel`/`leave` epilogue only handles that one
//!     shape (`msil/codegen.l` ~line 25630). Tracked as #6475.
//!   * JVM: `?` anywhere in an entry body (again with zero hoist/stacking
//!     involvement — a bare `entry f(): Result[Int, String] { val v = r?; v }`
//!     reproduces it) fails codegen outright with
//!     `Jvm.Codegen: match not exhaustive`. Tracked as #6476.
//!
//! Both are unrelated pre-existing limitations, not a hoist-polarity
//! regression (see docs/03-decision-log.md D-progress-769 for the full
//! repro trail) — so the polarity is pinned at the AST level instead, the
//! way `alias_rewriter_self_test.l` pins rewrite shapes that hit an
//! unrelated codegen gap: parse a small source string with an entry-bodied
//! `?` in stacked operand position, run it through
//! `Lyric.Propagate.lowerPropagateFile` (the exact pass the compiler runs
//! on every file, hoist included), and assert the entry body gained the
//! hoisted `val`(s) and the call receiver/argument became bare paths — the
//! SAME structural assertion `propagate_hoist_self_test.l`'s runtime tests
//! make by executing, made here by inspecting the post-pass AST.
//!
//! Run in CI via native `lyric test --target dotnet` ONLY (model:
//! `alias_rewriter_self_test.l`): importing `Lyric.Lexer`/`Lyric.Parser`/
//! `Lyric.Propagate` resolves in-process through `Msil.Bridge`'s
//! restored-deps mechanism (#2364), but `Jvm.Bridge`'s `compileToJarBundled`
//! only bundles a file's transitive `Std.*` import closure — it has no
//! mechanism to resolve a `Lyric.*` compiler-package import at all, so this
//! file cannot compile under `--target jvm` (confirmed: `T0020 unknown name
//! 'parse'`/`'lowerPropagateFile'` — the import silently resolves to
//! nothing rather than erroring at the `import` line itself). This is why
//! the pin lives in its OWN file rather than folded into
//! `propagate_hoist_self_test.l`: that file is wired dual-target in CI, and
//! one non-JVM-compilable test would break the JVM job for all 35 of its
//! existing cases.
@test_module
package Lyric.PropagateHoistEntryPolaritySelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Propagate
import Lyric.HoistEngine
import Lyric.AwaitHoist

test "protected-type entry: ? in a stacked method-call arg gets hoisted (AST pin, D-progress-769)" {
  val src = "package PinSrc\n" + "import Std.Collections\n" + "import Std.Core\n" + "protected type Bag {\n" +
    "  var items: List[Int]\n" +
    "  entry addDecoded(s: String): Result[Unit, String] {\n" +
    "    items.add(decode(s)?)\n" +
    "    Ok(())\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "the pinned source parses with no diagnostics")
  val result = lowerPropagateFile(pr.file)
  val firstItem = result.file.items[0]
  match firstItem.kind {
    case IProtected(decl) -> {
      assertEqualInt(decl.members.count, 2, "protected type Bag has the var field and the entry")
      match decl.members[1] {
        case PMEntry(ed) -> {
          match ed.body {
            case FBBlock(blk) -> {
              // Un-hoisted (a polarity regression), this stays at 2
              // statements: `items.add(decode(s)?)` then `Ok(())`. Hoisted,
              // a fresh `val` lands before the call, matching every
              // plain-`func` case in `propagate_hoist_self_test.l`.
              //
              // The call's own receiver (`items`, a bare implicit-self
              // field read) ALSO gets its own hoisted `val` ahead of the
              // hazard's, since #6684 made `Lyric.HoistEngine` recognize a
              // bare implicit-self field the same way it already treated
              // `self.field` (#6600): `hzHoistSpine`'s `ECall` case binds a
              // mutable call receiver whenever the call has a hazardous
              // argument (hoist_engine.l ~line 907), regardless of hazard
              // kind, so this fires for propagate the same as it would for
              // await even though `?` never suspends and so never actually
              // risks a stale receiver read here. That's the same
              // documented "costs a spurious extra temp bind... which is
              // the safe direction to err" tradeoff `hzNameLikeMutable`'s
              // own doc comment already accepts elsewhere, so the pin
              // widens to 4 statements: [0] the receiver hoist, [1] the
              // `decode(s)?` hoist, [2] the rewritten call, [3] `Ok(())`.
              assertEqualInt(
                blk.statements.count,
                4,
                "entry body gains a hoisted receiver val AND a hoisted arg val ahead of the original 2 statements (#6684)"
              )
              match blk.statements[0].kind {
                case SLocal(_) -> assertTrue(true, "first statement is the hoisted receiver val binding")
                case _ -> assertTrue(false, "expected the hoisted receiver val as the first statement")
              }
              match blk.statements[1].kind {
                case SLocal(_) -> assertTrue(true, "second statement is the hoisted arg val binding")
                case _ -> assertTrue(false, "expected the hoisted arg val as the second statement")
              }
              match blk.statements[2].kind {
                case SExpr(e) -> {
                  match e.kind {
                    case ECall(fn, args) -> {
                      match fn.kind {
                        case EMember(recv, _) -> {
                          match recv.kind {
                            case EPath(_) -> assertTrue(true, "call receiver is now a bare path reading the hoisted val")
                            case _ -> assertTrue(false, "call receiver still holds the original items reference")
                          }
                        }
                        case _ -> assertTrue(false, "expected the call callee to remain an EMember (items.add)")
                      }
                      assertEqualInt(args.count, 1, "items.add still has exactly one argument")
                      match args[0] {
                        case CAPositional(v) -> {
                          match v.kind {
                            case EPath(_) -> assertTrue(true, "call argument is now a bare path reading the hoisted val")
                            case _ -> assertTrue(false, "call argument still nests the unhoisted ?-desugar")
                          }
                        }
                        case CANamed(_, _, _) -> assertTrue(false, "unexpected named argument shape")
                      }
                    }
                    case _ -> assertTrue(false, "expected the items.add call as the third statement's expr")
                  }
                }
                case _ -> assertTrue(false, "expected the original call as the third statement")
              }
              match blk.statements[3].kind {
                case SExpr(_) -> assertTrue(true, "fourth statement is the original Ok(()) trailing expression")
                case _ -> assertTrue(false, "expected Ok(()) as the fourth statement")
              }
            }
            case FBExpr(_) -> assertTrue(false, "expected an FBBlock entry body")
          }
        }
        case _ -> assertTrue(false, "expected the entry as the protected type's second member")
      }
    }
    case _ -> assertTrue(false, "expected the parsed protected type as the first item")
  }
}

// #6729 (review finding on #6547, item 2): `hzHoistSpine`'s `ECall` handling
// skipped a bare-name callee (`EPath`) unconditionally, with no
// `mutableNames` consultation — unlike the `EMember` receiver case just
// above it, which already stacks a mutable receiver ahead of a hazardous
// argument (#5629). A reassignable local holding a closure, called by bare
// name with a hazardous argument (`cb(decode(s)?)` where `cb` is a `var`),
// stacks the callee value BEFORE evaluating the argument on MSIL exactly
// like the receiver case does — so it needs the same hoist protection.
//
// This lives here rather than as a runtime `test` in
// `propagate_hoist_self_test.l` (the natural home for a plain-`func`
// hoist case) because constructing an OBSERVABLE runtime difference needs
// `cb` to be reassigned as a side effect of evaluating the hazardous
// argument itself — which requires either aliasing `cb` through an `inout`
// parameter while also reading it in callee position (a shape the mode
// checker's V0015 aliasing rule is expected to reject outright) or
// capturing it as shared mutable state across a concurrency boundary
// (module-scope `var`, itself #6734's separate known gap). Pinned at the
// AST level instead, the same way the entry-polarity pin above is.
test "bare-name callee: ? in a hazardous call argument hoists the mutable callee too (#6729)" {
  val src = "package PinSrc2\n" + "import Std.Core\n" + "func decode2(s: in String): Result[Int, String] {\n" +
    "  Ok(1)\n" +
    "}\n" +
    "func apply2(g: in (Int) -> Int, s: in String): Int {\n" +
    "  var cb = g\n" +
    "  cb(decode2(s)?)\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "the pinned source parses with no diagnostics")
  val result = lowerPropagateFile(pr.file)
  val fnItem = result.file.items[1]
  match fnItem.kind {
    case IFunc(decl) -> {
      val body = match decl.body { case Some(b) -> b; case None -> panic("expected the pinned function to have a body") }
      match body {
        case FBBlock(blk) -> {
          // Un-hoisted (a regression), this stays at 1 statement: the bare
          // call `cb(decode2(s)?)`. Hoisted, the callee `cb` AND the
          // `decode2(s)?` hazard each gain their own hoisted `val` ahead of
          // the call, matching every other hazardous-argument case in
          // `propagate_hoist_self_test.l`.
          assertTrue(
            blk.statements.count >= 3,
            "function body gains at least a hoisted callee val AND a hoisted arg val ahead of the call (#6729), got " +
              toString(blk.statements.count) +
              " statement(s)"
          )
          // The LAST statement is always the (rewritten) call itself.
          val lastStmt = blk.statements[blk.statements.count - 1]
          match lastStmt.kind {
            case SExpr(e) -> {
              match e.kind {
                case ECall(fn, _) -> {
                  match fn.kind {
                    case EPath(_) -> assertTrue(
                      true,
                      "call callee is a bare path — either the original `cb` or a hoisted temp reading it"
                    )
                    case _ -> assertTrue(false, "expected the call callee to remain a bare EPath")
                  }
                }
                case _ -> assertTrue(false, "expected the apply call as the last statement's expr")
              }
            }
            case _ -> assertTrue(false, "expected the rewritten call as the last statement")
          }
          // At least one of the statements BEFORE the call must be a hoisted
          // `val` binding — this is the actual regression guard: before the
          // fix, only the `decode2(s)?` hazard got a hoisted `val` (1 extra
          // statement); the callee `cb` never did.
          var hoistedCount = 0
          var si = 0
          while si < blk.statements.count - 1 {
            match blk.statements[si].kind {
              case SLocal(_) -> {
                hoistedCount = hoistedCount + 1
              }
              case _ -> {
              }
            }
            si = si + 1
          }
          assertTrue(
            hoistedCount >= 2,
            "expected at least 2 hoisted val bindings ahead of the call (callee + hazard), got " + toString(hoistedCount)
          )
        }
        case FBExpr(_) -> assertTrue(false, "expected an FBBlock function body")
      }
    }
    case _ -> assertTrue(false, "expected the parsed function as the second item")
  }
}

// #6729 (review finding on #6547, item 3b): `hzCollectMutableNamesStmt`'s
// `SScope` case discarded the scope's own binding name instead of adding
// it to `localNames` — so a bare reference to that name, after the scope,
// was wrongly treated as an unbound/free name (indistinguishable from a
// package qualifier per #6699) rather than a genuine local, understating
// its hoist-protection eligibility should it ever appear as a receiver.
//
// `SScope.binding` has NO source syntax today — `parseIfExpr`'s (sic;
// `parser_exprs.l`'s statement-lead dispatch) `KwScope` arm always
// constructs `SScope(binding = None, body = ...)`; a `Some` binding is
// forward-looking AST surface with no parser support yet. So this pins
// the collector directly against a hand-built `SScope(Some(...), ...)`
// statement (via the public `mkStmt`/`hzCollectMutableNamesBlock` API),
// rather than through `parse(...)`, which cannot produce one.
test "scope binding name is tracked as a local by the mutable-names collector (#6729)" {
  val src = "package PinSrc3\n" + "import Std.Core\n" + "func anchor3(): Int {\n" + "  0\n" + "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "the anchor source parses with no diagnostics")
  val anchorSpan = pr.file.items[0].span
  val emptyBody = Block(statements = newList(), span = anchorSpan)
  val scopeStmt = mkStmt(SScope(binding = Some(value = "sc"), body = emptyBody), anchorSpan)
  val stmts: List[Statement] = newList()
  stmts.add(scopeStmt)
  val blk = Block(statements = stmts, span = anchorSpan)
  val mutableM: Map[String, Bool] = newMap()
  val localM: Map[String, Bool] = newMap()
  hzCollectMutableNamesBlock(blk, mutableM, localM)
  assertTrue(
    localM.containsKey("sc"),
    "a `SScope(binding = Some(\"sc\"), ...)` statement's binding name must be tracked as a local, not discarded (#6729)"
  )
}

// #6734 (review follow-up on #6729/#6600): a MODULE-SCOPE `val` used as a
// receiver is the identical shape one scope further out still. Before the
// fix, `HoistState` had no `moduleValNames` field, so a module-level `val`'s
// name was invisible to `hzMemberChainBaseIsValue` (which only consulted
// `st.mutableNames`/`st.selfFieldNames`/`st.localNames`, all function/entry-
// or record/impl/protected-type-scoped) — indistinguishable from an unbound
// package/type qualifier (#6699) — so a `var` field mutated through it
// during a hoisted hazard was never protected.
//
// This CANNOT be pinned as a runtime `test` in `await_hoist_self_test.l`
// (the natural home, given the identical shape to that file's #6600/#6684
// cases): compiling and running the equivalent module-`val` program hits a
// separate, unrelated pre-existing MSIL codegen gap in async-SM local
// promotion (tracked as #6787) — the hoisted receiver's captured value does
// not survive the awaited suspension when its initializer reads a field off
// a module-level val, even though (as this test itself proves) the
// front-end AST rewrite is correct. Pinned at the AST level instead, same
// as this file's other two cases — via `Lyric.AwaitHoist.hoistAwaitsFile`
// (the `await` instantiation) rather than `Lyric.Propagate.lowerPropagateFile`,
// since #6734 is an `await`-hoist case, not a `?`-hoist one.
test "module-scope val receiver: a var field mutated during a hoisted await gets hoist-protected (#6734)" {
  val src = "package PinSrc4\n" + "record MutBox4 {\n" + "  tag: Int\n" +
    "  func describe(self: in MutBox4, n: Int): Int {\n" +
    "    self.tag * 1000 + n\n" +
    "  }\n" +
    "}\n" +
    "record Cache4 {\n" +
    "  var box: MutBox4\n" +
    "}\n" +
    "func swapCacheBox4(c: in Cache4): Int {\n" +
    "  c.box = MutBox4(tag = 99)\n" +
    "  5\n" +
    "}\n" +
    "val gCache4: Cache4 = Cache4(box = MutBox4(tag = 1))\n" +
    "async func useGCache4(): Int {\n" +
    "  return gCache4.box.describe(await swapCacheBox4(gCache4))\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "the pinned source parses with no diagnostics")
  val noExtraRecords4: List[RecordDecl] = newList()
  val result = hoistAwaitsFile(pr.file, noExtraRecords4)
  // Items: [0] MutBox4, [1] Cache4, [2] swapCacheBox4, [3] gCache4 (IVal), [4] useGCache4.
  val fnItem = result.items[4]
  match fnItem.kind {
    case IFunc(decl) -> {
      val body = match decl.body { case Some(b) -> b; case None -> panic("expected useGCache4 to have a body") }
      match body {
        case FBBlock(blk) -> {
          // Un-hoisted (a #6734 regression), this stays at 1 statement: the
          // bare `return gCache4.box.describe(await swapCacheBox4(gCache4))`.
          // Hoisted, the receiver (`gCache4.box`) AND the hazard
          // (`await swapCacheBox4(gCache4)`) each gain their own hoisted
          // `val` ahead of the (rewritten) return — matching the identical
          // 3-statement shape `await_hoist_self_test.l`'s #6600/#6684 cases
          // produce for a local-`val`/`self` receiver.
          assertEqualInt(
            blk.statements.count,
            3,
            "function body gains a hoisted receiver val AND a hoisted hazard val ahead of the original 1 statement (#6734)"
          )
          match blk.statements[0].kind {
            case SLocal(_) -> assertTrue(true, "first statement is the hoisted receiver val binding")
            case _ -> assertTrue(false, "expected the hoisted receiver val as the first statement")
          }
          match blk.statements[1].kind {
            case SLocal(_) -> assertTrue(true, "second statement is the hoisted hazard val binding")
            case _ -> assertTrue(false, "expected the hoisted hazard val as the second statement")
          }
          match blk.statements[2].kind {
            case SReturn(valOpt) -> {
              val retExpr = match valOpt {
                case Some(e) -> e
                case None -> panic("expected the rewritten return to still carry a value")
              }
              match retExpr.kind {
                case ECall(fn, args) -> {
                  match fn.kind {
                    case EMember(recv, _) -> {
                      match recv.kind {
                        case EPath(_) -> assertTrue(true, "call receiver is now a bare path reading the hoisted val")
                        case _ -> assertTrue(false, "call receiver still holds the original gCache4.box chain")
                      }
                    }
                    case _ -> assertTrue(false, "expected the call callee to remain an EMember (....describe)")
                  }
                  assertEqualInt(args.count, 1, "describe still has exactly one argument")
                  match args[0] {
                    case CAPositional(v) -> {
                      match v.kind {
                        case EPath(_) -> assertTrue(true, "call argument is now a bare path reading the hoisted val")
                        case _ -> assertTrue(false, "call argument still nests the unhoisted await")
                      }
                    }
                    case CANamed(_, _, _) -> assertTrue(false, "unexpected named argument shape")
                  }
                }
                case _ -> assertTrue(false, "expected the describe call as the rewritten return's value")
              }
            }
            case _ -> assertTrue(false, "expected the rewritten return as the third statement")
          }
        }
        case FBExpr(_) -> assertTrue(false, "expected an FBBlock function body")
      }
    }
    case _ -> assertTrue(false, "expected useGCache4 as the fifth parsed item")
  }
}

// #6702: `HoistEngine.hzImplTargetFieldNames` resolved an `impl` block's
// target type's own fields only from the SAME file, so a cross-PACKAGE impl
// target (a `RecordDecl` declared in a sibling in-bundle package, a
// restored dependency, or a stdlib package — NOT a multi-file package's own
// files, which are concatenated into one `SourceFile` before this pass ever
// runs, per docs/19, so a same-package cross-file `impl` was already found)
// silently fell back to an empty field set: a bare (implicit-self) field
// mutated across a hoisted await was never protected. `pipeWeave` supplies
// the fix via `monoRecordDecls`, its own cross-package record list; this
// pin simulates that by parsing the record's declaration into a SEPARATE
// `SourceFile` (a different package, never merged into the `impl`'s own
// file) and passing its `RecordDecl` through `hoistAwaitsFile`'s
// `extraRecords` parameter — proving the fix end-to-end without needing a
// real multi-package project build (`await_hoist_self_test.l`'s single-file
// `@test_module` shape can't construct a genuine cross-package scenario at
// all).
func extractRecordDecls(file: in SourceFile): List[RecordDecl] {
  val acc: List[RecordDecl] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> acc.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

test "cross-file impl target: a var field mutated during a hoisted await is UNPROTECTED with no extraRecords, PROTECTED once the target's declaring file's records are supplied (#6702)" {
  // File A: declares the record `impl`ed against in file B. Never merged
  // into file B's own `SourceFile` — this is the cross-file boundary.
  val libSrc = "package Lib6702\n" + "record MutBox6702 {\n" + "  tag: Int\n" +
    "  func describe(self: in MutBox6702, n: Int): Int {\n" +
    "    self.tag * 1000 + n\n" +
    "  }\n" +
    "}\n" +
    "record Cache6702 {\n" +
    "  var box: MutBox6702\n" +
    "}\n"
  val libPr = parse(libSrc)
  assertEqualInt(libPr.diagnostics.count, 0, "the library source parses with no diagnostics")
  val libRecords = extractRecordDecls(libPr.file)
  assertEqualInt(libRecords.count, 2, "the library file declares exactly two records")

  // File B: an `impl` block targeting `Cache6702` (declared only in file
  // A above) with a bare implicit-self field mutated across an await —
  // the identical #6684 impl-method shape, one file boundary further out.
  val consumerSrc = "package Consumer6702\n" + "interface CacheRunner6702 {\n" +
    "  async func run(self: in Self): Int\n" +
    "}\n" +
    "func swapCacheBox6702(c: in Cache6702): Int {\n" +
    "  c.box = MutBox6702(tag = 99)\n" +
    "  5\n" +
    "}\n" +
    "impl CacheRunner6702 for Cache6702 {\n" +
    "  async func run(self: in Cache6702): Int {\n" +
    "    return box.describe(await swapCacheBox6702(self))\n" +
    "  }\n" +
    "}\n"
  val consumerPr = parse(consumerSrc)
  assertEqualInt(consumerPr.diagnostics.count, 0, "the consumer source parses with no diagnostics")

  // Negative control: no cross-file record index supplied — the pre-fix
  // behaviour. The `impl` block's target field set stays empty, so the
  // bare `box` receiver is (wrongly) treated as immutable name-like-safe
  // and stays unbound — only the hazard argument itself gets hoisted
  // (any await in a stacked-operand call-argument position needs its own
  // temp regardless of the receiver's mutability), so the body grows from
  // 1 to 2 statements, not 3: the receiver never gets its OWN protecting
  // bind, which is exactly the pre-#6702 stale-read gap (`box` re-read
  // inline, after the hazard, observing the mutated value at runtime).
  val noExtraRecords: List[RecordDecl] = newList()
  val unfixedResult = hoistAwaitsFile(consumerPr.file, noExtraRecords)
  val unfixedImplItem = unfixedResult.items[2]
  match unfixedImplItem.kind {
    case IImpl(decl) -> {
      match decl.members[0] {
        case IMplFunc(fn) -> {
          val body = match fn.body { case Some(b) -> b; case None -> panic("expected run to have a body") }
          match body {
            case FBBlock(blk) -> {
              assertEqualInt(
                blk.statements.count,
                2,
                "with no extraRecords, the cross-file target's fields are unresolved so only the hazard argument is hoisted, not the receiver (the pre-#6702 gap)"
              )
              match blk.statements[1].kind {
                case SReturn(valOpt) -> {
                  val retExpr = match valOpt { case Some(e) -> e; case None -> panic("expected a return value") }
                  match retExpr.kind {
                    case ECall(fn2, _) -> match fn2.kind {
                      case EMember(recv, _) -> match recv.kind {
                        case EPath(path) -> assertEqual(
                          path.segments[0],
                          "box",
                          "the receiver is still the raw (unprotected) bare `box` read, not a hoisted temp"
                        )
                        case _ -> assertTrue(
                          false,
                          "expected the receiver to stay a bare EPath"
                        )
                      }
                      case _ -> assertTrue(false, "expected the callee to remain an EMember (....describe)")
                    }
                    case _ -> assertTrue(false, "expected the describe call as the return value")
                  }
                }
                case _ -> assertTrue(false, "expected the rewritten return as the second statement")
              }
            }
            case FBExpr(_) -> assertTrue(false, "expected an FBBlock function body")
          }
        }
        case IMplAssoc(_) -> assertTrue(false, "expected the run method as the impl's first member")
      }
    }
    case _ -> assertTrue(false, "expected the CacheRunner6702 impl as the consumer file's third item")
  }

  // Fix: the library's records are supplied via `extraRecords`, exactly
  // as `pipeWeave` now threads `monoRecordDecls` through. The `impl`
  // block's target field set now resolves `Cache6702.box`, so the bare
  // `box` read is correctly recognised as hoist-worthy.
  val fixedResult = hoistAwaitsFile(consumerPr.file, libRecords)
  val fixedImplItem = fixedResult.items[2]
  match fixedImplItem.kind {
    case IImpl(decl) -> {
      match decl.members[0] {
        case IMplFunc(fn) -> {
          val body = match fn.body { case Some(b) -> b; case None -> panic("expected run to have a body") }
          match body {
            case FBBlock(blk) -> assertEqualInt(
              blk.statements.count,
              3,
              "with the library's records supplied via extraRecords, the cross-file impl target's fields resolve and the body gains hoisted receiver + hazard vals (#6702)"
            )
            case FBExpr(_) -> assertTrue(false, "expected an FBBlock function body")
          }
        }
        case IMplAssoc(_) -> assertTrue(false, "expected the run method as the impl's first member")
      }
    }
    case _ -> assertTrue(false, "expected the CacheRunner6702 impl as the consumer file's third item")
  }
}
