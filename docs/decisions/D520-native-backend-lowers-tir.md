# D520 - The native backend lowers TIR: `Lyric.LlvmTir`, per-function fallback (docs/70 phase 4a)

**Status:** accepted; slice 1 (scalar functions) shipped.

## Context

docs/70 §8 has each backend lower TIR, reading types from `TExpr.ty`, callees
from `Callee` and conversions from `ConvKind`, and deleting its inference and
name lookups. Phase 4a ports the native (LLVM) backend first. The TIR builder
(phase 3a) is still being finished and phase 3c (monomorphisation and the other
middle-end passes on TIR) has not started, so TIR does not yet cover every body
and still holds generics and un-elaborated contracts.

## Decision

1. **A new package, `Lyric.LlvmTir` (`lyric-compiler/lyric/llvm_tir.l`).**
   `lowerTirFunction(env, fn): Result[TirLowered, TirFallback]` lowers one
   monomorphic `TFnDecl` to an `NFunc` (plus the string globals and runtime
   declarations it needs). It imports `Lyric.Tir`, `Lyric.Symbols` and the LLVM
   IR model only: not the checker, not the parser AST, not `Lyric.LlvmCodegen`.
2. **The linkage table is an input.** The IR symbol of each `SymbolId` comes
   from `TirLowerEnv.fnNames` (docs/70 §9.5). The lowering never derives a name.
3. **Fallback is per function, explicit and counted.** A function the lowering
   does not cover returns `Err(TirFallback{sym, reason})`; the caller keeps the
   AST path's `NFunc` for it. Every fallback is counted and printed with its
   reason by the census, never hidden. A reason is a kind from §12.2 (for
   example `expression XMatch`, `a string literal`).
4. **The TIR path runs beside the AST path behind a flag** (`--via-tir` and an
   environment variable for CI) until it passes everything the AST path does;
   only then does it become the default and the native backend's inference,
   lookups and legacy AST entry get deleted (§13 phase 4a).
5. **Slice 1 covers** scalar parameters and results (`Bool`, `Byte`, `Int`,
   `UInt`, `Long`, `ULong`, `Nat`, `Float`, `Double`, `Char`, `Unit` results),
   operators with signedness read from the operand type, checked division,
   explicit widening, `if`, short-circuit `and`/`or`, blocks, `var`/`val`
   locals, assignment and compound assignment to locals, `while`, `loop`,
   `break`, `continue`, `return`, and direct non-generic calls.

## Consequences

- Unsigned division, remainder and ordering follow the operand's `Ty`
  (`udiv`, `urem`, `icmp ult`). The AST path derives these from `.toULong()`
  hints; the TIR path needs none.
- No TIR data-model change is required by this slice.
