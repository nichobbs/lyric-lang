# D520 - The native backend lowers TIR: `Lyric.LlvmTir`, per-function fallback (docs/70 phase 4a)

**Status:** accepted; slice 1 (scalar functions, #8995) and slice 2 (scalar `match`, `for` over ranges) shipped.

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

## Slice 2

- `match` on a scalar scrutinee (`Bool`, `Byte`, `Int`, `UInt`, `Long`, `ULong`, `Nat`, `Char`): literal, range, binding (with `@` sub-pattern), wildcard and or-patterns without bindings, guards, and a runtime panic after the last arm. A match the builder did not prove exhaustive falls back. The result is a phi whose predecessors include the dead block after the panic (the LLVM verifier rejects a phi without an entry for every predecessor).
- `for` over an `XRange` of integers; an inclusive range tests the bound before stepping so `MAX` does not wrap into an endless loop.
- Unary negation does not check overflow, the same as the AST path, so it is not a difference to close before the default switch.
- A `Bool` widens by zero extension; an unsigned literal above the signed maximum of its width is stored as its two's-complement value.

## Slice 3: the `--via-tir` build path and the census

- `lyric build --target native --via-tir` (and `LYRIC_NATIVE_VIA_TIR=1` for CI) asks the middle end for the checked file as a TIR package (`MiddleEndOptions.wantTir`: the file is numbered, `Lyric.Tir.Build.buildPackage` runs after a clean check, D570). The bridge attaches it to the user package's `CodegenUnit` (`tir`); single-file builds only, project builds follow.
- The code generator keeps the authority over IR names: for each function it finds the matching `TFnDecl` by the package, name and parameter count in the symbol's DefPath key (`Pkg::name(P1,P2)`), maps every callee symbol through its own signature table, and lowers with `Lyric.LlvmTir`. Linkage and attributes stay the AST path's. A TIR lowering whose parameter or result types differ from the AST lowering's is refused as a fallback, so the two paths cannot disagree about a function's ABI.
- Every function that stays on the AST path is counted with its reason. The build prints `native via-TIR: N of M functions lowered from TIR` and one `fallback: <reason> x <count>` line per reason, most frequent first (§12.2). `scripts/ci/native-via-tir-e2e.sh` builds a scalar program both ways, requires equal output, and requires exactly the expected census.
