# D-progress-941 — MSIL: bare-scalar `UInt`/`ULong` comparison, division, and stringification gain unsigned-aware codegen (#6913)

**Status:** shipped

**Context.** `D-progress-890` (#6756) gave MSIL a real `UInt`/`ULong`
representation — `Msil.Codegen.typeExprToMsilCtx` erases both to the same
`MInt`/`MLong` slot a signed `Int`/`Long` uses — and fixed the resulting
CLR-loader crash class, plus a downstream list-literal miscompile (#6782).
But that fix's own scope note flagged a real, deliberately out-of-scope gap:
only `MDistinctType.isUnsigned`-gated range-subtype bounds checking (the
`from`/`tryFrom` construction path) consulted "unsigned-ness" for
codegen — nothing tracked it for a BARE scalar value. A bare
`val x: UInt = 2500000000u32; println(x)` compiled and ran (no crash) but
printed `-1794967296`, the signed reinterpretation of the same bit pattern;
`x < y`/`x / y` on two bare `UInt`/`ULong` locals used plain signed
`clt`/`div` rather than `clt.un`/`div.un`, silently wrong for any value at
or above 2^31 (`UInt`) / 2^63 (`ULong`).

**Fix — a slot-keyed side channel, `Msil.Codegen`.** Mirrors the JVM
backend's `ctx.unsignedVars: Map[String, Bool]` / `isUnsignedExpr`
(`jvm/codegen/01_types.l`, #6748/#6754), but keyed by SLOT INDEX rather than
binding name:

```
unsignedSlots: Map[Int, Bool]   // FuncCtx field
```

populated by a new `markUnsignedSlotMsil(fctx, slot, isUnsigned)` at every
binding site that allocates a slot with a known declared type —
`registerParamsMsil` and `lowerFuncMsil`'s inline param-registration loop
(covering free functions, lambdas, impl methods, interface default
methods), and the `LBVal`/`LBLet`/`LBVar` (both with and without an
initializer) statement arms — using the type-expression check
`isUnsignedTypeExprMsil` (already added by #6756 as exactly this seam) via a
new `Option[TypeExpr]`-convenience wrapper, `isUnsignedAnnotationMsil`. A new
`isUnsignedExprMsil(fctx, e)` helper (mirroring JVM's `isUnsignedExpr` at its
ORIGINAL, pre-#6754 scope — see "Scope" below) recognizes a bare single-
segment `EPath` whose slot is marked, a `u32`/`u64`-suffixed integer
literal, and an `EParen`-wrapped instance of either.

**Why slot-keyed, not name-keyed (no separate scope-undo log needed).** The
JVM mechanism needed its own `unsignedUndo` scope-restore log (#6754) because
`ctx.unsignedVars` is keyed by binding NAME: a nested block shadowing an
outer `UInt x` with an inner `Int x` of the same name would otherwise
silently keep the outer unsigned marking for the inner (signed) value past
the shadow, and lose track of the outer marking once the inner block exited
without an explicit undo log. MSIL's own pre-existing `#5191` general-
shadowing fix (`allocSlotMsil`) already guarantees a shadowing bind gets a
FRESH slot number whenever it doesn't fall within the current block's
lexical scope (`existing >= fctx.scopeBaseMsil`) — so keying `unsignedSlots`
by slot index makes an outer binding's unsigned-ness immune to an inner
shadow BY CONSTRUCTION, with no separate undo log required. This exactly
mirrors how the pre-existing `FuncCtx.byteSlots` (Byte-local re-narrowing,
docs/59 §4.3) already tracks slot-keyed metadata the same way. Verified by
an explicit regression case (`range_subtype_self_test.l`'s block-shadow
test) rather than left as an unverified structural claim.

**Fix — comparison (`BLt`/`BGt`/`BLte`/`BGte`).** Two new `MInsn` cases,
`MClt_Un`/`MCgt_Un` (`Msil.Lowering`), wired to the ALREADY-EXISTING
`emitClt_Un`/`emitCgt_Un` opcode emitters (`Msil.Opcodes`, added by #6756 for
the narrower distinct-type bounds-check path but never wired into the
general `MInsn` union the binop path uses). `lowerBinopMsil`'s four
comparison arms now check `isUnsignedExprMsil(lhs) or isUnsignedExprMsil(rhs)`
and select the `_Un` variant instead of the default signed one — the
`String`-typed `CompareOrdinal`-then-`< 0`/`> 0` sub-arms are untouched
(strings are never unsigned-flavored). `insnStackDelta` (the other
exhaustive `MInsn` match, used by IL stack-depth bookkeeping) gained the two
new cases too (`-1`, same as `MClt`/`MCgt`).

**Fix — division/remainder (`BDiv`/`BMod`).** Extended the SAME
`MDivUn`/`MRemUn` selection that already existed for `MByte` (Byte division
is always unsigned, `#5992`-adjacent) to also fire for `MInt`/`MLong` when
`isUnsignedExprMsil(lhs) or isUnsignedExprMsil(rhs)`.

**Fix — stringification (`println`/`toString`/interpolation/concatenation).**
Two paths, both gated on `isUnsignedExprMsil`:

- `println` gets two new hand-built `Console.WriteLine(uint32)`/
  `Console.WriteLine(uint64)` `MemberRef` tokens (`tokWriteLineUInt`/
  `tokWriteLineULong`) — hand-built rather than via `buildStaticMethodSig`,
  because `MsilType` has no distinct unsigned-int variant to feed it (it
  would encode the SAME signed `I4`/`I8` element-type byte the existing
  `tokWriteLineInt`/`tokWriteLineLong` tokens already use, resolving to the
  SAME signed overload). Both overloads are real `[CLSCompliant(false)]` BCL
  members (same family as the `Byte`/`SByte`/`Int16` overloads), so no
  boxing/conversion is needed — `println` just dispatches to the matching
  token.
- `toString`/`print`/string interpolation/`+` string concatenation all
  route a bare numeric operand through boxing + `Object.ToString()`; a new
  `boxIfNeededUnsignedMsil` (and its `boxTypeRefUnsignedMsil` helper,
  boxing `MInt`/`MLong` as the new `System.UInt32`/`System.UInt64` TypeRefs
  instead of `boxTypeRef`'s default `System.Int32`/`System.Int64`) replaces
  the plain `boxIfNeededMsil` at every such call site when the operand is
  unsigned-flavored. Manual testing surfaced THREE more call sites sharing
  this exact "box then `Object.ToString()`" shape that the issue's own fix
  sketch didn't enumerate, fixed here rather than filed as follow-ups (same
  root cause, same one-line-per-site fix): the `.toString()` UFCS/member-
  call spelling (`lowerMethodCallMsil`'s `memberName == "toString"` arm —
  a codegen path entirely SEPARATE from the free `toString(x)` builtin,
  confirmed by reproducing `a.toString()` rendering `-1294967296` while
  `toString(a)` on the same `a` already rendered correctly); `format1`/
  `format2`/`format3` (`String.Format`'s `{0}` placeholder boxes its arg
  the same way); and `s += x` / `xs[i] += x` compound-assignment string
  concatenation (`emitCompoundCombineMsil`/`emitCompoundCombineSlotMsil`).
  Boxing an `int32`/`int64` CLR-native stack value as
  `System.UInt32`/`System.UInt64` is ECMA-335-legal (§III.4.1's `box`
  operand table treats the signed and unsigned built-in value types of a
  given width as stack-compatible, the same rule `MByte`'s box-as-
  `System.Byte` already relies on) — the bit pattern is identical either
  way, only the boxed TYPE IDENTITY differs, which is exactly what
  `Object.ToString()`'s virtual dispatch keys off to reach
  `UInt32.ToString()`/`UInt64.ToString()`.

**Scope.** Deliberately bounded to the shape the issue's own fix sketch asks
for: a bare name previously marked at a param/`val`/`var`/`let` binding
site, or a `u32`/`u64`-suffixed literal — NOT a function call's declared
return type or a container-element (`slice[UInt]`/`Map[K, ULong]`) read,
which is what the JVM backend's OWN later `#6754`/`#6759` follow-ons widened
`isUnsignedExpr` to cover, past its original (and this fix's matching)
shape. Neither gap silently drops correctness: an expression of either
excluded shape still compiles and runs correctly for every value that fits
the signed range either way, understating "unsigned" only for a
sign-bit-set value reached that way — tracked as a smaller, separable
follow-up if it's ever reported, not filed speculatively here. A
closure-hoisted (captured) `var` (promoted to a heap cell, no local slot to
key `unsignedSlots` on) is a second, narrower, documented gap for the same
reason — see `FuncCtx.unsignedSlots`'s own doc comment.

**Coverage.** Extended the dual-target `range_subtype_self_test.l` (the
established `UInt`/`ULong` test home per #6756) with a new bare-scalar
section: relational comparison (including a param-typed and a `var`-typed
case), division/remainder, `toString`/interpolation/concatenation, a
block-shadow isolation regression (A/B-verified, mirroring the JVM
backend's #6754 finding-2 shape), and an in-`@test_module` println smoke
test — for both `UInt` and `ULong` at/above the sign-bit boundary, on BOTH
targets (JVM was already correct via #6748/#6754, so this doubles as a
genuine cross-target parity check, not just an MSIL-only pin). Also:

- Added `range_subtype_self_test.l`'s previously-missing dotnet-target CI
  leg — despite the file's own header calling the dotnet leg
  "load-bearing," only the `--target jvm` leg was actually wired in
  `ci.yml`; the new bare-scalar section needs a dotnet-target CI run to mean
  anything, since the fix under test is dotnet-only.
- Added a dedicated CI step (`lyric run --target dotnet` on a small
  standalone program, its real captured stdout asserted directly — the same
  pattern the existing `println(Bool)` parity step already uses) asserting
  `println`'s ACTUAL output bytes for a sign-bit-set `UInt` and `ULong`.
  Deliberately NOT an `@test_module`-embedded capture (unlike the JVM
  backend's `unsigned_int_ops_jvm_self_test.l`, which redirects
  `System.setOut`/`PrintStream` from inside test cases): a `@test_module`'s
  synthesised `main()` also calls `println` to emit every test's own TAP
  result line, so redirecting `System.Console.Out` process-globally from
  inside a test risks leaving it redirected — and every LATER test's TAP
  line silently swallowed — if that test's own assertion panics before
  restoring it. A plain standalone program run via `lyric run` carries no
  such hazard.

Verified against a from-source `make lyric` build: `range_subtype_self_test.l`
green on both `--target dotnet` and `--target jvm`; the standalone
`println(UInt)`/`println(ULong)` repro programs print the correct unsigned
decimal (`3000000000`, `9223372036854775811`) instead of the pre-fix signed
misread; `byte_arithmetic_self_test.l` and `list_literal_index_self_test.l`
(adjacent binop-lowering-path regression suites) unaffected.

**Related:** #6756, #6782 (the crash-class fix this follows up on), #6748,
#6754 (the JVM backend's mirrored — and, for the container-element/call-
return widening, slightly broader — fix), `D-progress-0890` (full #6756
account).
