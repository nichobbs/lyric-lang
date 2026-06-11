# 41 — Self-hosted compiler gap analysis vs. language reference (production readiness)

_Status: **Re-verified 2026-06-03** (source-checked, all four severity bands).
The body below is the **2026-05-29 re-audit**; the per-gap status cells in §3
have been refreshed against live source on 2026-06-03 and a consolidated
delta is in **§10**. ~40 PRs (D-progress-323…367) landed between the two dates
and resolved or advanced a dozen gaps — most notably indexed assignment (C6),
the MethodSpec table (M5), range-`for` (H19), Char match literals (H18), and the
whole auto-FFI chain via the metadata reader (epic #1622: C9/H8/H9). The
CRITICAL **soundness floor (Band 1) is unchanged** — the front-end is still
advisory.  The Band 2/3 correctness floor has narrowed: `?` (#1475), `==`
(#1480), and `defer` (#1477) no longer miscompile; `await`/`async` remain the
silent-miscompile gap.  This remains the gating list for a v1.0 tag and is
cross-linked from `docs/36-v1-roadmap.md` §R7._

_This is a full re-audit of the self-hosted Lyric compiler against
`docs/01-language-reference.md` for the **`--target dotnet` (MSIL) channel only**.
It supersedes the original 2026-05-20 draft, which is now substantially stale —
the compilation-pipeline disconnect it called CRITICAL has since been fixed, the
self-hosted MSIL backend grew enum/interface/opaque/protected/aspect/derive
coverage, and the #1442 merge added closed-generic instance tracking. Where this
re-audit corrects a 2026-05-20 finding the change is called out in §7._

_JVM is **out of scope** for this audit (deliberately deferred per the review
brief). The goal measured against is a **functionally complete, production-grade
compiler written in Lyric — no F# shims, no workarounds — supporting all
language features on the .NET runtime and AOT-compilable.** The JVM counterpart
audit and remediation plan lives in `docs/44-jvm-production-readiness-plan.md`._

_All file:line citations are to the working branch at the time of audit. The
audit was performed by reading the current source, not by trusting prior docs._

---

## §1  Executive summary

The headline finding of the 2026-05-20 draft — "neither self-hosted backend
invokes the self-hosted middle-end" — is **no longer true**. The default
`lyric build`/`lyric run --target dotnet` path is now **fully self-hosted and
in-process**: the AOT trampoline → Lyric-emitted `cli.l` → `emitter.l` →
`Msil.Bridge` chain runs the complete middle-end
(`parse → alias-rewrite → typecheck → modecheck → contract-elaborate → derive →
mono → weave → lambda-lift → codegen → contract-metadata embed`) and writes PE
bytes directly, with **no F# `--internal-build` subprocess hop** for .NET and no
`System.Reflection.Emit`. That is a genuine, large advance and the bands below
should not re-litigate it.

What remains between today's state and "production-grade, all features, .NET,
AOT" falls into **five bands**, ordered by how badly they break the production
bar:

1. **The front-end does not reject invalid programs (CRITICAL).** The
   self-hosted type checker is a bottom-up, error-tolerant *inference* pass, not
   a sound gatekeeper. ~12 expression forms infer `TyError`, which `typeEquiv`
   treats as "matches anything", so entire classes of type error are
   unreachable. Match exhaustiveness now exists (T0016, #1483 split 1 — unions,
   enums, `Bool`, unbounded scalars); still missing: visibility
   enforcement, no opaque representation-hiding, no impl/interface conformance,
   and no §5.2 parameter-mode enforcement. Worse, on the **single-file** build
   path the checker's diagnostics are downgraded to advisory
   (`msil/bridge.l:92`) while the **multi-package** path aborts on them
   (`bridge.l:395`) — the same source can build on one path and fail on the
   other.

2. **Several backend constructs silently miscompile (CRITICAL).** Not panics —
   *silent wrong code*: `await`/`spawn` run synchronously and return the
   unwrapped/awaitable value, and `async func` returns a bare value instead of
   `Task[T]`. (Three former members of this list are now fixed: `?` propagation
   — #1475; `==`/`Map`-key structural equality for `@derive(Equals)` /
   `@derive(Hash)` records is now fully wired — #1480/#1796, incl. synthesised
   `Object.Equals`/`GetHashCode` overrides; and `defer` now runs at scope exit
   via `try`/`finally` lowering — #1477.) Each remaining item compiles without
   error and produces a wrong program — the failure mode the project standard
   most explicitly forbids.

3. **Async/await has no self-hosted implementation (CRITICAL).** There is no
   `IAsyncStateMachine` / `ValueTask` synthesis and no lazy
   `IAsyncEnumerable[T]` generator in `lyric-compiler/msil/`. The real
   implementation (~110 KB of F#: `AsyncStateMachine.fs` + `AsyncGenerator.fs`)
   lives only on the legacy F# path, which the self-hosted CLI no longer routes
   to. This is the single largest remaining port.

4. **Generic *types*, key item kinds, and FFI shapes are erased or stubbed
   (HIGH).** User generic types (`record Box[T]`, `union Tree[T]`) are
   type-erased to a single non-generic TypeDef with `object` fields; protected
   types emit **zero locking**; range-subtype bounds are dropped (no validation)
   _(`@projectable` opaque twins are now generated on both targets — H2
   resolved, PR #3015 + #3044)_; wire blocks drop
   `bind`/`scoped`/`provided`; default/named/`out`/`inout` arguments are
   mis-handled. _(An `@externTarget` whose signature touches a class/object
   type used to emit a runtime-throw stub; that is now resolved — #1504
   part 1 — encoding real `TypeRef`-backed MemberRefs.)_

5. **One F# DLL is still load-bearing at runtime and AOT is unconfigured
   (HIGH).** _(`Msil.Kernel.ByteWriter` was a `Lyric.Jvm.Hosts.dll`
   boundary on every emitted byte; #1492 replaced it with a pure-Lyric
   `List[Byte]` buffer — `System.BitConverter` is the only host extern — with
   byte-identical output, so `--target dotnet` no longer routes bytes through
   that F# DLL.  Only `Lyric.Emitter.dll` remains load-bearing today; #1600.)_
   Core stdlib kernels
   (`http`/`process` still — `console`/`env`/`log` migrated to direct BCL
   externs in #1493) extern into `Lyric.Emitter.dll` —
   the same assembly that carries the Reflection.Emit F# emitter. No
   `<PublishAot>` is set anywhere, so the "AOT-compilable" goal is currently
   aspirational.

**Bottom line.** The pipeline is now the right shape and a large slice of the
language works end-to-end on self-hosted .NET. But a non-trivial program can
today (a) pass a non-gating type check, (b) hit a silent miscompile of `?`,
`await`, `defer`, or `==`, or (c) drag two F# DLLs (one Reflection.Emit
laden) onto its runtime closure. None of those is acceptable at the project's
production bar, and AOT is not yet wired.

---

## §2  The default `--target dotnet` pipeline (verified from source)

```
lyric build foo.l                       (default target; "jvm" is the only other value, cli.l:358-365)
  └─ bootstrap/src/Lyric.Cli.Aot/Program.cs:20      pure trampoline → Lyric.Cli.Program.main
       └─ lyric-compiler/lyric/cli.l                buildOne → Emitter.emit(req, target=Dotnet)
            └─ lyric-compiler/lyric/emitter.l        Dotnet → emitMsilInProcess (NO subprocess)
                 └─ lyric-compiler/msil/bridge.l     compileToMsilWithVersion
                      ├─ parse                       reportAndAbort     → FATAL   (bridge.l:64)
                      ├─ AliasRewriter.rewriteFile                              (bridge.l:89)
                      ├─ TypeChecker.checkWithImports reportDiagnostics → ADVISORY ⚠ (bridge.l:91-92)
                      ├─ ModeChecker.checkFile        reportAndAbort     → FATAL   (bridge.l:94-95)
                      ├─ ContractElaborator.elaborateFile                       (bridge.l:97)
                      ├─ Derives.deriveFile           (transform)               (bridge.l:100)
                      ├─ Mono.monoFile                reportAndAbort     → FATAL   (bridge.l:103-104)
                      ├─ Weaver.weaveFileWithDiags    reportAndAbort     → FATAL   (bridge.l:135-136)
                      ├─ liftLambdasMsil → addPackageTokens → codegenMPackage    (bridge.l:141-148)
                      ├─ embedLyricContract (Lyric.Contract resource)            (bridge.l:162)
                      └─ lowerMPackageWithCtx → raw PE bytes → Std.File.writeBytes(bridge.l:165-168)
```

- **No `--target dotnet-legacy`.** The CLI maps anything ≠ `"jvm"` to `Dotnet`
  (`cli.l:358-365`). The string `dotnet-legacy` survives only in stale `panic`
  messages in `codegen.l` (1852/1855/1858/1931) — pointing users at a flag they
  can no longer select.
- **Project / multi-package builds are self-hosted too.** `Emitter.emitProject`
  → `emitProjectInProcess` → `Msil.Bridge.compileProjectToMsilWithRestoredAndVersion`
  (`emitter.l:531/599`, `bridge.l:280`), including cfg feature erasure, in-process
  restored-dependency loading, per-package import scoping (#1378/#1435), and
  manifest version threading. The F# `--internal-project-build` subprocess is
  invoked **only for `--target jvm`** (`emitter.l:704`).
- **PE emission is genuine direct-byte assembly** — `pe.l`/`assembler.l`/
  `tables.l`/`heaps.l` write raw ECMA-335 bytes. There is **no**
  `System.Reflection.Emit`, `PersistedAssemblyBuilder`, `ManagedPEBuilder`,
  `DynamicMethod`, or `ILGenerator` in the self-hosted MSIL tree, and extern
  resolution is table-driven, not reflection-driven (`ffi.l:191-196`). This is
  AOT-shaped.

---

## §3  Consolidated gap inventory (severity-ordered)

Severity is judged against "production-ready self-hosted .NET compiler
supporting all language features."

### CRITICAL

| # | Gap | Evidence | Effort |
|---|---|---|---|
| C1 | Type checker is advisory on the single-file build path (`reportDiagnostics`), fatal on the project path (`reportAndAbort`). Type-broken single files compile to broken IL silently; same source diverges between paths. **Gate progress (#1488):** the single-file false-positive surface is being closed category by category before the flip. **(A) `result` contextual-keyword shadowing cleared (D086, D-progress-420):** a local named `result` now types as its binding, not the return type, clearing the `T0032`/`T0060` swarm on `environment_tests`/`path_tests`. **(C) argument-type overload resolution cleared (D-progress-421):** same-name/same-arity overloads (`toUpper` Char-vs-String, `join` String-vs-slice) now dispatch by argument type, clearing `string_tests`. **(B) generic return-type instantiation cleared (D-progress-424):** a generic call's return is inferred from its arguments (`unwrapOr(…): T` → `Int`), clearing `parse_tests`. With A/B/C done, `environment_tests`/`path_tests`/`string_tests`/`parse_tests` single-file builds are clean. **(D) cross-package name collision cleared (D-progress-427, superseded by D-progress-429):** the initial fix spread the file's imported packages last (`orderStdlibPkgsByImports`) so the imported package won last-registered-wins resolution; this was superseded by proper **package-scoped name resolution** (#2271, D-progress-429), where each imported package resolves against its own decls — so a file importing only `Std.Regex` resolves `RegexError` to `Std.Regex`'s union, clearing the phantom-`RegexBug` `T0016` and `RegexError`-vs-`RegexError` `T0043` on `regex_tests`. **(E) range-subtype arithmetic cleared (D-progress-431):** `isNumericType`/`isOrderedType` now recurse through `TyRefined`, so an inline `Int range 0 ..= 100` parameter is numeric/ordered — clearing the spurious `T0030`/`T0031`/`T0033` on `examples/prove_demo.l`. Remaining: **(F) interface subtyping at argument positions cleared (D-progress-432):** a `TrackedFeed` that `impl`s `PriceFeed` is now accepted where `PriceFeed` is expected (`argSatisfiesParam` + `SymbolTable.impls`), clearing the `T0043` half of `mocking_tests`. **(G) `@stubbable` synthesis ported (D-progress-433):** `Lyric.Stubbable` synthesises the `<Name>Stub` record + impl before type-check (`Msil.Bridge.stubbableRewriteFile`), so `PriceFeedStub`/`TaxProviderStub` resolve — `mocking_tests` now builds clean self-hosted. **(H) alias-aware qualified-call resolution (D-progress-434):** the alias rewriter now rewrites `Rx.tryCompile` to the fully-qualified `Std.RegexSafe.tryCompile` (instead of dropping the package), `ResolvedSignature` carries `originPackage`, and `findDirectSig` prefers the same-arity overload whose package matches the call's prefix — so `regex_safe_tests` (two identically-signatured `tryCompile` overloads disambiguated only by alias) builds clean. **(I) Byte/Int conversion surface cleared (D-progress-436/437):** the stage-0 emitter gained the spec §541 primitive conversion methods (`.toInt()` etc.) so spec-correct code compiles on both paths; `encoding_tests` and `metadata_reader_tests` (the latter via `LYRIC_LOAD_COMPILER`) are now clean. **FLIP DONE (D-progress-438):** with every single-file-buildable surface diagnostic-clean (all stdlib tests bar the two `LYRIC_LOAD_COMPILER`-only compiler-internal ones, all `examples/`), `bridge.l`'s single-file type-check is now `reportAndAbort` — type errors in `lyric build <file>` abort instead of emitting broken IL, matching the project path. Verified: emitter 843/843, cli 84/84, weaver/cfg_gate/bitwise/conv_methods self-tests green, examples + stdlib single-file sweep clean. Remaining (not flip blockers, tracked separately): `msil_project_bridge_tests` needs cross-target JVM-kernel `extern type` resolution in the `LYRIC_LOAD_COMPILER` loader (its closure pulls in `Jvm.Bridge`→`Jvm.Kernel`), and the JVM single-file path (`jvm/bridge.l`) flip. | `bridge.l` single-file path now `reportAndAbort` | **DONE** |
| C2 | Type checker is unsound: several expr forms infer `TyError`, a universal unifier; no record-ctor checking; `index`/`lambda`/`if`/`match`-branch results untyped. **Shipped:** match exhaustiveness (T0016, #1483 split 1: unions/enums/`Bool`/unbounded scalars; `EMatch` infers its scrutinee); `EPropagate` (`?`) unwrap typing (#1483 split 2a). **`EIndex` unblocker shipped (2b, #1901, D-progress-405):** the numeric/character conversion-method family `.toByte()`/`.toInt()`/`.toLong()`/`.toChar()`/`.toDouble()` now type-checks (target primitive) and codegens to native width conversions on **both** targets (MSIL `conv.*`; JVM `i2l`/`l2i`/… with `.toByte()` masked to MSIL's unsigned `conv.u1` semantics), replacing the throw-stub. **`EIndex` element typing shipped (2b, #1901, D-progress-407):** `recv[i]` now carries the receiver's element type — `slice[T]`/`array[N,T]` → `T`, `String` → `Char`, `List[T]` → `T`, `Map[K,V]` → `V` — so byte/char indexing is sound (`a[i].toInt()` migrations in `lyric-auth`). **`EBlock`/`EUnsafe`/`EResult` shipped (D-progress-408, D081):** enclosing-function context (`returnTy`/`genericNames`) is now carried on `Scope`, so a value-position brace/`unsafe` block types as its trailing expression via a divergence-aware `checkBlock` (a `return`/`throw`/`break`/`continue`-terminated block is `Never`), and `result` types as the return type. **Parser statement-end fix shipped (#1943, D-progress-410):** a brace-terminated `if`/`match` in statement position is now a complete statement (not a binary-operator LHS), fixing the `if { return … }`-then-`-1` mis-parse that silently miscompiled the fall-through value — clearing the prerequisite for `EIf`-branch typing. **`EIf`-branch typing shipped (#1943, D-progress-414):** an `if`/`else` takes the unified type of its branches (T0067 on a mismatch); an `if` without `else` is `Unit`; a diverging branch is `Never` and is absorbed. **Generic union-constructor typing shipped (#2142 prereq, D-progress-418):** `Some(value=x)`/`Ok(v)`/`None` now type as the parent union instantiated from the argument types (`Some(value: String)` → `Option[String]`), not `TyError` — the prerequisite for `EMatch`-branch unification. **`EMatch`-branch typing shipped (#2142, D-progress-419):** a value-position `match` now takes the unified type of its arm bodies (T0067 on a genuine mismatch); each arm is checked with its pattern variables bound to their destructured types (`bindPatternTyped` — `Some(ns)` on `Option[T]` binds `ns:T`, constructor sub-patterns instantiate field types against the scrutinee's type args), nullary constructor patterns don't shadow the constructor in the arm body, and still-generic field types are erased to `TyError` (lenient) rather than tripping a false mismatch. **Argument-type overload resolution shipped (#1488 category C, D-progress-421):** same-name/same-arity functions that differ only in parameter types (`Std.Char.toUpper(Char)` vs `Std.String.toUpper(String)`; `Std.Path.join(String,String)` vs `Std.String.join(String,slice[String])`) no longer collide under first-in-wins — each non-generic sig registers under an indexed `arityKey@i` slot and `findDirectSig` picks the candidate whose params `typeEquiv`-match the args, after trying the shadow-preserving primary first. **Generic return-type instantiation shipped (#1488 category B, D-progress-424):** a generic call's return type is now inferred from the argument types (`unwrapOr(o: Option[T], default: T): T` on an `Option[Int]` returns `Int`, not the raw `TyVar("T")`) via `instantiateReturnType` (deep param/arg structural matching + `substituteTyVars`), clearing the `T0033` on `unwrapOr(…) < 0`. Remaining `TyError` forms: `ELambda`, `ETypeApp`, `EForall`/`EExists`, `EAssign`, tuple-destructure sub-bindings, record-ctor argument checking. | `typechecker_exprs.l`, `typechecker_types.l:130-131`, `typechecker_stmts.l:14-51` | L |
| C3 | ~~`?` propagation (`EPropagate`) is a no-op — `x?` compiles as `x`, no unwrap, no early-return.~~ **RESOLVED (#1475).** The `Lyric.Propagate` middle-end pass (`lyric-compiler/lyric/propagate.l`, run from `bridge.l` after the elaborator) rewrites `e?` into a `match` that unwraps `Ok`/`Some` and early-returns `Err`/`None`, keyed off the enclosing function's declared return type; a non-`Result`/`Option` enclosing function is rejected with `F0020`. (`try?`/`ETry` is never produced by the self-hosted parser, so its codegen arm is dead.) Verified by `propagate_self_test.l` (incl. `?` inside a `while` loop, after #1779 fixed the `List[ValueType]` element-comparison miscompile). Note: `?` inside an impl/interface method body is still blocked by a pre-existing early-`return` codegen defect, #1784. | `propagate.l`; `bridge.l` | M |
| C4 | ~~Silent miscompile of `@externTarget async func`~~ **Phase A shipped (D-progress-415 / D085):** `@externTarget async func` now correctly unwraps `Task<T>→T` via `Task<T>::get_Result()` / `Task::Wait()` after the BCL call; `EAwait` is correct as a no-op (all callees return T synchronously). **Remaining:** user-defined `async func` still returns T (not `Task<T>`), so C# interop and proper concurrent async are blocked; no `IAsyncStateMachine` synthesis; `ESpawn` no-op. Phase B (SM synthesis, `Task<T>` return, concurrency) tracked in epic #2070. | `codegen.l` `EAwait`/`ESpawn`; `async_sm.l` not yet created | L (#2070 Phase B) |
| C5 | Async generators use eager collect-all into `List<object>`, not lazy `IEnumerable`/`IAsyncEnumerable`; return type forced to List; unbounded generators buffer forever. **Planned in epic #2070** (slice 5: eager-producer `IAsyncEnumerable[T]` class first, then async-iterator on the await engine). | `codegen.l` generator path (6953-7135) | XL (#2070) |
| C6 | **Fixed (#1530).** Indexed assignment `a[i] = v` previously silently discarded the store (value evaluated then popped); the `EIndex` assignment target now emits `List[object]::set_Item`. Compound indexed forms (`a[i] += v`) hard-fail with a clear build error pending element-type plumbing (#1481). | `codegen.l` `lowerAssignExprMsil` EIndex arm | Resolved |
| C7 | ~~`defer` runs its body inline immediately, not at scope exit.~~ **Resolved (#1477 / D-progress-374):** `defer { D }` lowers the rest of its scope to `try { rest } finally { D }`, so D runs on fall-off, early `return` (via the function epilogue, #1477 foundation), `break`/`continue` (via `leave`), and exception unwind; multiple defers nest in reverse order. | `codegen.l` `lowerStmtsFromMsil` / `lowerStmtsExprFromMsil` | ✅ |
| C8 | **Fixed for in-bundle types (#2362 — D-progress-453 records, D-progress-455 unions).** In-bundle generic *records and unions* are reified: GenericParam rows (table 0x2A), VAR-typed fields (`value: T` → `FIELD VAR(0)`), arity-suffixed CLR type names (`Box`1`, `Maybe`1`, `Maybe_Just`1`), AutoLayout, construction via closed-instantiation TypeSpec `.ctor` MemberRefs, and TypeSpec-parented field reads — verified for multi-field value-type instantiations (`Pair[Int,Int]`, `Pairish[Int,Int]`). Unions: each case extends the open base instantiation (`Maybe`1<!0>`, a TypeSpec); nullary cases are `newobj`-each-time (no singleton — Q-GEN-001 resolved); matching via closed-TypeSpec isinst/castclass/ldfld. #2362 closed here: an exact stage-3 stdlib byte-match was **not pursued** (the self-hosted emitter already produces structurally-correct generic `Option`/`Result` but with the arity-suffix correctness fix F# omits, and self-compiling the whole stdlib is blocked on front-end completeness — §R7); see `docs/43`. **JVM parity gap (2026-06-07):** the JVM backend does not yet emit truly generic TypeDefs for in-bundle generic records/unions (no JVM equivalent of GenericParam rows, open-type field descriptors, or TypeSpec-parented construction); JVM generic-type emission is deferred and tracked under Band 4 of this doc and epic #2359. | `codegen.l` (`lowerRecordMsil`/`lowerUnionMsil`, `typeExprToMsilCtx`, `buildInBundleGenericCtorTok`, EMember, pattern test/bind); `lowering.l` (`lowerMRecord`/`lowerMUnion`, GenericParam emit); `tables.l` (GenericParam 0x2A) | In-bundle MSIL ✅; JVM deferred (#2359); stdlib self-compile under §R7 |
| C9 | ~~`@externTarget` whose signature mentions any class/object type emits a runtime-throw stub instead of a real call.~~ **Resolved (#1504 part 1):** class-typed params/return now encode as real `ELEMENT_TYPE_CLASS + TypeDefOrRef` MemberRefs (`buildFfiMethodSigCtx`/`resolveFfiClassTypeRef`), resolving extern types via `externTypeNames` → CLR TypeRef. Verified end-to-end (`StringBuilder` ctor + instance calls). Remaining #1504 parts: unresolved-type diagnostic (H8), instance/non-void auto-FFI (H9), generic externs (blocked on #1497). | `codegen.l` `buildFfiMethodSigCtx` | ✅ |
| C10 | ~~Opaque representation-hiding not enforced.~~ **RESOLVED (#1485):** cross-package **construction** of an opaque type is rejected (**T0100**), cross-package **pattern-matching** of its representation (record/constructor pattern) is rejected (**T0102**), and field reads on opaque values resolve to `TyError` (non-resolving). Construction calls also yield the constructed type with named-field validation (T0101). Binding/wildcard match arms remain legal (the value is opaque-but-usable). | `typechecker_exprs.l` (`inferConstruction`, `checkOpaquePatternHiding`) | M |
| C11 | ~~`impl`/interface conformance never checked; default-interface-method bodies discarded.~~ **RESOLVED:** `checkImplConformance` reports missing abstract methods (**T0098**), arity mismatches (**T0099**), parameter-type mismatches (**T0106**), and return-type mismatches (**T0107**, #1486, #2939). Interface subtyping at argument positions wired via `SymbolTable.impls` / `argSatisfiesParam` (#1488). **DIM bodies lowered:** `IMFunc` members now compile via `lowerImplMethodMsil` into `MInterface.defaultMethods`; `lowerMInterface` emits them as concrete (non-abstract) MethodDefs with real RVA and `Public+Virtual+HideBySig+NewSlot` flags — the CLR dispatches through the DIM when the implementing class provides no override. Verified by `shm_interface_default_method` in `SelfHostedMsilBridgeTests.fs`. | `typechecker_checker.l`; `codegen.l`; `lowering.l` | ✅ |
| C12 | Protected types emit a plain record with **no lock field and no Enter/Exit** — zero mutual exclusion despite the doc-comment promising Monitor locking. | `codegen.l:5373-5482` | L |
| C13 | ~~§5.2 parameter modes unenforced.~~ **Front-end RESOLVED (#1487).** Codegen passes `out`/`inout` by managed pointer (#1761). Type-checker §5.2 enforcement, all packages: **`in` no-rebind** (**T0087**, resolves the V0001 collision); **`out`/`inout` value-type argument must be a writable l-value** (**T0085**; reference-type `inout` records mutated in place are exempt); **`out` definite-assignment** (**T0086** — an `out` param never assigned in the body; the sound never-assigned subset, full all-paths partial-assignment detection a refinement). (JVM by-ref parity is follow-up #1763.) | T0085/T0086/T0087 present | M |

### HIGH

| # | Gap | Evidence | Effort |
|---|---|---|---|
| H1 | ~~`==` does not dispatch to derived `equals`; no `GetHashCode` override.~~ **RESOLVED (#1480).** Two parts: (1) `==`/`!=` operator wiring — `BEq`/`BNeq` call the derived `<Type>.equals` for `@derive(Equals)` records/distinct types instead of static `Object.Equals`, so `a == b` is structural (recursive through nested derived records). (2) `Object.Equals(object)` + `GetHashCode()` virtual *overrides* are now synthesised on `@derive(Equals)`/`@derive(Hash)` record TypeDefs (`appendDeriveOverridesMsil`, delegating to the derived `equals`/`hash`; rows reserved in `addPackageTokens`), so BCL `Map`/`HashSet` key lookup is structural — two field-equal record instances hash and compare as the same key. Both depended on #1796 (mono no longer drops the synthesized helper). Verified by `equality_self_test.l` + `map_key_self_test.l`. (Map keys need both `@derive(Equals)` and `@derive(Hash)`, mirroring the .NET requirement. A `Map[Record, ValueType]` *value* still trips the unrelated #1835 bug.) | `codegen.l` `BEq`/`BNeq` → `derivedEqualsTokenMsil`; `appendDeriveOverridesMsil` | M |
| H2 | ~~`@projectable` opaque twin + `toExposed`/`fromExposed` never generated — `isProjectable` is computed but never read in `lowerMOpaque`.~~ **RESOLVED (#1500 / PR #3015, MSIL; #3044, JVM).** `lowerMOpaque` emits the `<Name>View` TypeDef (visible fields, view-substituted nested types), `toView()`, and eligibility-gated `tryInto()` with a declaration-order-independent `allProjFqns` pre-scan; the JVM backend mirrors it via `LPProjectable` → `lowerProjectableType` (D-progress-492/493). Verified in CI by `msil_self_test_m87.l` + `projectable_jvm_self_test.l` (native `lyric test`, both targets). | `msil/lowering.l` `lowerMOpaque`; `jvm/lowering.l` `lowerProjectableType` | L |
| H3 | **Fixed (#1501).** The distinct/range-type construction API is now synthesised by the self-hosted MSIL backend: `lowerMDistinctType` emits `.ctor(value)`, a static `from(x)` (throws `System.ArgumentOutOfRangeException` on a range violation), a static `tryFrom(x): Result[Self, String]` (returns `Err(message)`; emitted when `Std.Core.Result` is imported), and an inherent `toInt`/`toLong`/… projection; the `IDistinctType` codegen arm folds the `rangeClause` literals to integer/`Double` bounds and threads them onto `MDistinctType`. `TypeName.from`/`TypeName.tryFrom` resolve as static-on-type-name calls in `lowerMethodCallMsil`; `value.toInt()` resolves via the instance `methodTokens` path. Verified by `range_subtype_self_test.l` (closed/half-open boundaries, `Int`/`Long`, plain distinct round-trip) run under native `lyric test`. The pre-fix dead `lowerMRangeType` remains unused. Scope notes: `Double`-bound ranges are still rejected upstream by the type checker (`T0093`, integer literals only), so the `Double` bounds path is forward-compat only; and applying a generic stdlib helper (`isOk`) to a `Result` over a *user* type still erases its type arguments (#1498), so consumers use `match`. | `codegen.l` (`mkDistinctTypeIR`, IDistinctType arm, `lowerMethodCallMsil`), `lowering.l` (`lowerMDistinctType`) | **DONE** |
| H4 | **PARTIAL (2026-06-03).** `WMExpose` members lower; `bind`/`scoped`/`provided` are still dropped (`case _ -> {}`) and there is no topological ordering / cycle detection. | `codegen.l` wire-block lowering (`WMExpose` only); `typechecker_checker.l` | L |
| H5 | **PARTIAL (2026-06-03).** Record-constructor named args are now reordered to field-declaration order (`reorderCtorNamedArgs`, #1730 spinoff / f774979). **Function call sites still don't reorder named args and never fill defaults** (too few args → invalid IL). | `codegen.l` call-arg lowering; record ctor reorder present | M |
| H6 | **PARTIAL (2026-06-03).** `monoFileWithImports` is now live and the bridge passes `collectStdlibGenericFuncs` (#1753/#1727), so **stdlib** generic functions specialize into the consumer bundle. **User cross-package generic functions** are still not collected (imported gen-decl set empty for user calls). | `mono.l` `monoFileWithImports`; `bridge.l` (stdlib funcs wired, user funcs empty) | M |
| H7 | **PARTIAL (2026-06-07).** Generic *function* instantiation improved via #1727/#1753 mono. Generic *type* instantiation `Box[Int]` is now reified for in-bundle generic **records and unions** via the ctx-aware `typeExprToMsilCtx` (`MGenericInstByName`) — MSIL target only (D-progress-453 records, D-progress-455 unions, #2362). The legacy non-ctx `typeExprToMsil` still erases `TGenericApp`→`MObject` (only reached by callers that don't thread `cctx`). **JVM parity gap (2026-06-07):** the JVM backend does not yet emit truly generic TypeDefs for in-bundle types; JVM generic-type reification is deferred and tracked under epic #2359. | `codegen.l` `typeExprToMsilCtx` `TGenericApp` (in-bundle arm); legacy `typeExprToMsil`→`MObject` | M (MSIL in-bundle done; JVM deferred #2359) |
| H8 | ~~Unknown extern types silently bind to `System.Runtime` with no diagnostic.~~ **Resolved (#1504 H8):** `clrAssemblyResolvable` gates the FFI cascade; a type that is neither `System.*` nor a `Lyric.*` host now fails the build with a clear, type-specific diagnostic (codegen `panic`, matching the F0002 conflict panic) instead of mis-binding to `System.Runtime` → opaque runtime `TypeLoadException`. Applied on both the `@externTarget` and auto-FFI paths. | `ffi.l` `clrAssemblyResolvable` | ✅ |
| H9 | ~~Auto-FFI scoring only handles static void-returning methods; instance/non-void silently mis-bind.~~ **Resolved (#1504 H9):** auto-FFI cannot resolve a method's real signature without .NET metadata (the self-hosted emitter has no reflection over reference assemblies; D-progress-268), so any shape beyond *static / void / parameterless* was an `(object…):void` guess that mis-bound at runtime (`MissingMethodException`). `emitAutoFfiCallMsil` now **fails the build with a clear diagnostic** for any argument-bearing auto-FFI call, directing the user to an `@externTarget` wrapper (which supplies the real signature and supports instance / non-void / typed-param / class returns after part 1). The parameterless static-void shape (`GC.Collect()`) still works.  **Open sub-case:** parameterless static methods with a *non-void* return type (e.g. `Guid.NewGuid()`) are still emitted with the hardcoded `():void` signature and throw `MissingMethodException` at runtime; tracked under epic #1622.  **Superseded by epic #1622** (real metadata-based resolution — design in `docs/42-extern-metadata-resolution.md`), which would remove the guess entirely. | `codegen.l` `emitAutoFfiCallMsil` | ✅ (stopgap; #1622 supersedes) |
| H10 | Custom `@generate(Pkg.Name)` source generators exist (`generator/generator.l`) but are **never called from `bridge.l`** — inert on self-hosted .NET. | `generator/generator.l:1-16`; no ref in `bridge.l` | M |
| H11 | `old()`/`forall`/`exists` in `@runtime_checked` contracts **panic** in codegen (elaborator passes them through). | `codegen.l:1851-1858`; `elaborator.l:361-362` | M |
| H12 | Two F# DLLs were load-bearing at runtime. **ByteWriter resolved for MSIL (#1492):** `Msil.Kernel.ByteWriter` is now a pure-Lyric `List[Byte]` buffer (`System.BitConverter` the only host extern); a sample exercising Int/Long/Double/String compiles **byte-identical** to the old host (verified via `cmp`), and the MSIL path has zero `Jvm.Hosts` references (JVM target retains `Lyric.Jvm.Hosts`, out of scope per #1470). **Kernels partially resolved (#1493):** `console` (stderr → `Console.Error`/`TextWriter`), `env` (`verifier_env` → `Environment.GetEnvironmentVariable`), and `log` (→ console stderr) migrated to audited BCL externs, and the dead `ConsoleHelper`/`LogHelper`/`VerifierEnv` F# types were deleted. Remaining (verified 2026-06-03): `http` `defaultClient` singleton (`http_host.l` → `Lyric.Emitter.HttpClientHost.defaultClient`, blocked on a package-level class-`val` `.cctor` codegen gap — a class-typed package-level `val` compiles but its static field stays null at runtime) and `process_capture` (`process_capture_host.l` → `Lyric.Emitter.ProcessCapture.*`, deadlock-safe concurrent stdout/stderr reads need async, Band 3 #1489). **Newly surfaced 2026-06-03 (not in the 05-29 audit):** (a) ~~`lyric-stdlib/std/_kernel/testing_mocking.l` externs into `Lyric.Stdlib.StubCounterHost.*`~~ — **resolved (#1776, see L5)**; (b) `Lyric.Session.Host.dll` (ecosystem `lyric-session`) is an F# host on its consumers' runtime closure (see L6). Net remaining F#-host externs on the .NET path: **~11 live**. | `msil/_kernel/kernel.l`; `lyric-stdlib/std/_kernel/{http,process_capture}_host.l`; `scripts/bootstrap.sh` | M |
| H13 | No `<PublishAot>` configured; "AOT-compilable" unrealized and untested. | `bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj` | M (gated on H12) |
| H14 | ~~Visibility (`pub`/`internal`/`private`) stored but never enforced at use sites.~~ **RESOLVED (#1484).** `checkImportedVisibility` (`typechecker_resolver.l`) rejects a cross-package reference to a package-private (unmarked) symbol with **T0097** (`pub`/`internal` allowed cross-package within a project per ref §3.1); wired into `resolveTypePath` + `resolveExprPath`. (V0007/V0008 from the issue collide with the verifier, so the type-checker code T0097 is used.) | `typechecker_resolver.l` | M |
| H15 | `where T: Marker` bound satisfaction never checked at call sites; qualified constraint paths rejected (T0051). | `typechecker_exprs.l:603-723`; `typechecker_checker.l:372-373` | L |
| H16 | `alias X = Long` unresolvable as a type — alias has no `TypeId`, so `val v: X` → T0013 "not a type". | `typechecker_symbols.l:85-98` | M |
| H17 | ~~Loop `break`/`continue` whose jump target is outside an enclosing `try` region emitted `MBr` (unverifiable IL across a protected-region boundary).~~ **Resolved (#1481 item 3 / D-progress-371):** codegen tracks protected-region nesting depth (`tryRegionStack`) and the depth each loop was entered at (`loopTryDepth`); a break/continue escaping ≥1 open region now emits `leave`. Covered by `loop_eh_collection_self_test.l`. | `codegen.l` `emitLoopJumpMsil` + `lowerTryCatchMsil` | ✅ |
| H18 | ~~`Char`/`Float`/`Long` literal match patterns fall to the wildcard arm → always match.~~ **Resolved.** `Char` (#1769/#1770, D-progress-367), then `Long` (already emitting `MLdcI8+MCeq`) and `Float` (`MLdcR8+MCeq+MBrFalse`, #1481 item 1 / D-progress-370). All literal pattern kinds now emit real compares. | `codegen.l` `PLiteral` arm | ✅ |
| H19 | ~~Range-for (`for i in 0..n`) and any `a..b` expression panic (`ERange`).~~ **Resolved (#1478):** `for i in lo .. hi` / `..= hi` / `..< hi` parse and lower to a counting loop (`lowerForMsil`/`emitCountingForMsil`). Only a *standalone* range value (`val r = lo .. hi`) still panics — no `Range` value type, unused in stdlib/ecosystem. | `codegen.l` `lowerForMsil`; `parser_exprs.l` for-iter | ✅ |
| H20 | **RESOLVED (#1479 v1+v2).** Capturing closures work for both immutable and mutable captures, single level (including escaping closures returned from their defining function). **v1 (by value):** `lambdaCaptureNamesMsil` computes the capture set; immutable values are boxed into an `object[]` bound as the delegate's closed target, and the lifted `__lambda_*` reads each from a leading `object[] __caps` parameter (`ldelem.ref` + unbox). **v2 (by reference):** a captured `var` is hoisted (per a pre-pass over the function body) to a one-element `List[object]` heap **cell**; the closure captures the cell reference, so reassignments are shared in both directions (closure↔enclosing scope). Reads/writes route through `get_Item(0)`/`set_Item(0)`; compound `+=` honoured. Related: invoking a function-typed value `f()` (#1877) works via a uniform `Func` ABI; parameter-taking lambdas passed directly to a typed `(…) -> R` parameter work (#1939) — boxed args unboxed via annotation or HOF-signature propagation; combine freely with captures. Remaining (tracked in #1479): a lambda capturing from an enclosing **lambda**'s locals (multi-level nesting), and returned lambdas with un-annotated params (the orthogonal #1939 gap, fail-loud). Lambdas in `@test_module` self-tests hit #1854. | `codegen.l` `ELambda` arm + `lowerFuncMsil` `__caps`/cell path | ✅ |
| H21 | ~~`mapGet`/`map.remove` (#1602/#1727), `List.Contains`→`false`, `List.removeAt`→no-op, unknown method→pop+null.~~ **Resolved.** `mapGet`/`remove` (D-progress-364); `List.contains`/`removeAt` now emit real `List<object>::Contains`/`RemoveAt` and the unknown-method catch-all throws a clear runtime error instead of returning silent `null` (#1481 item 4 / D-progress-371). | `codegen.l` `lowerMethodCallMsil` | ✅ |
| H22 | ~~Compound assignment ignores the operator: string `+=` emits numeric `MAdd`; field `r.f += v` only stores; `a[i] op= v` hard-fails.~~ **Resolved (#1481 item 2 / D-progress-370):** compound assignment is a real read-modify-write honouring the operator (String `+=` → `String.Concat`) for local / `result` / record-field / `List`-element / `Map`-value targets. | `codegen.l` `lowerAssignExprMsil` + `emitCompoundCombine*` | ✅ |

### MEDIUM / LOW (selected)

| # | Gap | Evidence | Sev |
|---|---|---|---|
| M1 | In-bundle cross-package imports still fall through to `MObject` when tokens absent (Phase-1 independent-packages scope). | `bridge.l:208-214` | MED |
| M2 | ~~`IConst` constant-folds only `Int`; `Double`/`Long`/`String`/`Bool` consts emit a literal field valued 0.~~ **Resolved (verified 2026-06-03):** `ELiteral` codegen emits `MLdcI8`/`MLdcR8`/`MLdStr`/`MLdcI4` for Long/Double/String/Bool. | `codegen.l` `ELiteral` arm | ✅ |
| M3 | `IConfig` (config blocks, D046) compile to nothing — no env-var reader, no startup validation. | `codegen.l:6349` | MED |
| M4 | `@derive(Ord)` missing on all type kinds; union/enum derives deferred to F#. | `derives.l:25-26` | MED |
| M5 | ~~No MethodSpec table (tables stop at TypeSpec 0x1B) → cannot call open generic BCL methods.~~ **Resolved (#1497):** MethodSpec (table 0x2B) + `MethodSpecRow`/`addMethodSpec`/`ctxAddMethodSpec`/`buildMethodSpecBlob` shipped in `tables.l`/`lowering.l`, with serializer wiring (bitmask bit 43, row counts, row data). First consumer: an empty typed-slice literal `val xs: slice[T] = []` lowers to `System.Array.Empty<T>()` (a GENERIC-convention MemberRef instantiated by a MethodSpec) — fixing a latent miscompile (it previously emitted a `List<object>` that mis-read as `T[]`). Verified: PE carries a MethodSpec row decoding to the concrete element type; `shm_empty_slice_array_empty` bridge test. Generic-extern (#1504) and user-generic reify paths can now build on this. | `tables.l` `MethodSpecRow`; `lowering.l` `ctxAddMethodSpec` | ✅ |
| M6 | Numeric widening not applied (arithmetic requires exact `typeEquiv`); no checked-overflow awareness. | `typechecker_exprs.l:206-211` | MED |
| M7 | ~~`SItem`/`SInvariant` silently dropped in codegen.~~ **Stale (verified 2026-06-03):** `SInvariant` is lowered to `assert(inv)` at the loop-body top by the contract elaborator, so codegen's `SInvariant -> {}` correctly drops the redundant marker — loop invariants *are* checked at runtime (a violated `invariant:` panics; covered by `loop_invariant_self_test.l`). `SItem` is **never produced by the parser** (a nested `func`/type inside a block fails to parse, P0080), so `SItem -> {}` is unreachable dead code, not a dropped feature. Neither is a real gap. | `codegen.l` (`SInvariant`/`SItem` arms); elaborator | ✅ |
| M8 | Weaver `config`-fields-without-default emit a `panic` stub; `call.elapsed`/`call.caller` deferred (A0043 at weave time). | `weaver.l:24,30-35,773-780` | MED |
| M9 | `pub use Foo.bar` symbol-level re-export (Q022-1): an `ImportDecl.isPubUse` flag exists and the formatter renders it, but there is still **no item-level AST node** carrying the re-exported symbol, so the typechecker/codegen can't surface a named re-export. | `parser_ast.l` (`isPubUse` flag only; no `IPubUse` item kind) | MED |
| M10 | Stdlib-source parse errors swallowed during type-item collection → dropped symbols. | `bridge.l:780-786,795-798` | MED |
| L1 | Stale `--target dotnet-legacy` text in user-visible `panic` strings for a removed flag. | `codegen.l:1852-1931` | LOW |
| L2 | `ast.l` `ItemKind` diverges from the authoritative `parser_ast.l` (missing `IAspect`/`IConfig`) — latent maintenance hazard. | `lyric/ast.l:773` vs `parser_ast.l:623` | LOW |
| L3 | `weaver_self_test.l`/`weaver_ci_test.l` not wired into CI (#1324). | CLAUDE.md / #1324 | LOW |
| L4 | `Float` literals always lower to `MDouble` (32-bit `Float` not distinct); `BXor`/`Long` truncates to `MInt`. | `codegen.l:1459-1462,2142-2147` | LOW |
| L5 | ~~**NEW (2026-06-03).** `testing_mocking.l` declares `extern` against `Lyric.Stdlib.StubCounterHost.{newCounter,record,count,wasCalledWith}` but no such F# type exists under `bootstrap/src/` (the `Lyric.Stdlib` F# project was deleted, D-progress-140). `@stubbable` call-count assertions therefore fail to resolve on the self-hosted .NET path.~~ **RESOLVED (#1776):** stale `_kernel/testing_mocking.l` + `_kernel_jvm/testing_mocking.l` deleted (D-progress-467); the pure-Lyric `StubCounter protected type` in `std/testing_mocking.l` is the sole implementation. `stubbable.l` now synthesises `_counter: StubCounter = makeStubCounter()` fields for every supported method and injects `import Std.Testing.Mocking` automatically; the synthesised impl increments the counter on entry. Covered by `stubbable_self_test.l` on the self-hosted path. | `lyric-compiler/lyric/stubbable.l` | ✅ |
| L6 | **NEW (2026-06-03).** `lyric-session` ships an F# host (`Lyric.Session.Host.dll`) that lands on consumers' runtime closure — a second load-bearing F# assembly beyond `Lyric.Emitter.dll`. Migrate its boundary to audited BCL externs (`StackExchange.Redis` via `extern package`) per the no-F# rule. | `lyric-session/` host shim | MED |

---

## §4  What is genuinely production-solid now (do not redo)

- **Pipeline shape & dispatch.** In-process self-hosted .NET codegen is the
  default and only non-JVM path; AOT-shaped trampoline; full middle-end runs
  before codegen on both single-file and project paths (mode-check, mono, weave,
  parse all correctly fatal).
- **Direct PE emission** with no Reflection.Emit anywhere in the self-hosted MSIL
  tree (`pe.l`/`assembler.l`/`tables.l`/`heaps.l`).
- **Item kinds:** `IUnion` (base + case subclasses, payloads, nullary singletons,
  pattern dispatch), `IEnum` (full CLR enum with Constant rows), `IInterface`
  abstract method headers, `IOpaque` sealed body, `IRecord`/`IExposedRec`
  construction (equality caveat H1), `IVal` (literal inlining + token-shift-safe
  `.cctor`), `IExternType`, and the correctly-skipped compile-time-only kinds.
- **Generic *functions*:** same-package monomorphization with multi-source
  inference and a worklist for nested specializations; `Option[T]`/`Result[T,E]`/
  `List[T]` over stdlib/in-bundle element types track closed generic instances
  (incl. nested) via the #1442 `MGenericInst`/`contextHintTyArgs` work.
- **Contracts:** `requires`/`ensures` (incl. nested returns), loop `invariant:`,
  and protected-entry contracts all lowered to runtime asserts and applied
  unconditionally in default builds (covered by `contract_elaborator_self_test.l`).
- **Aspect weaver:** around/proceed/contract-composition/ordering plus the
  todo/06 config, call-context, and `@inline_template` extensions, invoked before
  codegen.
- **Deriving:** `equals`/`hash`/`show`/`toJson` *methods* synthesized for records,
  exposed records, and distinct types and emitted (caveat: not wired to `==`/
  `GetHashCode` — H1).
- **Contract metadata:** both reading and writing/embedding the `Lyric.Contract`
  resource are self-hosted (`bridge.l:986-1033`, `contract_meta.l`).
- **FFI:** `@externTarget` for primitive/String **and class/object** (#1504
  part 1) static/instance/ctor calls — class-typed params/return encode as real
  `TypeRef`-backed MemberRefs; `@externStatic`/`@externInstance` dispatch with
  conflict guard; unresolved externs emit an actionable runtime-throw stub
  rather than invalid IL.
- **Mode checker:** V0001–V0006, V0009–V0011 well-enforced for proof-required code
  (the strongest part of the front end).
- **Front-end enforcement that does work:** operator typing (T0030–T0037),
  range-subtype *declaration* validation (T0090/T0091/T0093), `where`-clause
  *declaration* validity (T0050/T0051), arity-keyed overload resolution,
  generator/`yield` placement (T0094–T0096), duplicate-name detection,
  local-binding type-equality (T0060–T0063).

---

## §5  Per-area detail

### 5.1  Front-end soundness (CRITICAL band)

Root cause (verified): `TyError` is a universal unifier (`typechecker_types.l:130-131`)
and the `Type` union is too coarse to carry the alias/distinct/opaque
distinction, `Future`/`Task`, or channels. So ~12 expression forms short-circuit
the whole `typeEquiv` machinery. The checker is a lint-grade advisory pass, not a
gatekeeper — and on the single-file path it isn't even allowed to gate the build.
Fixing this is a prerequisite for flipping `bridge.l:92` to fatal (C1) without
rejecting valid programs.

**Foundation shipped (#1482, D077):** the `Type` union now carries refinement
(range) bounds via an append-only `TyRefined(underlying, lo, hi, hiInclusive)`
case, populated by the resolver for inline refined types and consumed by a new
inline-literal range check (T0015).  Refinement is *transparent* to `typeEquiv`
(unwraps to underlying), so the widening adds no equivalence false positives —
gate-safe for C1.  `TyArray` already carried `size`.  The remaining coarseness
(representation tag, `Future`/`Task`/channel carriers) is deferred to its
consuming Band-1/Band-4 tasks, each adding the case it consumes append-only.

### 5.2  Backend silent miscompiles (CRITICAL band)

`await`, `spawn`, `defer`, and `==` each compile cleanly and run
wrong (C4–C5, C7, H1; `?` propagation (C3) is now fixed — #1475; indexed
assignment `a[i]=v` (C6) is now fixed — #1530).
The root cause is that the bridge pipeline has **no
desugaring/lowering pass** for `?`, `await`/async, `defer`, or range iteration —
those nodes arrive at codegen raw and are handled with placeholder
pass-throughs. Per the project standard, the honest interim for anything not yet
correctly lowered is a **hard diagnostic**, never a silent pass-through.

### 5.3  Async/await (CRITICAL band)

No `IAsyncStateMachine`/`ValueTask` synthesis, no lazy `IAsyncEnumerable[T]`.
The front end parses async fine; only backend codegen is missing. Porting
`AsyncStateMachine.fs` (~78 KB) + `AsyncGenerator.fs` (~31 KB) to Lyric MSIL
codegen (state-machine class synthesis, local→field promotion across
await/yield points, `AsyncTaskMethodBuilder` protocol, `AwaitUnsafeOnCompleted`,
TCS-backed `MoveNextAsync`) is the largest single remaining item.

### 5.4  Generics & FFI (HIGH band)

The #1442 merge is a real but narrow win: closed-generic *value* tracking for
cross-assembly heads. It did **not** give user generic *types* CLI generic
identity (C8), wire cross-package generic functions (H6), add a MethodSpec table
(M5), or fix the FFI class/object signature chokepoint (C9). The decision to
make on user generic types is monomorphize-the-type (extend `mono.l`, consistent
with the function strategy) vs. reify-as-CLI-generics (GenericParam +
GenericParamConstraint + MethodSpec + `constrained.`) — see §6 band 4.

### 5.5  AOT & F# residue (HIGH band)

Two F# DLLs sit on every .NET program's runtime closure (H12). They don't break
codegen under AOT (resolution is table-driven, not reflection-driven), but they
keep F# — including the Reflection.Emit emitter assembly — in the loop, blocking
both "no F# in the .NET path" and a clean NativeAOT publish (H13). The fix is a
pure-Lyric byte accumulator for the ByteWriter boundary and audited direct-BCL
externs (`System.Console`/`Process`/`Net.Http`/`Environment`) for the kernel
helpers, then `<PublishAot>` + a native-binary CI smoke test.

---

## §6  Remediation bands (updated 2026-05-29)

Ordered by the production bar. Bands 1–2 are the soundness/correctness floor and
should precede feature-completion work, because they stop *silent* wrongness.

### Band 1 — Front-end soundness floor (CRITICAL)
- Widen the `Type` union to carry range bounds, a representation tag
  (alias/distinct/opaque), array size, and `Future`/`Task`/channel (touches an
  `@stable` surface — needs a decision-log entry).  **FOUNDATION shipped
  (#1482, D077):** range bounds (`TyRefined`, transparent to `typeEquiv`) +
  inline-literal range check (T0015); `TyArray.size` pre-existing.  Remaining
  carriers (representation tag, `Future`/`Task`/channel) land append-only with
  their consuming tasks.
- Type the `TyError` expression forms: `EMatch`/`EIf` branch unification
  (**shipped** — D-progress-414/419), `EIndex` element type (**shipped** —
  D-progress-407), `ELambda` param/return inference, `EPropagate` return-compat,
  tuple-destructure sub-bindings, record-constructor argument checking.
- Add match exhaustiveness (**shipped** — T0016, #1483 split 1), visibility
  enforcement, opaque hiding, impl/interface
  conformance, and call-site `where`-bound satisfaction.
- Add a §5.2 parameter-mode pass that runs for **all** packages (not just
  proof-required).
- Then flip `bridge.l:92` to `reportAndAbort` and reconcile the two build paths
  (C1). This is the gate that makes "bad code fails to compile" true.

### Band 2 — Backend correctness floor (CRITICAL)
- Lower `?`/`try?` in the elaborator (where types are known) to match-unwrap +
  early-return; implement `defer`-at-scope-exit, range values +
  range-for, capturing-closure display classes, `break`/`continue`-via-`leave`,
  real Float/Char/Long match-literal tests, compound-assignment operator
  honoring, and the BCL stubs (Contains/Remove/RemoveAt). Indexed assignment
  `a[i]=v` shipped in #1530 (compound `a[i] += v` tracked in #1481). Where a
  correct lowering is genuinely out of scope, replace the silent pass-through
  with a hard diagnostic.
- Wire `==`/`GetHashCode` (and `Object.Equals` overrides) to the derived methods
  so structural equality and hashing actually work (H1).

### Band 3 — Async (HIGH, Phase A complete)

**Phase A shipped (D-progress-415):** `@externTarget async func` silent
miscompile fixed.  `MLdflda` instruction added.  `Task`/`Task`1` TypeRefs and
`Task::Wait()` MemberRef registered.  `emitExternTargetBody` now unwraps
`Task<T>→T` synchronously after the BCL call.  All 847 stdlib tests pass.

**Remaining for Phase B (still tracked in #2070):**
- Port `AsyncStateMachine.fs` to self-hosted MSIL codegen: synthesise
  `IAsyncStateMachine`-implementing SM struct TypeDef + fields + MoveNext (with
  `GetAwaiter()`/`GetResult()` for each inner await) + kickoff that returns
  `Task<T>`.
- `AsyncTaskMethodBuilder<T>`: `Create()`, `Start<SM>(ref SM)`, `SetResult(T)`,
  `SetException(Exception)`, `get_Task()` MemberRef/MethodSpec tokens.
- `Task<T>`-returning user-defined `async func` (needed for C# interop and
  concurrent async).
- `MethodImpl` rows for `IAsyncStateMachine::MoveNext` /
  `IAsyncStateMachine::SetStateMachine`.
- `ESpawn` implementation.
- Lazy `IAsyncEnumerable<T>` generators (C5).

The `addMethodImpl` function in `lowering.l` exists but is never called; wiring
it for SM synthesis is the main remaining lowering gap.

### Band 4 — Feature completion (HIGH)
- User generic types (monomorphize or reify — decision required), protected-type
  locking, ~~`@projectable` twins~~ (done — PR #3015 MSIL, #3044 JVM),
  range-subtype validation, wire
  `bind`/`scoped`/`provided` + ordering/cycle-detection, named/default/`out`/`inout`
  arguments, FFI class/object signatures + `clrAssemblyForType` hard-diagnostic
  fallback + auto-FFI beyond static-void, custom `@generate` generator wiring,
  `old()`/quantifier runtime lowering, `@derive(Ord)` + union/enum derives,
  `IConfig` lowering, MethodSpec table, cross-package generic-function mono
  (`monoFileWithImports` wiring), in-bundle cross-package token resolution.
  Metadata-based extern resolution (replacing the hardcoded `clrAssemblyForType`
  table + the auto-FFI guess) is epic #1622 — design in
  `docs/42-extern-metadata-resolution.md`.
  - **Open question — user generic types (C8), reify path:** the decision is to
    *reify* (emit truly generic TypeDefs: GenericParam table + VAR fields +
    instantiated TypeSpec construction/field/match), not erase. The execution
    plan is `docs/43-in-bundle-generics-plan.md` (epic #2359, prerequisite for
    full Stage 3 byte-match #2362). Open questions there: Q-GEN-001–Q-GEN-005.

### Band 5 — F# elimination + AOT (HIGH)
- Replace the `Lyric.Jvm.Hosts` ByteWriter boundary with a pure-Lyric byte
  accumulator; move the `Lyric.Emitter`-hosted kernel helpers to audited direct
  BCL externs; then add `<PublishAot>` (+ globalization/trim) and a CI smoke test
  that runs a real `lyric build` through the native binary.

### Band 6 — Acceptance gate
The self-hosted .NET compiler is production-ready when: every program in
`docs/02-worked-examples.md` builds and runs under `--target dotnet`; the parity
suite expands to one program per §§2–14 feature class; `lyric prove`/
`public-api-diff`/`test`/`doc` on every stdlib module match a baseline; both F#
DLLs are off the runtime closure; and `<PublishAot>` produces a working native
binary in CI.

---

## §7  Corrections to the 2026-05-20 draft

| 2026-05-20 claim | 2026-05-29 reality |
|---|---|
| "Neither backend invokes the middle-end; `--target dotnet` ships with NO compile-time validation." | False now. The full middle-end runs in-process; mode-check/mono/weave/parse are fatal. Type check runs but is advisory on the single-file path (C1). |
| "`--target dotnet-legacy` is the load-bearing path." | Removed from the CLI; only stale `panic` strings reference it. Default is self-hosted in-process. |
| §3.5 "TGenericApp defaults to MObject (`codegen.l:593`); `Lyric.Mono` not called from `Msil.Bridge`." | Stale. `monoFile` is wired (`bridge.l:103,403`); `TGenericApp` emits `MGenericInst` for cross-assembly heads (`codegen.l:1290-1313`). Erasure now applies to *user generic types* (C8), not all generics. |
| "MSIL: no `for` loops (panics)." | `for` over List/array and range-`for` (`lo .. hi` / `..= hi` / `..< hi`) both work (#1478); only a standalone `a .. b` *value* expression remains unsupported (H19). |
| "`SDefer` not implemented." | Resolved (#1477): runs at scope exit on all paths via `try`/`finally` lowering. |
| "Contract elaborator defers protected-type entries and loop invariants." | Both shipped (`elaborator.l:805-819,1046-1116`). |
| "Contract metadata embedding is F#-only." | Self-hosted (`bridge.l:986-1033`). |
| "Both backends skip `IEnum`/`IInterface`/`IOpaque`/`IProtected`/`IAspect`." | All have MSIL lowering now; the gaps are correctness (protected locking C12, opaque twins H2, default-interface-method bodies C11), not absence. |

---

## §8  Out of scope for this audit

- JVM target (deferred per the review brief).
- Performance/allocation profiling; compile-time benchmarks.
- Stage-2/3 reproducibility bootstrap.
- LSP completeness (separate audit).

---

## §9  References

- `docs/01-language-reference.md` — authoritative language description.
- `lyric-compiler/msil/{bridge,codegen,lowering,ffi,tables,pe,assembler,heaps}.l`.
- `lyric-compiler/lyric/{parser,type_checker,mode_checker,contract_elaborator,weaver,derives,mono,generator}/`.
- `lyric-compiler/lyric/{cli,emitter,contract_meta}.l`.
- `lyric-stdlib/std/_kernel/*_host.l`, `lyric-compiler/msil/_kernel/kernel.l`.
- `bootstrap/src/Lyric.Cli.Aot/`, `bootstrap/src/Lyric.Emitter/{AsyncStateMachine,AsyncGenerator}.fs` (unported async).
- `scripts/bootstrap.sh` (stage-1 bundle contents).

---

## §10  Re-verification delta (2026-06-03)

Every status below was re-checked against live source on 2026-06-03 (~40 PRs,
D-progress-323…367, landed since the 2026-05-29 body above). This section is
the **current authoritative snapshot**; where it disagrees with a §3 row, this
section wins.

### Resolved since 2026-05-29

| Gap | Resolution | PR / D-progress |
|---|---|---|
| C6 — indexed assignment `a[i]=v` silently discarded | `EIndex` assignment emits `set_Item` (List + Map); compound `a[i] op= v` now a real read-modify-write (#1481 item 2) | #1530 / D-progress-323; #1481 / D-progress-370 |
| C9 — `@externTarget` class/object signatures emit throw-stub | class-typed params/return encode real `TypeRef` MemberRefs | #1504 pt1 / D-progress-326 |
| H8 — unknown extern types bind silently to `System.Runtime` | `clrAssemblyResolvable` fail-loud diagnostic | #1504 H8 / D-progress-327 |
| H9 — auto-FFI arg-bearing calls mis-bind silently | fail-loud + real metadata resolution (epic #1622) | #1504 H9 + D-progress-344…362 |
| H18 — Char/Float/Long literal match always matches | `PLiteral` emits real compares for every literal kind (Char #1769; Float/Long #1481 item 1) | #1769 / D-progress-367; #1481 / D-progress-370 |
| H22 — compound assignment ignores the operator | read-modify-write honouring the op (String `+=` → Concat) for local/result/field/List/Map targets | #1481 item 2 / D-progress-370 |
| H19 — range-`for` panics | `for i in lo..hi` / `..=` / `..<` lower to counting loop (standalone range value still panics) | #1478 / D-progress-325 |
| M2 — only `Int` consts fold | all literal kinds emit correct `ldc`/`ldstr` | verified 2026-06-03 |
| M5 — no MethodSpec table | table 0x2B + `ctxAddMethodSpec` shipped; first consumer `Array.Empty[T]` | #1497 / D-progress-340 |

### Advanced to PARTIAL (progress, not closed)

| Gap | What shipped | What remains |
|---|---|---|
| C13 — parameter modes | `out`/`inout` codegen by managed pointer (#1761) | front-end §5.2 mode enforcement pass |
| H4 — wire blocks | `WMExpose` lowers | `bind`/`scoped`/`provided` + topo ordering / cycle detection |
| H5 — named/default args | record-ctor named-arg reorder (#1730) | call-site reorder + default filling |
| H6 — cross-pkg generic fns | stdlib generic fns monomorphize into consumer bundle (#1727/#1753) | user cross-package generic fns |
| H7 — generic-type instantiation | generic *function* mono improved | generic *type* `Box[Int]` still `MObject` (blocked on C8) |
| H21 — BCL stubs | `mapGet`→`Option`, real `Map.remove` | `List.Contains`→false, `removeAt`→no-op |
| M9 — `pub use Foo.bar` | `isPubUse` flag + fmt rendering | item-level AST node + checker/codegen |

### Still OPEN — the v1.0 gating list (updated 2026-06-09)

_Several items the 2026-06-03 snapshot listed as open have since shipped.
The authoritative tactical task list is `docs/12-todo-plan.md`._

- **Band 1 (front-end soundness, CRITICAL): COMPLETE.** All Band-1 items are
  resolved. Closed since 2026-06-03: advisory→fatal flip (C1, D-progress-438),
  visibility enforcement (H14, #1484), opaque hiding (C10, #1485), parameter-mode
  front-end (C13, #1487), `TyError` expression forms (C2, #2939), full
  impl/interface conformance including DIM body lowering (C11, #1486/#2939),
  `where`-bound satisfaction (H15, #2939), alias-as-type (H16, #2939), numeric
  widening (M6, #2939).
- **Band 2 (backend correctness, CRITICAL):** All major Band-2 items are now
  resolved: `?` (C3, #1475), `==`/`Map`-key structural equality (H1,
  #1480/#1837), `defer` (C7, #1477), all of #1481, try/catch-as-value-expression
  IL (#1823). H20 (capturing closures) **RESOLVED** (#1479 v1+v2 — immutable by
  value into `object[]`, `var` by heap-cell reference, single-level incl.
  escaping). Function-value invocation (#1877/#1939) works for zero-arg and
  annotated/HOF-propagated param-using lambdas. M7 is stale (loop invariants
  lowered by the elaborator; `SItem` never produced by the parser). Remaining
  tracked items: multi-level nested closure capture (#1479), lambdas in
  `@test_module` bodies (#1854).
- **Band 3 (async, CRITICAL):** Async SM synthesis **shipped** (Epic #2070
  Phases B.0–B.3 + spawn): `IAsyncStateMachine` / `AsyncTaskMethodBuilder` /
  `Task[T]` returns and `ESpawn` are implemented (verified by
  `async_sm_self_test.l`). Remaining correctness gaps: `await` inside a `try`
  block emits invalid IL (#2725, recent open); hardcoded `maxStack=8` risks
  `VerificationException` (#2712); lazy `IAsyncEnumerable[T]` generator
  synthesis (C5, Phase 5, #1490).
- **Band 4 (feature completion, HIGH):** C8 (cross-package generic-type
  reification — in-bundle MSIL records/unions done #2362; cross-package remains,
  #1496), C12 (protected-type locking — zero mutual exclusion emitted, #1499),
  H2 (`@projectable` twins, #1500 — **done**, PR #3015 MSIL + #3044 JVM),
  H3 (range-subtype validation, #1501), H10
  (custom `@generate` never invoked, #1505), H11 (`old()`/`forall`/`exists`
  panic, #1506), M3 (`config{}` no-op, #1508), M4 (`@derive(Ord)`/union/enum
  derives, #1507).
- **Band 5 (F# elimination + AOT, HIGH):** AOT **now wired** — `release.l`
  emits `<PublishAot>true</PublishAot>` and runs `dotnet publish
  -p:PublishAot=true`; H13 "confirmed absent" is no longer accurate. CI smoke
  test still needed. F# residue still load-bearing: H12 (HttpClientHost .cctor
  gap #1576, ProcessCapture async tail #1489), L6 `Lyric.Session.Host` (#1777).
  L5 `StubCounterHost` resolved (#1776).

### New findings (2026-06-03, not in the 05-29 body)

- **L5** — ~~`testing_mocking.l` externs into a non-existent `Lyric.Stdlib.StubCounterHost`;
  `@stubbable` counters are broken on the self-hosted path.~~ **RESOLVED (#1776)**:
  stale kernel externs deleted; `stubbable.l` wired to pure-Lyric `StubCounter`.
  (Added to §3, resolved in same pass.)
- **L6** — `lyric-session` drags `Lyric.Session.Host.dll` (F#) onto consumers'
  runtime closure — a second load-bearing F# assembly. (Added to §3.)

### Bottom line (updated 2026-06-09)

Since the 2026-06-03 snapshot, significant further progress has landed: async SM
synthesis shipped (Epic #2070 Phases B.0–B.3 + spawn), the advisory→fatal
typecheck gate flipped (C1, D-progress-438), visibility enforcement (#1484),
opaque hiding (#1485), parameter-mode front-end (#1487), TyError expression forms
(C2, #2939), full impl conformance including DIM body lowering (C11, #1486/#2939),
`where`-bound satisfaction (H15, #2939), alias-as-type (H16, #2939), numeric
widening (M6, #2939), and AOT wired via `release.l`.  **Band 1 (front-end
soundness) is now complete.**  The remaining v1.0 blockers are async correctness
tail (#2725 await-in-try, #2712 maxStack, C5 generators) and Band-4 feature gaps.
Band 2 is substantially resolved.  `docs/12-todo-plan.md` is the authoritative
task list; `docs/36-v1-roadmap.md` §R1–R6 are all done and tracking has moved to
docs/12.
