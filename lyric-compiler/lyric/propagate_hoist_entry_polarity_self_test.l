//! propagate_hoist_entry_polarity_self_test.l — D-progress-769: AST-level
//! pin for `Lyric.HoistEngine`'s `asyncGated = false` axis as applied to
//! `protected type` ENTRY bodies, exercised via `Lyric.Propagate`'s `?`
//! operand-position hoist (#6448, `propagate_hoist_self_test.l`).
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
//! hoisted `val` and the call argument became a bare path — the SAME
//! structural assertion `propagate_hoist_self_test.l`'s runtime tests make
//! by executing, made here by inspecting the post-pass AST.
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
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Propagate

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
              assertEqualInt(blk.statements.count, 3, "entry body gains a hoisted val ahead of the original 2 statements")
              match blk.statements[0].kind {
                case SLocal(_) -> assertTrue(true, "first statement is the hoisted val binding")
                case _ -> assertTrue(false, "expected the hoisted val as the first statement")
              }
              match blk.statements[1].kind {
                case SExpr(e) -> {
                  match e.kind {
                    case ECall(_, args) -> {
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
                    case _ -> assertTrue(false, "expected the items.add call as the second statement's expr")
                  }
                }
                case _ -> assertTrue(false, "expected the original call as the second statement")
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
