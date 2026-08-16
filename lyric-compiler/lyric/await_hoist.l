//! await_hoist.l — Lyric.AwaitHoist
//!
//! Statement-level ANF-style hoist for `await` in operand position (#5606).
//!
//! On `--target dotnet` an `async func` lowers to a state-machine `MoveNext`
//! whose suspension points must run with an empty CLR evaluation stack: any
//! value already pushed when an `await` suspends is lost across the resume
//! (the CLR does not preserve the operand stack between calls), so shapes
//! like `f(a, await e)` — where `a` is on the stack when `await e` suspends —
//! JIT-fail with `InvalidProgramException`, and nested awaits desync the
//! async-SM field pre-scan from emission.  The MSIL backend's binop-LHS
//! spill machinery (`phaseBSpillToLocal`) covers only the two-operand binop
//! case; call arguments, constructor arguments, method-call arguments (the
//! receiver counts as a stacked operand), list elements, index expressions,
//! and interpolation segments were all miscompiled.
//!
//! Rather than teach every call-lowering path to spill (the FieldDef budget
//! in `countSmFieldsMsil` must match emit-time spill registration EXACTLY
//! across a dozen paths — any desync corrupts every subsequent token), this
//! pass rewrites the AST once, before codegen, where the pre-scan and the
//! emitter see the same tree:
//!
//!     f(a, await e, b)   ⇒   val __lyric_hoist_0 = a
//!                            val __lyric_hoist_1 = await e
//!                            f(__lyric_hoist_0, __lyric_hoist_1, b)
//!
//! Every operand evaluated before the last await-bearing one is bound to a
//! fresh local first (preserving left-to-right evaluation order), so no
//! await remains in a position with operands already stacked.  `val x =
//! await t` is exactly the shape the async-SM machinery already compiles
//! correctly on both targets.
//!
//! The pass runs as the LAST middle-end rewrite (from
//! `Lyric.Pipeline.pipeWeave`, after aspect weaving) on every backend: the
//! rewrite is semantics-preserving on JVM and native (evaluation order is
//! unchanged), and keeping one tree across backends means the MSIL pre-scan,
//! MSIL emission, and the other targets can never diverge on these shapes.
//!
//! The hoist WALK (presence, qualification, spine rewrite, assign-target
//! rebinding, `while`-loop restructuring, statement/block/item drivers,
//! `ELambda`/`ESpawn`/`ETry` scope boundaries) is shared with
//! `Lyric.Propagate` §2b (#6448) via `Lyric.HoistEngine` (#6454) — this
//! file now only supplies its own `HoistConfig` (below) and its `isAsync`-
//! gated pipeline slot. See `Lyric.HoistEngine`'s module doc for the full
//! shared design.
//!
//! Scope — deliberately minimal (hoisting changes debug shape):
//!
//!   * Only `async func` bodies are rewritten (plain functions and lambdas
//!     resolve `await` with a blocking `GetAwaiter().GetResult()` shim that
//!     has no suspension, so their operand stacks are never at risk).
//!   * Only statements containing a QUALIFYING await are rewritten; shapes
//!     that already compile correctly — `await t` as a whole statement /
//!     initializer, plain binop operands (the spill path), `if`/`match` with
//!     awaits in arms bound to a `val` — are left byte-identical.  ANY
//!     await-bearing call argument qualifies regardless of callee shape
//!     (#6457, porting `Lyric.Propagate`'s #6460 fix) — a bare-name callee
//!     is syntactically indistinguishable from a local/module-level lambda
//!     value, and a callee-expression call (`getF()(await e)`) has the same
//!     stacked-callee hazard, so there is no "first-free-arg is safe"
//!     exemption.
//!   * Awaits under `ELambda` and `ESpawn` bodies are deferred computations,
//!     not operands of the enclosing expression; the pass never descends
//!     into them.  `ETry` cannot contain an await in an async function
//!     (V0012), and hoisting out of it would change exception scoping, so it
//!     is opaque too.
//!   * A `while` condition with a qualifying await is rewritten into the
//!     equivalent `loop { <hoisted>; if cond { body } else { break } }` so
//!     the hoisted bindings re-evaluate on every iteration; `continue`
//!     re-enters at the loop head, preserving `while` semantics.
//!   * #6457 (porting `Lyric.Propagate`'s #6456 fix): an assignment to a
//!     MEMBER or INDEX target (`b.field = await e`, `arr[i] = await e`,
//!     compound forms included) stacks the receiver — and any index
//!     operands — before the value evaluates on MSIL (`lowerAssignExprMsil`
//!     pushes them with no spill), so ANY await in the value qualifies, even
//!     a bare `val x = await t`-shaped one; the target's receiver/index
//!     operands are rebound to temps in evaluation order and the whole
//!     value is bound out (`Lyric.HoistEngine.hzBindAssignTarget`).  A
//!     bare-name target is a plain local store with nothing stacked and
//!     stays byte-identical.
//!
//! Known non-goals (unchanged behaviour, still resolved by later emission
//! machinery or currently-rejected shapes): awaits in the RHS of the
//! short-circuit operators `and` / `or` / `??` are left in place inside a
//! bound temp (the branchy lowering evaluates them on an empty stack),
//! `for`-iterable ranges keep their existing lowering, and an await inside a
//! `forall`/`exists` quantifier body or `old(...)` is detected by the
//! presence/qualification walks (#6457, walk-consistency with
//! `Lyric.Propagate`) but not rewritten by the hoist spine — low severity,
//! since quantifiers never lower to real bytecode and `EOld` at codegen is
//! already an ICE.
//!
//! Public surface:
//!
//!   pub func hoistAwaitsFile(file: in SourceFile): SourceFile
//!
//!     Returns the file with every qualifying await hoisted.  The input is
//!     not mutated; items with nothing to hoist are returned as-is.
package Lyric.AwaitHoist

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.HoistEngine

// ─────────────────────────────────────────────────────────────────────────────
// This pass's `HoistConfig` — see `Lyric.HoistEngine`'s module doc for the
// five configuration axes and the evidence behind each value below.
//
//   * `kind = HKAwait` — `EAwait` is this instantiation's own hazard node;
//     `EPropagate` is a transparent pass-through.
//   * `freshPrefix = "__lyric_hoist_"` — distinct from the `?` hoist's
//     `__lyric_phoist_` (async-SM field-naming assumption).
//   * `unconditionalTryHazard = false` — `Lyric.Propagate` runs first in
//     the pipeline (`pipeCheckAndMono`, before this pass's `pipeWeave`
//     slot) and already extracts any no-hazard try in a stacked operand
//     position before this pass ever sees the tree (D-progress-767); a try
//     that DOES contain an await cannot arise at all (V0012 rejects await
//     inside try/catch/finally in an async function).
//   * `binopRhsHazardUnconditional = false` — the MSIL emitter's LHS-spill
//     (`phaseBSpillToLocal`) already covers a bare await in a
//     non-short-circuit binop RHS, so only a NESTED need escalates here.
//   * `nestedTargetAlsoQualifies = true` — a nested await's completion is
//     itself an operand of the outer await's expression, and the MSIL
//     async-SM field pre-scan (`countSmFieldsMsil`) undercounts it unless
//     flagged (#5606).
//   * `asyncGated = true` — only `async func` bodies are rewritten; a
//     blocking (non-async) await has no suspension, so its operand stack
//     is never at risk. `protected type` entries (no `isAsync` field, can
//     never be declared async) are therefore never visited either.
// ─────────────────────────────────────────────────────────────────────────────
func awaitHoistConfig(): HoistConfig {
  HoistConfig(
    kind = HKAwait,
    freshPrefix = "__lyric_hoist_",
    unconditionalTryHazard = false,
    binopRhsHazardUnconditional = false,
    nestedTargetAlsoQualifies = true,
    asyncGated = true
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point.
// ─────────────────────────────────────────────────────────────────────────────
pub func hoistAwaitsFile(file: in SourceFile): SourceFile {
  hoistFile(awaitHoistConfig(), file)
}
