# Lyric Compiler Core — Code Review

Scope: compiler/src/Lyric.Lexer/, compiler/src/Lyric.Parser/, compiler/src/Lyric.TypeChecker/, compiler/src/Lyric.Emitter/, compiler/lyric/lyric/{lexer.l, parser/, type_checker/, mode_checker/, contract_elaborator/, mono.l}, and compiler/src/Lyric.Cli/{Program.fs, SelfHosted*.fs}.

Method: spec-vs-implementation read, F#-vs-self-hosted divergence diff, defensive edge-case enumeration on lexer / parser / type checker. lsp_diagnostics not available; dotnet build is too slow for an in-band run of this scope, so all findings come from source inspection.

## Severity legend

- CRITICAL — Wrong output / crash on plausible input.
- HIGH — Real correctness gap or known limitation that may surface as silent miscompilation or hard-to-diagnose error.
- MEDIUM — Maintainability / robustness issue that should be fixed before v1.
- LOW — Polish / clarity improvement.
- NIT — Trivial.

---

## 1. Lexer correctness (F# bootstrap)

### [CRITICAL] Surrogate-range escape throws ArgumentOutOfRangeException mid-lex
compiler/src/Lyric.Lexer/Lexer.fs:451, :497, :561, :607

The validator accepts any codepoint 0 <= v <= 0x10FFFF for \u{...} escapes, including the UTF-16 surrogate range 0xD800..0xDFFF. The decoded scalar is then fed to Char.ConvertFromUtf32, which throws on surrogate codepoints:

    | true, v when v >= 0 && v <= 0x10FFFF -> v   // accepts 0xD800
    ...
    sb.Append(Char.ConvertFromUtf32 cp) |> ignore  // throws ArgumentOutOfRangeException

A source containing "\u{D800}" crashes the lexer with an unhandled exception inside lexStringLiteral, lexStringChunk, and lexTripleString. Fix: in the guard at line 451, reject 0xD800..=0xDFFF and emit L0022 instead of returning the codepoint.

### [HIGH] \u{ with 7+ hex digits emits a misleading L0021 unterminated unicode escape
compiler/src/Lyric.Lexer/Lexer.fs:442-448

The reader bails at sb.Length < 6, then checks peek == }. For "\u{0010000Z}" (7 chars before }), the loop stops at 6 chars, the next char is not }, and the diagnostic says "unterminated unicode escape" — but the escape is overlong, not unterminated. Fix: distinguish overlong vs unterminated by checking whether 6 digits were actually read; emit a dedicated message for overlong.

Related: an empty \u{} body bypasses the loop (peek is immediately }), then Int32.TryParse "" fails, emitting L0022 "must be 1-6 hex digits, <= U+10FFFF" — message is acceptable but the empty-body case is worth a dedicated diagnostic.

### [HIGH] L0010 integer literal out of range fires on malformed-suffix lexemes
compiler/src/Lyric.Lexer/Lexer.fs:382-412

When 100abc is lexed as a decimal, parseIntSuffix "100abc" returns ("100abc", NoIntSuffix) (no recognised suffix). UInt64.TryParse "100abc" fails, so the lexer emits L0010 "integer literal out of range" — but 100abc is not out of range, it is malformed. Misleading diagnostic. Same path in lexBasedInt (line 343). Fix: when suffixSb consumed non-alphanumeric leftover or when the suffix is unrecognised, emit a dedicated "invalid integer suffix" diagnostic with the offending tail.

### [MEDIUM] peek returns space past EOF instead of a sentinel
compiler/src/Lyric.Lexer/Lexer.fs:69, :73

    let private peek (st: State) : char =
        if isAtEnd st then space else st.Source.[st.Pos.Offset]

Returning a printable character past EOF is fragile — peek == space reads as space character everywhere, and a future caller relying on peek to decide between EOF and whitespace would see no difference. Fix: use 0 (NUL) or a separate peekOpt : State -> char option. Currently survives because every caller pairs peek with isAtEnd, but it is a footgun.

### [MEDIUM] Convert.ToUInt64 on hex literals throws OverflowException/FormatException for empty body
compiler/src/Lyric.Lexer/Lexer.fs:347-355

If the source is just 0x (no digits), body == "" after stripUnderscores, and Convert.ToUInt64("", 16) throws FormatException (not caught by the overflow guard, since the try ... with _ -> swallows it but reports the wrong error code). The bigger issue: the exception path emits L0010 (out of range) for the format-error case too. Recover with a body-empty check and emit L0011 (invalid integer literal) instead.

### [LOW] Identifier reservation rule _<UpperCase> is silently kept as ident
compiler/src/Lyric.Lexer/Lexer.fs:274-280

The lexer emits L0040 for reserved _Foo names but still emits a TIdent "_Foo" token. The parser then accepts it as a valid identifier. Downstream codegen could produce IL where user code clashes with compiler-generated names (_Async, _StateMachine). Either (a) replace the name with a recovery placeholder (e.g. __error_<n>) or (b) document that L0040 is purely advisory and acceptable.

### [NIT] lexBlockComment does not detect comment-in-comment of form // /*
compiler/src/Lyric.Lexer/Lexer.fs:237-253

A // /* */ line in source increments block-comment depth when nested inside another block comment (because the lexer only looks for /* characters and does not notice a line comment marker). Minor — block-and-line comments do not nest in idiomatic Lyric, but worth a test case.

---

## 2. F# vs self-hosted lexer divergence

### [CRITICAL] Self-hosted lexUnicodeEscape rejects all non-BMP scalars; F# accepts them
compiler/lyric/lyric/lexer.l:1656-1666 vs compiler/src/Lyric.Lexer/Lexer.fs:451

    if v < 0i64 or v > 65535i64 {
      recordError(state, L0022, non-BMP unicode escape (deferred to follow-up), ...)
      \u{FFFD}
    }

A program containing \u{1F600} parses cleanly with the F# bootstrap and fails L0022 under self-hosted. Three-stage bootstrap reproducibility (per scripts/bootstrap.sh) is broken for any source touching emoji or other astral-plane scalars. Self-hosted comment at lexer.l:25 flags this as deferred. Either upgrade the self-hosted decoder to UTF-16 surrogate pairs (matching Char.ConvertFromUtf32) or, until then, gate the F# lexer behind the same BMP-only restriction so the two stay aligned.

### [HIGH] Self-hosted longToInt(v) is O(n) — quadratic in literal value
compiler/lyric/lyric/lexer.l:1581-1592

    func longToInt(v: in Long): Int {
      var acc = 0
      var rem = v
      while rem > 0i64 {
        acc = acc + 1
        rem = rem - 1i64
      }
      acc
    }

Called once per character in lexUnicodeEscape and longToChar. Decoding \u{FFFF} runs 65535 iterations to widen a Long to Int. Any source with a flurry of high-codepoint escapes pushes the self-hosted lexer into the seconds-per-file range. Fix: expose a Long.toInt (or Std.Convert.longToInt) extern; the BCL has Convert.ToInt32(int64).

### [HIGH] Self-hosted longToChar truncates to ASCII (0..127)
compiler/lyric/lyric/lexer.l:1559-1579

Any escape \u{80}..\u{FFFF} decodes to U+FFFD silently. Combined with the non-BMP rejection above, the self-hosted lexer can faithfully decode only ASCII escapes. Fix: extern a Char.fromCodepoint(Int): Char builtin against the BCL (char)int.

### [MEDIUM] Self-hosted lexer captures leadingTrivia; F# bootstrap does not
compiler/lyric/lyric/lexer.l:125-141 (Trivia + SpannedToken) vs compiler/src/Lyric.Lexer/Lexer.fs (no Trivia type)

The self-hosted lexer maintains a red/green-style trivia run on each token; the F# lexer drops whitespace/comments entirely. As a result, anything routing through the F# lexer (today: every lyric build path that has not migrated to the self-hosted CLI) loses comment positions, and a future round-trip via lyric fmt that re-reads via the F# lexer would silently strip comments. The self-hosted CST in parser_cst.l depends on this trivia data; running the F# lexer through that CST would produce empty trivia lists for every token. Fix direction: either backport trivia capture to the F# lexer or document loudly that Lyric.Fmt and CST-consumers must route through the self-hosted lexer.

### [MEDIUM] Self-hosted TInt payload is Long (signed 64-bit); F# is uint64
compiler/lyric/lyric/lexer.l:292 vs compiler/src/Lyric.Parser/Ast.fs:70

    case TInt(value: Long, suffix: IntSuffix)

vs

    | LInt of value: uint64 * suffix: IntSuffix

The F# lexer can hold a literal in the range [0, UInt64.MaxValue]; the self-hosted lexer cannot represent any literal above Int64.MaxValue (9_223_372_036_854_775_807). Lyric source 0xFFFF_FFFF_FFFF_FFFFu64 lexes fine under F# and overflows under self-hosted. Fix: switch the self-hosted payload to ULong, or carry a sign-tagged representation.

### [LOW] Self-hosted statement-end tracker only carries prevSuppresses: Bool
compiler/lyric/lyric/lexer.l:551-557

The F# lexer carries the whole previous Token and re-runs suppressesNewlineAfter on it. The self-hosted lexer flattens this into a single boolean computed at emit time. Both approaches work for the current suppression set, but the bool-only form is fragile: any new token kind that needs context-dependent suppression (e.g. soft keywords that suppress only in certain positions) requires plumbing changes. Keep the boolean for performance but add a comment that the suppression table is authoritative.

---

## 3. Type checker

### [HIGH] Loose Type.equiv (TyError-vs-anything, TyVar-vs-anything) hides bugs
compiler/src/Lyric.TypeChecker/Type.fs:72-82

    let rec equiv (a: Type) (b: Type) : bool =
        match a, b with
        | TyError, _ | _, TyError                       -> true
        | TyVar _, _ | _, TyVar _                       -> true

This is admitted in the comment as a deliberate over-permissive equivalence — "the bootstrap does not do real unification". The cost: every subsequent type mismatch that flows through a TyVar or TyError silently typechecks. A genuine bug like val xs: List[Int] = newSet() (where newSet returns TyUser(SetId,[TyVar T])) would equate Int with T and pass. Note this is deliberate and gated to T6+ in the comment, but worth a T- follow-up issue with the explicit cases this currently masks.

### [MEDIUM] Match-expression result type uses first non-Never arm; no exhaustiveness check
compiler/src/Lyric.TypeChecker/ExprChecker.fs:686-715

EMatch checks arm-type compatibility but never verifies that the patterns cover the scrutinee. A match Option[Int] { case Some(x) -> x } (missing None) typechecks and would silently emit a runtime fault. There is also no diagnostic for redundant arms (case _ -> a; case _ -> b). The closest relative — ConstFold — handles cycle detection cleanly; the same rigour should land on patterns before v1.

### [MEDIUM] No exhaustiveness / coverage checking anywhere
Scanned compiler/src/Lyric.TypeChecker/*.fs for exhaust, coverage, missingCase, wildcard — only one match (PWildcard | PBinding(_, _) in the pattern-binding walk). For a safety-oriented language this is a glaring v1 gap. Verifier (Lyric.Verifier) does not do it either.

### [MEDIUM] POr pattern only walks first alt for bindings, never enforces alt-name agreement
compiler/src/Lyric.TypeChecker/ExprChecker.fs:398-409

    | POr alts ->
        match alts with
        | [] -> ()
        | first :: rest ->
            bindPattern table scope diags genericNames first ty
            for sp in rest do
                let dummy = Scope()
                bindPattern table dummy diags genericNames sp ty

A pattern case Some(x) | Some(y, z) -> binds x only; y and z go to a dummy scope and are silently dropped. The comment acknowledges this. Fix: diff first vs each rest scope and emit a T0xxx when names diverge or types disagree (akin to Rusts error[E0408]).

### [MEDIUM] EAssign checks rhs vs lhs type but never verifies lhs mutability
compiler/src/Lyric.TypeChecker/ExprChecker.fs:813-821

    | EAssign(target, _, value) ->
        let targetType = infer target
        let valueType  = infer value
        if not (Type.equiv targetType valueType) then
            err diags T0063 ...
        TyPrim PtUnit

Same in SAssign (line 915). A binding from LBVal (immutable) can be assigned to without diagnostic; the IsMutable flag on the Scope binding is set but never consulted in EAssign / SAssign. Fix: look up target.Kind root binding via scope.TryFind, and emit a T0064-class error when IsMutable is false.

### [MEDIUM] SItem _ (nested item declarations) silently dropped by type checker
compiler/src/Lyric.TypeChecker/ExprChecker.fs:992-994

    | SItem _ ->
        // Nested item declarations — deferred to T6+.
        ()

The grammar permits nested func / record / union declarations inside a block (see parseStatement -> SItem); they are syntactically parsed and then dropped. A user writing a nested func helper(): Int { ... } and calling it from the same block would get a T0020 "unknown name" on the call. Either reject nested items at parse time with a TODO error, or implement scope.

### [LOW] Cursor.peek past EOF returns a synthetic TEof with Position.initial span
compiler/src/Lyric.Parser/Cursor.fs:33-39

    let p = Position.initial   // 0:0
    { Token = TEof; Span = Span.pointAt p }

If a recovery path bottoms out and calls peek after the last buffered token, the synthetic tokens span points at the file head (0:0), not the source end. Any subsequent diagnostic anchored at that span would report errors at the wrong line. The lexer guarantees a trailing TEof so this is rarely exercised, but it is a footgun.

### [LOW] Type-as-expression special case (Type range ...).method(...) discards the refinement
compiler/src/Lyric.Parser/Parser.fs:566-591

The expression (Nat range 1 ..= 100).tryFrom(x) parses but the refinement (1..=100) is dropped — only the head Nat is kept as the EPath. Resolution of Nat.tryFrom(x) would not actually enforce the bound. Either feed the refinement through to the call site (so the emitter can pick the right narrowed dispatch target) or refuse the syntax with a clear error.

### [LOW] ConstFold cannot represent Long.MinValue
compiler/src/Lyric.TypeChecker/ConstFold.fs:52-61

ELiteral (LInt n) checks n > uint64 Int64.MaxValue. The literal 9_223_372_036_854_775_808u64 is required to negate into Int64.MinValue, but it gets rejected as Overflow before PreNeg can apply. Effect: type X = Long range Long.MinValue ..= Long.MaxValue cannot be written. Fix: parse PreNeg + literal as a unit and check the combined value, mirroring how C# / Rust handle the most-negative literal.

---

## 4. Contract elaborator gap

### [HIGH] Nested returns inside if / match / loop bodies are not elaborated
compiler/lyric/lyric/contract_elaborator/elaborator.l:511-537

The elaborators elaborateTopLevelStmt only rewrites SReturn and trailing SExpr at the top level of the function body block. A return inside a nested block:

    func clamp(x: Int): Int
      ensures: result >= 0 and result <= 100
    {
      if x < 0 { return 0 }      // <-- not elaborated; ensures not asserted
      if x > 100 { return 100 }  // <-- not elaborated; ensures not asserted
      x                           // <-- trailing; elaborated correctly
    }

The bootstrap emitter (per the elaborators preamble) still inserts runtime checks for these via the exit-label routing in Emitter.fs, so today the F# pipeline produces correct IL. But if anything downstream routes through the elaborator without also running the emitters exit-label rewriting (e.g. a future verifier feeding the elaborated AST to a different backend), it would silently skip the ensures check on the nested-return paths. Risk:

- Correctness today: depends on the runtime check happening in the emitter; if the self-hosted emitter (compiler/lyric/lyric/emitter.l) does NOT re-implement the exit-label routing, ensures checks vanish on the self-host path.
- Migration risk: high, because the elaborator silently produces an under-asserted AST.

Fix: extend elaborateTopLevelStmt to walk into if / match / try / loop bodies recursively, rewriting SReturn along every reachable path.

### [HIGH] Loop invariant: clauses left as-is; not emitted as runtime asserts
compiler/lyric/lyric/contract_elaborator/elaborator.l:39-42

    //   * Loop invariant: (SInvariant) — left as-is.  The verifier
    //     consumes it; the bootstrap emitter does not insert runtime
    //     checks for loop invariants, and neither does the elaborator.

Confirmed: SInvariant flows through unchanged. The bootstrap emitter (Emitter.fs:1839) explicitly says "Bootstrap-grade: invariants do not run yet". So a @runtime_checked module with while c { invariant: i >= 0; ... } silently skips the invariant at runtime. Documented gap, but a real safety hole. Decide whether @runtime_checked should imply loop-invariant runtime asserts; if yes, lower SInvariant to assert(...) at loop head + bottom.

### [HIGH] Protected-type entries (PMEntry) not elaborated for runtime checks
compiler/lyric/lyric/contract_elaborator/elaborator.l:43-47

    //   * Protected-type entries (PMEntry) — deferred to a follow-up
    //     stage.  Barrier (when:) checks and protected-type invariant:
    //     clauses are emitted by the bootstrap directly in IL; the
    //     self-host elaborator will lower them to assert statements once
    //     it picks up the protected-type lowering as well.

Same risk profile as nested returns: relies on the F# emitters direct IL emission. If the self-hosted emitter does not mirror that, protected-type contracts evaporate.

### [MEDIUM] appendEnsuresAssertsNoResult leaves leftover EResult references unsubstituted
compiler/lyric/lyric/contract_elaborator/elaborator.l:449-464

Comment: "ensures clauses on Unit-returning functions do not reference result (the type-checker already rejects that), so the leftover EResult is unreachable." But is the type-checker rejection actually enforced? Spot-check of typechecker_exprs.l and ExprChecker.fs — EResult simply returns TyError, no diagnostic is emitted for using result in a Unit function ensures. So the assumption is wrong. A program with func foo() ensures: result == 0 { ... } where return type is Unit would elaborate to assert(result == 0) with a dangling EResult that codegen treats as TyError. Fix: either emit a typechecker error (ensures: references result in Unit-returning function) or substitute EResult to a synthetic unit literal in the no-result path.

---

## 5. Monomorphizer (mono.l)

### [HIGH] Cannot infer type arguments from anything except literals and annotated locals
compiler/lyric/lyric/mono.l:359-404

inferExprTE handles only ELiteral, EParen, and single-segment EPath lookups against an env seeded with explicit annotations. Everything else — method calls, field projections, lambdas, constructor calls, binary ops — returns None. A perfectly normal call:

    val xs = newList()         // returns List[T] generically — no annotation
    process(xs.first())        // process: generic[T] func process(x: T) -> cannot infer T

falls back to "left un-specialised", which (per the comment at mono.l:32) means the call stays generic, which means the self-hosted PE emitter (per mono.l:5-7) cannot instantiate it, which (best case) means a runtime error or silent miscompile. Fix: at minimum pipe in the type checkers ResolvedSignature so inferExprTE can return the inferred type of a call expression by looking up the callees return type with current substitutions.

### [HIGH] Recursive generic instantiation does not propagate type args through type-app
compiler/lyric/lyric/mono.l:543-598

When rewriteExpr sees ECall, it queues a SpecRequest based on the calls positional argument type-unification. There is no handling of ETypeApp(fn, typeArgs) — the user-written mapFoo[Int, String](xs) form. ETypeApp is matched only at line 691-692 and merely forwards to rewriteExpr on the inner fn, dropping the type arg payload entirely. As a result, an explicit type application is never specialised through. Fix: when ECalls fn is ETypeApp(EPath p, targs), extract the targs directly into subst (skip unification) and pass through to the SpecRequest path.

### [HIGH] monoFile does not specialise generic methods on interfaces / impl blocks
compiler/lyric/lyric/mono.l:898-915

Phase 1 collects only top-level IFunc items with Some generics. Generic methods declared inside an impl T { ... } or interface I { ... } block are not in file.items — they live inside IImpl/IInterface payloads. Consequently, generic methods on a List[T] impl would never be specialised under the self-hosted path. The F# bootstrap monomorphises via the CLR runtime generics so this has not bitten yet, but the self-hosted emitter diverges. Fix: extend Phase 1 to walk IImpl.members and IInterface.members for generic IFuncs.

### [HIGH] No occurs check on substitution; nested-generic recursion can produce a fixpoint loop
compiler/lyric/lyric/mono.l:967-994

The worklist while wi < state.allSpecs.count advances index-by-index until no new requests are queued. Nothing detects mutual recursion of the form:

    generic[T] func foo(x: T): T { bar(x) }
    generic[T] func bar(x: T): T { foo(x) }

A call foo(1) queues foo_Int, whose body queues bar_Int, whose body queues foo_Int — but seenSpecs catches that. OK. The actual risk is when mangled names differ across recursive instantiations:

    generic[T] func wrap(x: T): List[T] { ... wrap(toList(x)) }

wrap_Int calls wrap_List_Int, which calls wrap_List_List_Int, etc. Nothing in mono.l bounds the worklist depth, and seenSpecs does not catch this because each name is genuinely fresh. Real-world Lyric stdlib probably avoids this shape today, but a malicious or just-clever input crashes the self-hosted compiler with stack exhaustion / OOM. Fix: bound the worklist depth or recursion budget (e.g. 64 levels) and emit a diagnostic on overflow.

### [MEDIUM] LBVar re-binding silently drops the new annotation
compiler/lyric/lyric/mono.l:808-820

    case LBVar(name, tyOpt, initOpt) -> {
      match tyOpt {
        case Some(te) -> {
          if env.containsKey(name) {
            // Last-write wins — Map.add would throw on duplicate; for simplicity
            // we leave the old binding in place (type env is best-effort).
            ()
          } else { env.add(name, te) }
        }
        ...
      }
    }

Re-declaring a var with a different annotation (shadowing, common in Lyric) leaves the env stuck on the first annotation. The next mono inference walks the new var with the wrong type, producing wrong specialisations. Fix: pop the old binding before adding the new one (or use a scoped Map with push/pop, mirroring Scope in F#).

### [LOW] extractBaseName only splits on the first __
compiler/lyric/lyric/mono.l:1045-1054

A generic function whose name happens to contain __ (e.g. user-named __lyric_helper) would have its base name truncated to the empty string. Realistic? No — but the L0040 reserved-name rule is not currently enforced as hard rejection, so a determined user could land here. Fix: skip leading _ runs before scanning, or unique the synthetic separator (e.g. 32757).

---

## 6. Emitter — async / FFI / state machines

### [HIGH] FFI receiver-vs-static disambiguation is ordering-dependent
compiler/src/Lyric.Emitter/Emitter.fs:2155-2268

The resolution cascade is:
1. static exact-typed
2. instance exact-typed
3. static arity-only
4. instance arity-only
5. static arity-only-with-defaults
6. instance arity-only-with-defaults
7. property getter
8. static field

The cascade comment correctly flags one bug (an exact instance match must beat arity-only static), but there are still subtle issues:

- A Lyric extern func foo(s: String): Int (arity 1, type [String]) on a type with both static foo(string) and instance foo() resolves to the static method (correct), but if both have arity 1 of compatible types and one is static, the static always wins. There is no way for the user to disambiguate to "I want the instance method".
- The with-defaults passes only kick in after exact-arity static/instance pairs fail. If a BCL method has defaults AND a sibling without defaults at the wrong arity, the wrong-arity sibling never lands but the defaults-pass candidate can match an unintended method. A Lyric-side annotation (@externStatic / @externInstance) would make resolution intent explicit.
- failwith is the failure mode (lines 2298, 2342, 2361, 2386, 2399, 2486) — the user gets an F# exception with no source location. Convert to Diagnostic.error F0xxx msg span and accumulate.

### [HIGH] FFI paramsExactMatch requires exact CLR type equality
compiler/src/Lyric.Emitter/Emitter.fs:2096-2105

    let private paramsExactMatch (m: MethodInfo) (expected: System.Type array) : bool =
        let p = m.GetParameters()
        if p.Length <> expected.Length then false
        else
            ...
            if ok && p.[i].ParameterType <> expected.[i] then
                ok <- false

System.Type equality is reference-identity-via-Equals; constructed generics (List<int> vs List<Int32>) compare equal, but co/contravariant assignability (e.g. IEnumerable<string> vs IList<string>) does not. The arity-only fallback is the workaround. Documented as bootstrap-grade by D035. Worth calling out in the language reference: BCL methods accepting interface types must be re-declared in Lyric with the exact interface CLR type.

### [HIGH] findClrType walks every loaded assembly on every FFI call
compiler/src/Lyric.Emitter/Emitter.fs:2042-2063

    System.AppDomain.CurrentDomain.GetAssemblies()
    |> Array.tryPick (fun asm -> ...)

No cache. findClrType is called once per @externTarget resolution; a stdlib with 280 extern declarations (stdlib/std/_kernel/*.l) does 280 full-AppDomain walks. Each walk is O(assemblies x types). On a cold lyric process with ~30 assemblies x ~10000 types each, that is ~84M comparisons per build. Add a Dictionary<string, System.Type> cache keyed on the qualified name.

### [HIGH] Async state machine Phase A falls back silently for byref params
compiler/src/Lyric.Emitter/AsyncStateMachine.fs:1077-1087, :1270-1273

If an async function takes inout / out parameters, the SM defines the field as the non-byref type and the fallback path activates via isPhaseAEligible = false. But the comment notes "the M1.4 stdlib + tests do not pass out/inout parameters to async funcs", which means this fallback is untested. A user writing such a function lands on the M1.4 blocking shim, which is a synchronous join — silent semantic divergence (the async function blocks instead of suspending). At minimum, surface a diagnostic when an async function with byref params is encountered.

### [MEDIUM] bodyContainsYield duplicated between TypeChecker and AsyncStateMachine
compiler/src/Lyric.TypeChecker/Checker.fs:357-411 vs compiler/src/Lyric.Emitter/AsyncStateMachine.fs:981-982

The TypeChecker explicitly says "Mirror of AsyncStateMachine.bodyContainsYield; kept here because Lyric.TypeChecker cannot depend on Lyric.Emitter." A future language-feature addition (e.g. yield inside try/catch, or in a new control construct) requires editing both files in lockstep. Risk: high — the duplication is 55 lines deep and walks an exhaustive match on ExprKind/StatementKind. Fix: factor into a shared Lyric.Parser.AstWalk module that both can depend on, OR move the predicate to Lyric.Parser itself (no emitter dependency needed).

### [MEDIUM] failwith peppered through codegen -> user sees raw F# exception
compiler/src/Lyric.Emitter/Emitter.fs:511, 613, 758, 986, 1195, 1202, 1221, 1229, 1235, 1249, 1255, 1261, 1275, 1462, 1466, 1781, 1827, 1831, 2016, 2298, 2342, 2361, 2386, 2399, 2486, 3014, 3015, 3027, 3226, 3235

30+ failwith* calls in Emitter.fs. Several would-be diagnostics escape as unhandled exceptions:

- failwithf "FFI: cannot resolve ..." — should be a diagnostic with the externTargets source span.
- failwith "objects no-arg ctor not found" — internal invariant violation, should be invalidOp (an internal-compiler-error path).
- failwithf "M2.2: nested toView for X not yet defined ..." — language feature limitation; should produce a structured diagnostic at the users source location, not crash the build.

Fix: route every user-facing failure through Diagnostic.error; reserve failwith for "this code path should be unreachable".

### [MEDIUM] AsyncStateMachine collectPromotableLocals does not recurse into try/catch
compiler/src/Lyric.Emitter/AsyncStateMachine.fs:1047-1065

The walker recurses into SWhile, SLoop, and (under hasAwaitInBlock) SFor. It does not recurse into STry bodies. A val foo = ... inside try { val foo = ...; await bar() } catch { ... } is not promoted and the local goes out of scope across the await suspend -> use-after-free shape. The allAwaitsSafe check probably blocks this from reaching the codegen path today, but the omission is a structural blind spot worth a defensive recurse + diagnostic.

---

## 7. SelfHosted*.fs reflection bridges

### [HIGH] Process-wide assembly-load leak (Assembly.LoadFrom) cannot be unloaded
compiler/src/Lyric.Cli/SelfHosted*.fs (every bridge)

Each tryRun / format / parseText call invokes preloadStdlibAssemblies(), which Assembly.LoadFroms every cached stdlib DLL into the default AppDomain. The default AppDomain cannot unload assemblies in .NET 5+, so the per-process working set grows monotonically as new stdlib DLLs are produced (e.g. after a feature flip changes the imported set). For a long-running lyric lsp daemon this is a real memory leak. Fix: load into a collectible AssemblyLoadContext (.NET Core 3+ supports isCollectible = true) and unload between sessions, or document that the bridge is single-shot.

### [HIGH] SelfHostedMsil.fs does not register ProcessExit cleanup for the scratch directory
compiler/src/Lyric.Cli/SelfHostedMsil.fs:48-54

Every other SelfHosted*.fs bridge does:

    AppDomain.CurrentDomain.ProcessExit.Add(fun _ ->
        try Directory.Delete(scratch, recursive = true) with _ -> ())

SelfHostedMsil skips this. Per-process scratch dirs accumulate in /tmp/lyric-msil-bridge-<pid> across CI runs. Fix: add the cleanup; better yet, factor a BridgeBoilerplate module that all SelfHosted*.fs files use.

### [HIGH] SelfHostedManifest.fs uses culture-sensitive String.StartsWith
compiler/src/Lyric.Cli/SelfHostedManifest.fs:130-153

    if line.StartsWith "pkg.name=" then pkgName <- line.Substring 9

The single-argument String.StartsWith(string) overload uses StringComparison.CurrentCulture by default. On locales where the Latin alphabet folds differently (Turkish i/I, Azerbaijani, etc.), characters match unexpectedly. The keys are ASCII and the protocol generator is also ASCII, so this is unlikely to bite today, but a build run on a fresh-locale CI runner could silently parse the wrong field. Same pattern in SelfHostedCli, SelfHostedFmt, SelfHostedJvm, etc. anywhere a substring/prefix check is done on bridge protocol text. Fix: pass StringComparison.Ordinal explicitly: line.StartsWith("pkg.name=", StringComparison.Ordinal).

### [HIGH] Bridge failure mode is silently fall back to F# dispatch
compiler/src/Lyric.Cli/SelfHostedCli.fs:120-127

    let tryRun (argv: string[]) : int option =
        try
            let fn = getDelegate ()
            Some (fn argv)
        with ex ->
            eprintfn "self-hosted CLI unavailable (%s); falling back to bootstrap"
                ex.Message
            None

Any exception inside the self-hosted CLI (parse error in user source, BCL exception during reflection, the users func main throwing) is swallowed by this catch and routed to the F# bootstrap. Two failure modes:

1. The users program throws -> caught here -> F# bootstrap reruns the same command from scratch -> user sees no useful diagnostic, just "self-hosted CLI unavailable: <message>" with the F# bootstraps interpretation of the command.
2. A genuine bug in Lyric.Cli.Program.main produces a wrong exit code -> caught here only if it throws, otherwise silently mismatched.

Fix: narrow the catch to load-time exceptions (FileNotFoundException, ReflectionTypeLoadException, MissingMethodException, etc.) and let runtime exceptions propagate so the user sees the real stack trace.

### [MEDIUM] Bridge cold-start cost (~3-5s per process) for every CLI invocation
compiler/src/Lyric.Cli/SelfHostedFmt.fs:31-37 (and every other bridge)

Comment: "The driver compile is the slow part (~3-5s on a cold cache); we only do it once per lyric invocation that touches the formatter." This is fine for one-shot CLI use but lethal for an LSP daemon, an editors format-on-save hook, or a CI step that runs lyric fmt --check over each file. Document the per-process cache, or hoist the bridge assemblies into the stdlibs pre-built cache directory so they are already on disk when the daemon starts.

### [MEDIUM] Bridge protocol parsers tolerate keys silently — typos pass as no-ops
compiler/src/Lyric.Cli/SelfHostedManifest.fs:129-153

If the self-hosted bridge introduces a new key (pkg.repository=), the F# parser silently ignores it. The reverse — F# parser expects a key the bridge has not emitted — surfaces as a missing/empty value. There is no protocol version handshake. Add version=1 as the second header line and refuse to parse mismatched versions.

### [MEDIUM] Reflection-based dispatch has no shape verification beyond method lookup
compiler/src/Lyric.Cli/SelfHostedManifest.fs:86-93

    match Option.ofObj (m.Invoke(null, [| box text; box filePath |])) with
    | Some o -> string o
    | None   -> "err\nunknown error"

If serializeManifest is renamed in the .l source, pickStatic throws an AmbiguousMatchException (overloads can collide). If the return type changes, string o silently formats whatever it gets. Add m.ReturnType = typeof<string> check and fail with a structured "ABI break" message.

---

## 8. Diagnostics quality

### [HIGH] No hint: / fix-it / did you mean? channel in the Diagnostic record
compiler/src/Lyric.Lexer/Diagnostics.fs:11-16

    type Diagnostic =
        { Severity: DiagnosticSeverity
          Code:     string
          Message:  string
          Span:     Span }

There is no slot for: secondary spans (related-info), a hint message, a suggested edit (fix-it), or a help URL. Modern compiler UX (rustc, swiftc, TypeScript) leans hard on these. For v1, extend the record:

    type Diagnostic =
        { Severity: DiagnosticSeverity
          Code:     string
          Message:  string
          Span:     Span
          Help:     string option
          Related:  (Span * string) list
          Fix:      TextEdit option }

Without this, the LSP cannot offer code actions for diagnostics — only the underlying squiggle.

### [MEDIUM] Diagnostic codes are inconsistent across passes
compiler/src/Lyric.TypeChecker/{Checker.fs, ExprChecker.fs}, compiler/src/Lyric.Cli/Program.fs

Codes seen: L0001-L0040 (lexer), P0010-P0256 (parser), T0001-T0096 (typechecker), G0009/G0013 (config blocks), F0003 (features), B0040/B0042 (build), S0001/S0002 (stability), V0001-V0011 (mode checker). The numbering scheme has gaps and overlap of prefixes between subsystems. A user looking up T0086 must guess that T = type-checker. Fix: maintain a flat registry doc (docs/diagnostics-registry.md) so every published code is reserved exactly once.

### [LOW] Many diagnostics include CLR-side types in user-facing messages
compiler/src/Lyric.TypeChecker/Type.fs:103-121

Type.render TyUser(TypeId 7, []) produces <#7> — a synthetic numeric id the user cannot map back to a source type. Rendering should track the declared name (the resolver already has it). Same with TyVar n rendering as the bare name without quoting (Foo looks like a known type to a user reading "got Foo, expected Foo").

---

## 9. Statement-end insertion (ASI-like) edge cases

### [MEDIUM] STMT_END is suppressed after KwIn / KwWhere, but match expression followed by newline-then-brace is ambiguous
compiler/src/Lyric.Lexer/Lexer.fs:144-151

    | KwAnd | KwOr | KwXor | KwNot | KwIs | KwAs
    | KwElse | KwThen | KwIn | KwWhere -> true

Inside for x in newline longExpression { ... }, the newline after in is correctly suppressed. Good. But for a match expression where the user writes:

    val foo = match x
    {
      case 0 -> "zero"
      ...
    }

The match x expression ends with an EPath token (x). The newline after x falls through to maybeEmitStmtEnd, which DOES emit STMT_END (since x is in the non-suppress set). Then { ... } parses as a fresh block. This is the dangling-braces ambiguity Go also has. Documented in the language ref? If not, document or warn.

### [MEDIUM] Semi always emits STMT_END regardless of suppression
compiler/src/Lyric.Lexer/Lexer.fs:720-726

    | Semi ->
        maybeEmitStmtEnd st
        st.Tokens.Add({ Token = TStmtEnd; Span = Span.make start st.Pos })
        st.PrevToken <- Some TStmtEnd

A ; after a binary operator (a + ;) gets a STMT_END right after the +, producing a parse error at the +, which is misleading. The semicolon "explicitly terminates" intent should probably be reported as a parser error on the +-as-prefix-of-statement-end pattern.

### [LOW] Self-hosted lyric/lexer.l reset of prevWasStmtEnd etc. is split across many functions
compiler/lyric/lyric/lexer.l:537-571

The mutable LexerState has 6 fields tracking STMT_END insertion. They are updated independently across emit, maybeEmitStmtEnd, and several lex helpers. A future contributor changing one path may forget to clear newlinePending or prevSuppresses. Factor: a Lexer.afterEmit(state, tok) helper that owns the bookkeeping. The F# version is tighter (the entire bookkeeping is in emit + maybeEmitStmtEnd).

---

## 10. Build / process-orchestration concerns

### [MEDIUM] internalBuild accepts --target jvm but defaults to Dotnet on unknown values
compiler/src/Lyric.Cli/Program.fs:2257-2259

    | "--target" :: _ :: tail ->
        target <- Emitter.Dotnet
        cursor <- tail

--target wasm silently selects Dotnet. Fix: emit a diagnostic on unknown targets and exit non-zero.

### [LOW] writeRuntimeConfig constructs runtimeconfig.json by string concat — drift risk
compiler/src/Lyric.Cli/Program.fs:96-117, compiler/src/Lyric.Cli/SelfHostedMsil.fs:135-152

Two implementations of the same JSON template. Either share a helper, or use System.Text.Json.JsonSerializer.

### [LOW] Program.fs env-var bootstrapping for LYRIC_BIN/LYRIC_CLI_DLL uses Diagnostics.Process.GetCurrentProcess().MainModule
compiler/src/Lyric.Cli/Program.fs:2360-2374

MainModule can be null when the process was started without symbolic info (some Linux/musl environments). The Option.ofObj guard handles it but Environment.ProcessPath (.NET 6+) is more reliable. Prefer that.

---

## 11. Positive observations

- The F# lexers interpolation handling (InString / InHole / bracket-depth unwind) is clean and the comments explain the invariants well (compiler/src/Lyric.Lexer/Lexer.fs:533-589).
- ConstFold.fs correctly tracks recursion to detect cycles, uses checked-arithmetic for overflow detection, and surfaces structured FoldError cases — a model for how other passes should report failures.
- Out-parameter definite-assignment analysis (daBlock/daStatement/daExpr in ExprChecker.fs:1077-1185) is a real CFA pass with set-intersection at branch merges — the kind of analysis the language needs more of.
- The contract elaborator (elaborator.l) preserves source spans through the rewrite (every synthetic assert(...) is anchored at the source clauses span). Diagnostics anchored on synthetic IL still point at the user clause.
- findClrType correctly force-touches well-known assemblies before walking the AppDomain, and the FFI resolvers preference for exact-typed instance match over arity-only static catches a real overload-resolution bug (Emitter.fs:2169-2175).
- The SelfHosted bridge pattern (driver source + reflect entry point + cache delegate) is consistent across bridges and well-documented in each files header comment. The architecture itself is sound; the issues above are implementation details.
- The self-hosted lexers parseDigits overflow guard (compiler/lyric/lyric/lexer.l:1296-1316) does early-exit via the limit / base precomputation — a textbook technique that avoids relying on a wrap-around overflow.

---

## Top-priority recommendations (ordered)

1. Fix the surrogate-range escape crash (Section 1 CRITICAL #1). Trivial 3-line fix that prevents a lexer crash.
2. Fix the self-hosted non-BMP escape gap (Section 2 CRITICAL #1). Reproducibility bootstrap is broken for any astral-plane source.
3. Add pattern exhaustiveness checking (Section 3 MEDIUM #2 + MEDIUM #3). For a safety-oriented language, match with missing case -> runtime fault is the biggest unmet safety promise.
4. Elaborate nested returns (Section 4 HIGH #1). Risk concentrates as the self-hosted emitter grows past the F# bootstrap; today the F# emitters exit-label routing masks the gap.
5. Convert FFI failwith to diagnostics (Section 6 HIGH #1, MEDIUM #2). Users currently see raw F# stack traces for FFI resolution failures.
6. Cache findClrType results (Section 6 HIGH #3). Trivial perf win on any stdlib build.
7. Extend the Diagnostic record with Help / Related / Fix (Section 8 HIGH). Blocks meaningful LSP code-actions.
8. Stabilise the SelfHosted bridge protocol with version + Ordinal StringComparison (Section 7 HIGH #3 + MEDIUM #1). Cheap insurance against locale-dependent CI failures.
