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

## Slice 4: strings and ARC

- `String` is a lowered type: literals (static `LyricString` globals with the immortal count, so retaining or releasing them is a no-op), `+`, `==`, `!=`, the orderings, `String.length`, `toString` of every scalar, `print` and `println`.
- Ownership is explicit in the lowering, not inferred from the AST path's helpers. A reference `Val` is either owned (a count this code holds: a call result, a retained value) or borrowed (a read of a local, a static literal). A binding, a returned value, an `if` or `match` result and a reassigned local take ownership (`own`: a borrowed value is retained, an owned one moves). An argument or operand is borrowed; an owned temporary used that way is released when its statement ends. Reference locals are released when their lexical scope closes, and `return`, `break` and `continue` release what they leave (`releaseDownTo`). Each branch of an `if`/`match` closes its own temporaries before it joins, so no release is emitted in a block that does not dominate the value.
- Parameters are `in` borrows (ARC rule 5) and are never released by the callee; a returned reference is owned by the caller (rule 6).
- `scripts/ci/native-via-tir-e2e.sh` builds `native-via-tir/strings.l` both ways and requires equal output, and recompiles the TIR build's IR under AddressSanitizer against an ASan-built runtime: a leak, a double release or a use after release fails the run.
- Still on the AST path: matching on a reference value, `inout`/`out` references, and everything with a heap layout (records, unions, lists, closures).

## Slice 5: by-value records

- `XConstruct`, `XField` and `XCopy` lower for the records the code generator registers by value (docs/67 §4.2: no `var` field, every field by-value): construction is an `insertvalue` chain from `undef`, a field read is `extractvalue`, `.copy` inserts the updated fields into the base. There is no allocation and no ARC, so no ownership rule applies. A Unit field has only its placeholder byte; nothing is stored or read.
- Layout stays the code generator's. `TirLowerEnv.recs` maps a record's `SymbolId` to a `TirRecLayout` (the LLVM struct type and the field types it chose), built in `tirOrAst` from the DefPath keys (`Pkg::Name`) and `ctx.recordDefs`. `LlvmTir` never decides between the heap and the by-value form: a symbol with no entry (a heap record, a union case, a generic) falls back. `tyToN` takes the map so a record can be a parameter, result, local or field type.
- Operators on a record (`==`, unary) fall back: structural equality is a derive, not an intrinsic.
- Still on the AST path: heap records and unions (the ARC and destructor slice), patterns on records, tuples, lists, closures.

## Slice 6: heap records

- `XConstruct`, `XField` and `XCopy` also lower for the records the code generator registers in the heap form (a `var` field, or a field that is not by-value). `TirRecLayout` carries `byValue` and the destructor symbol; `LlvmTir` still never decides between the forms.
- Construction evaluates every field first, then allocates (`lyric_alloc`, count 1, the destructor in the header, the weak count seeded by `lyric_weak_init`), then stores. An owned field value is a statement temporary (released when the statement ends) and the object takes its own count on each reference field (ARC rule 2), so an early exit inside a later field expression leaks nothing. The result is an owned reference.
- A field read is a load through the field pointer (header slots first) and is borrowed from the object; a binding or a return retains it.
- `.copy` allocates a new object: updated fields from the updates, the others loaded from the base with each reference retained.
- `isRefN` is now "a pointer to a struct that starts with the ARC header", so record locals are released at scope exit and `return`/`break`/`continue` release them. Operators on a reference other than a string, and a compound assignment on one, fall back.
- The layout and function-name maps are built once per unit (`tirUnitMaps`), not once per function. A field value whose type differs from the layout's is a fallback, not invalid IR.
- Protected types, `foreign record`s and `@nativeDtor` types stay on the AST path. `heaprecords.l` runs both ways and under AddressSanitizer.

## Slice 7: unions

- Non-generic unions lower in both forms the code generator registers: the inline tagged struct value (every payload by-value) and the heap object with the ARC header. `TirLowerEnv.unions` maps a union's `SymbolId` to a `TirUnionLayout` (value type, the struct behind it, inline or heap, the GEP indices of the discriminant and the payload area, the destructor symbol, and each case's payload struct and field types) and `TirLowerEnv.cases` maps a case's symbol (DefPath key `Pkg::Union::Case`) to its union and discriminant. The code generator builds both once per unit; `LlvmTir` reads them and never lays a union out.
- A case value: an inline union is built in a hoisted stack slot and loaded; a heap union is allocated after its fields are evaluated (`allocObject`, shared with heap records) and returned owned, the object owning its reference payload. Field types are checked against the layout.
- `match` on a union: the scrutinee is a borrowed pointer (an inline value is spilled to a stack slot). A `TpCtor` pattern tests the discriminant and then its scalar sub-patterns (literal, range, or-pattern) on the payload fields, and a binding stores the loaded field. A bound reference is a borrow of the scrutinee, which outlives the arm, so it is neither retained nor released and a guard that fails leaks nothing; a mutable reference binding falls back. Reading a field of a case the discriminant did not select is memory-safe (the payload area covers every case) and its value is used only under the discriminant test.
- Still on the AST path: generic unions (`Option`, `Result` until monomorphisation, docs/70 phase 3c), enums, nested case patterns, record patterns, `XPropagate`.

## Slice 8: text and common patterns

- `XInterp` is a left fold of `lyric_string_concat` over its (already `String`) parts; each intermediate is released as soon as the next concatenation has run, and the result is owned by the caller.
- `match` on a `String` scrutinee: a borrowed operand tested with `lyric_string_eq` for each `TpLit(TLString)`, with wildcard and borrowed bindings. A `Double`/`Float` literal pattern compares with `fcmp oeq`.
- `s[i]` on a string (`IkString`) calls `lyric_string_char_at` with the index widened to 64 bits. Indexing a list, map, array or slice stays on the AST path.
- A pattern binding of a reference scrutinee is a borrow (`bindBorrowed`) for every scrutinee kind, not only unions.
- Fallback census of a probe program (before this slice): `XInterp`, a match on a reference, a non-integer literal pattern, `XIndex`, enums, nested case patterns (the builder does not prove them exhaustive), `List` (an extern type; its calls are generic), tuples, function types and `Option` (generic, phase 3c).

## Slice 9: enums

- An enum value is its `i32` ordinal (the code generator's `enumDefs` representation). `TirLowerEnv.enums` lists the enum types and `TirLowerEnv.enumCases` maps each case symbol (DefPath key `Pkg::Enum::Case`) to its ordinal; the code generator builds both once per unit from `enumDefs`. A case value is a literal ordinal, a case pattern compares the scrutinee with it, and `==` on enums is the existing `i32` comparison.
- Still on the AST path: enums with payloads (they are unions), generic enums.

## Slice 10: project builds

- `lyric build --manifest ... --target native --via-tir` hands each own package's TIR to its code generation unit, as the single-file path does for the user package: the project loop of `compileProjectToNativeWithShape` asks the middle end for each own package's TIR (`MiddleEndOptions.wantTir`) and passes it to `unitOf`. Bundled stdlib packages and restored dependencies still compile through the AST path.
- The census is one total over every unit that carried TIR, printed once.
- `scripts/ci/native-via-tir/project/` (two packages, calls, a record and a union across the boundary) is built both ways by `native-via-tir-e2e.sh`.

## Slice 11: the generic fallback is pinned end to end

- `scripts/ci/native-via-tir/fallback.l` has a generic record, a generic union and a generic function beside one plain function. `native-via-tir-e2e.sh` requires that exactly the plain function is lowered from TIR, that the others are counted as fallbacks with a reason, that the output equals the AST build's and the specified output, and that the TIR build is clean under AddressSanitizer (nichobbs/lyric-lang#9023). When phase 3c monomorphises, this stage flips to asserting they lower.
- A self-test covers a case pattern on a value that is not an enum; `TirLowerEnv.enums` is documented as a set.

## Slice 12: tuples

- `XTuple`, a destructuring `let` over a tuple pattern and `TpTuple` in a `match` lower from TIR. A tuple is the synthesised heap record `__tuple<...>` the AST path already builds (`tupleRecInfo`), so layout stays the code generator's. Because those records are registered on demand, the lowering cannot be handed them up front: `tyToN` of a `TTuple` looks the layout up in `TirLowerEnv.tuples` (keyed by `renderTy`), and a missing one is recorded in `needTuples`, which the failed `TirFallback` carries. `lowerWithTuples` in the code generator registers those layouts with `tupleRecInfo` and lowers again (bounded; a nested tuple needs one round per level). Layouts persist per unit in `TirUnitMaps.tuples`.
- A destructuring `let` binds each name as an ordinary owning local (reference elements are retained) so the tuple is released at the end of the statement; tuple pattern bindings in a `match` are borrows of the borrowed scrutinee, like union payload bindings.
- A tuple pattern's element patterns are tested through `patTestAny`, which opens a union element first. Literal and nested tuple patterns are therefore accepted by the TIR path although the AST path rejects them (N0007); the fixture sticks to what both paths accept.
- Still on the AST path: element access `t.0` (the builder does not build it yet: it has no `FieldRef` owner for a tuple), tuple equality, a tuple holding a Unit element in a pattern.
- `scripts/ci/native-via-tir/tuples.l` (6 of 6 lowered, output equal to the AST build and the specified output, clean under AddressSanitizer) is run by `native-via-tir-e2e.sh`.

## Slice 13: function types, lambdas and calls through function values

- `TFunc` lowers to the code generator's `__closure<ret(params)>` pointer type, registered on demand like tuples (`TirLowerEnv.funcs`/`needFuncs`, registered by `closureNType` in `lowerWithTuples`'s retry). Only `in` parameters of concrete non-Unit types and non-async functions qualify; anything else keeps the function on the AST path.
- `XLambda` lowers to a heap closure object (ARC header, code pointer at slot 3, captures from slot 4) exactly as the AST path lays it out, so closure values cross between the two paths. The body is a function of its own (`__lyric.lambda.tir.<fn>.<n>`) lowered by the same `assembleFn` as any function, reading each capture from the environment into a slot. Captures are by value (a reference is retained into the object); a lambda that mutates a capture (`CmByRef`) stays on the AST path, as the AST path itself rejects it. The lowering returns the lambda functions and the environment layouts (`TirLowered.extraFns`/`closures`); the code generator emits them with the capture-releasing destructor (`synthClosureDtor`) only when the function lowers from TIR, so a fallback leaves nothing behind.
- `Callee.Indirect` loads the code pointer from the closure and calls it with the closure as `i8*` and the borrowed arguments; a reference result is owned.
- Still on the AST path: a named function used as a value (`XGlobal` of a function), `out`/`inout` function-type parameters, Unit parameters, async lambdas.
- `scripts/ci/native-via-tir/closures.l` (6 of 6 lowered, output equal to the AST build and the specified output, clean under AddressSanitizer) is run by `native-via-tir-e2e.sh`.

## Slice 14: out and inout parameters, assignment to record fields

- An `out` or `inout` parameter is the address of the caller's cell, as on the AST path (N9.6): the parameter's IR type is a pointer to the value type, the local's slot is that pointer, so every read and write reaches the caller's storage; the callee owns nothing and never releases it. A write to a reference goes through the ordinary replace path (new value owned, old one released).
- At a call, an `out`/`inout` argument is the address of a local's slot or of a field of a heap record. A field of a by-value record has no address and stays on the AST path. A reference passed `in` beside a by-reference argument may be the cell the callee writes, so it is retained for the call and released after it.
- Assignment to a field of a heap record (`r.f = v`, `r.f += v`) lowers through the same cell assignment as a local: the receiver is evaluated before the right-hand side, a reference field is replaced with the old value released.
- Not covered: elements and globals as places, interface and generic calls with by-reference arguments, by-value record fields as places.
- `scripts/ci/native-via-tir/inout.l` (6 of 6 lowered, output equal to the AST build, clean under AddressSanitizer) is run by `native-via-tir-e2e.sh`. `closures.l` gains a nested lambda that captures a captured variable.
