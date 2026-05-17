# Phase 4 Verifier — Code Review Findings

**Reviewed:** `compiler/src/Lyric.Verifier/*.fs` (4400 LOC F# bootstrap), `compiler/lyric/lyric/verifier/*.l` (~4200 LOC self-hosted), `docs/15-phase-4-proof-plan.md`.

**Verdict: REQUEST CHANGES.** Two CRITICAL soundness bugs (silent capture in substitution; silent passthrough of unmodelled expression kinds in `translateExpr`) plus several HIGH-severity correctness gaps (mode-check holes for await/spawn inside try/while, protected-type invariant preservation never checked, cross-package callee call-graph rule unenforced, SMT-LIB float literal rendering broken). The proof checker silently accepts code it cannot model, which is the worst possible failure mode for a verifier.

---

## Missing features (the user's concrete question: async/yield/aspect support)

### [CRITICAL] `EAwait`/`EYield`/`ESpawn`/`EPropagate` silently fall through to passthrough in VCGen
- **F#:** `compiler/src/Lyric.Verifier/VCGen.fs:842-850` — the catch-all `| _ ->` arm in `translateExpr` covers every unmodelled expression kind, emitting `TVar("?expr", SUninterp "expr")` with only a V0024 *warning* (not an error).
- **Self-hosted:** `compiler/lyric/lyric/verifier/vcgen.l:731-739` — same shape.
- **Impact:** A `@proof_required` function whose body contains `await foo()`, `yield x`, `spawn task`, `value?` (propagate), `try expr`, etc. has its body silently coerced to an uninterpreted symbol. Because the `eval` post-substitution becomes `postcondition[result := ?expr]`, the *trivial discharger* will not close anything but the *user* may still see `0 counterexamples` if the mode-check holes (next finding) let those constructs through and the goal happens to be vacuous (e.g. a `requires: false` precondition).
- **Why the design doc doesn't excuse this:** §16 of `docs/15-phase-4-proof-plan.md` defers `await` to a *compile error* (`V0002`). It is *not* "silently produce a junk symbol". The verifier should fail loudly on every expression kind it cannot translate to a Term.
- **Fix:** Promote V0024 from warning to error, and enumerate every expression kind explicitly in the match — let the F# compiler's incomplete-match warning catch additions. List the truly unhandled kinds: `EAwait`, `EYield`, `ESpawn`, `EPropagate`, `EAssign`, `EIndex`, `ETypeApp`, `ELambda`, `EInterpolated`, `ETry`, `ERange`, `ETuple`, `EList`, `EError`, `ESelf`. Each should emit a distinct V-code so users can ack which feature is missing.

### [HIGH] Mode-check doesn't detect await/spawn inside try/while/for/loop/scope/defer
- **File:** `compiler/src/Lyric.Verifier/ModeCheck.fs:230-247`
- `checkFunction` only descends into `SExpr / SAssign / SReturn / SThrow / SLocal` statements; `STry`, `SDefer`, `SScope`, `SLoop`, `SWhile`, `SFor`, `SInvariant`, `SRule` are skipped at the top level.
- **Impact:** `func f(): Int { while true { await asyncCall() }; 0 }` does **not** trigger V0002. Combined with the previous finding, this means the proof verifier silently accepts code that calls `await`. Reproduces user's reported "proof checker not supporting async/yield".
- **Fix:** Replace the manual statement enumerator with a delegated full block-walker that just calls `visitBlock blk` (the inner helper in `collectCalls` already does this correctly — it's just not invoked at the top level).

### [HIGH] Aspect-elaborated functions are unsupported and undetected
- **Files:** verifier never inspects `Annotations` for `@aspect`-introduced wrappers (per `docs/26-aspects.md`); the AST shape the verifier walks is the parsed AST, not the post-aspect-elaboration AST.
- **Impact:** A function decorated with `@RequiresAuth`, `@Cached`, `@Retryable` etc. has the *underlying body* verified, not the elaborated body the runtime actually executes. Contracts on the wrapper (`requires: token.isValid`) are never discharged because the verifier doesn't see them.
- **Fix:** Either (a) run the verifier post-elaboration so the proven body matches the running body, or (b) audit each aspect template for proof-soundness and mark unsafe-when-proven aspects with `V0031`-style rejection.

### [HIGH] Function-level `IsAsync` flag is ignored in `goalsForFunction`
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:1466` — `entryToFn` sets `IsAsync = false`; nowhere else does the verifier read `fn.IsAsync`.
- **Impact:** `async func f(): Int ensures: result > 0 { ... }` produces VC obligations for `result > 0`, but the *actual* return is a `Task[Int]` whose unwrapped value isn't what `result` denotes. The encoding treats async like sync.
- **Fix:** Reject `IsAsync = true` in `goalsForFunction` with a clear `V0002`-style error (matching the §16 "async correctness — out of scope" decision), or specifically encode `result` as the awaited value with a documented unsoundness carve-out.

---

## Correctness bugs

### [CRITICAL] `Term.subst` is not capture-avoiding despite the docstring
- **F#:** `compiler/src/Lyric.Verifier/Vcir.fs:167-188` — comment says "Capture-avoiding substitution. Variable renaming on capture uses a numeric suffix" but no renaming happens. The implementation only removes bound names from the env (necessary but not sufficient).
- **Self-hosted:** `compiler/lyric/lyric/verifier/vcir.l:391-454` — identical bug, identical comment.
- **Demonstration:** Substituting `{x → y}` into `forall y. x > y` yields `forall y. y > y` (false), not `forall y'. y > y'` (preserved meaning). Triggers anytime a `@pure` callee body, contract substitution, or havoc renaming injects a name that shadows a quantifier binder.
- **Impact:** Unsoundness — a proof that "discharges" under capture can be false. Most likely to bite in `goalsForFunction` where `Term.subst (Map.ofList [("result", resultExpr)]) postTerm` (VCGen.fs:1366) substitutes into a contract that may quantify over `result`.
- **Fix:** When a binder name `n` is in the codomain free vars of the env, rename `n → n$<counter>` in `binders/triggers/body` before recursing.

### [HIGH] SMT-LIB Float literal rendering produces an Int when the value has no fractional part
- **F#:** `compiler/src/Lyric.Verifier/Smt.fs:46` — `| LFloat f -> sprintf "%s" (string f)`. `string 1.0` in F# produces `"1"`. SMT-LIB Real literals require a decimal point — Z3 will parse `1` as `Int` and emit a sort error on `(+ 1 r)` where `r : Real`.
- **Self-hosted:** `compiler/lyric/lyric/verifier/smt.l:80` — `doubleToString(f)` has the same hazard depending on the host extern.
- **Also:** `Double.NaN`, `Double.PositiveInfinity` are silently converted to `"NaN"` / `"Infinity"` — not valid in SMT Real theory. The verifier will report `unknown` with an opaque "Z3 returned unexpected output" rather than a useful diagnostic.
- **Fix:** Normalise to `"<int>.0"` for whole-valued doubles, format with `R` round-trip specifier (`f.ToString("R", CultureInfo.InvariantCulture)`), and reject NaN/Inf at VC-gen time with a documented `V0023`-style diagnostic.

### [HIGH] `goalsForProtectedType` never checks invariant preservation
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:1411-1496`
- The protected-type encoding adds the invariant as `CCRequires` (precondition) to each entry's synthesised `FunctionDecl`, but never as a `CCEnsures`. The header comment (lines 1411-1414) admits this and shifts the burden to the user: "Invariant PRESERVATION is checked via explicit `assert φ` statements in the entry body".
- **Impact:** A protected type whose entry mutates a field in a way that breaks the invariant verifies silently. The plan's §5.2 table promises "Invariant preservation checked via explicit `assert` in the body" — but no diagnostic warns the user if the explicit assert is missing.
- **Fix:** Either (a) inject the invariant as `CCEnsures` automatically (sound and complete for the std encoding), or (b) emit a `V0032`-style hint when an entry body lacks an `assert <inv>` at its tail.

### [HIGH] Cross-package callees bypass V0002 (only `imp.Contract.Level` is checked)
- **File:** `compiler/src/Lyric.Verifier/ModeCheck.fs:190-196`
- `onCall` only checks the local `callees` map; cross-package callees from `imports` are silently admitted with the comment "Without contract metadata we conservatively skip". But `Imports` *does* carry contract metadata (it's used in `checkImportLevels` for V0001 at line 463-493).
- **Impact:** A proof-required package imports an `@runtime_checked` package (caught by V0001), but if it imports an `@axiom` package, every non-`@pure` cross-package call still slips through V0002. The call rule in VCGen does work (`VCGen.fs:498-606`), so the obligation may still fail — but the user gets a confusing "your post doesn't follow from your pre" rather than "you called a non-pure non-proof-required callee".
- **Fix:** Look up the callee in `env.Imports` after the local table miss and check `dominates` on `ip.Contract.Level` (per-package level; per-decl level isn't tracked).

### [HIGH] V0001 import check is package-level only; per-callee `@axiom` overrides ignored
- **File:** `compiler/src/Lyric.Verifier/ModeCheck.fs:463-493` and `Imports.fs:122-128`
- `checkImportLevels` reads `ip.Contract.Level` (one level per imported package) and rejects when it's `RuntimeChecked`. But a `@runtime_checked` package may export individual `@axiom`-marked functions; the per-decl `@axiom` annotation lives in `ContractDecl` but the V0001 check never inspects it.
- **Impact:** False positives — proof-required code importing a runtime-checked package that exports *only* `@axiom`-marked symbols is rejected even though the call is sound.
- **Fix:** Either (a) only emit V0001 when the import path is *used* and the actual callee is non-axiom/non-pure, or (b) check the union of per-decl levels in the imported package.

### [MEDIUM] Local datatypes silently shadowed by imports
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:1513-1524`
- `Map.ofList (local @ importedTypes)` — when keys collide, the later occurrence wins. Imports come after locals, so an imported type with the same name shadows a local one.
- **Impact:** Confusing — user defines `record Money { amount: Int }` locally but imports a `Money` type from `Std.Money` and sees the field selector pointing at the wrong fields.
- **Fix:** Reverse order to `Map.ofList (importedTypes @ local)`, or emit a collision diagnostic.

### [MEDIUM] `parseModel` strips multi-line/nested-paren values incorrectly
- **F#:** `compiler/src/Lyric.Verifier/Solver.fs:38-78`
- The loop terminates the value at the first line ending with `)`, which fails for values like `(- 5)`, `(_ bv42 32)`, or any datatype value `(Account 100)`. The single-line `| [| name; "()"; sort |]` pattern (line 51) outright discards values that fit on one line in the form `(define-fun n () Int 5)` because no `_` for the value is matched there.
- **Self-hosted:** `compiler/lyric/lyric/verifier/solver.l:73-93` — same bug.
- **Impact:** Counterexample bindings for negative integers (rendered `(- 5)` by Z3), bitvectors, and datatypes get mangled or dropped. The user-facing counterexample report (which is the §9 deliverable highlighted as the day-one demo target) is unreliable for any value other than positive integers and booleans.
- **Fix:** Tokenise the model as an S-expression rather than a line-stripper; the recursive depth-counted reader in `readResponse` (Solver.fs:520-537) already shows the right approach for streaming — apply the same logic to model parsing.

### [MEDIUM] `Mode.fs` `Some other ->` arm produces unused-binding warning suppression that hides modifier typos
- **File:** `compiler/src/Lyric.Verifier/Mode.fs:110-112`
- The arm `| Some other -> ProofRequired` binds `other` but doesn't use it; the V0011 diag is computed separately at line 116-126. The level falls back to `ProofRequired` even for unknown modifiers, so a typo like `@proof_required(unsave_blocks_allowed)` ends up as plain ProofRequired but also fires V0011 — confusing because the file is processed as if the modifier were absent.
- **Fix:** Make the unknown-modifier case fatal (raise the level diag, return without computing further) instead of degrading silently.

### [MEDIUM] Goal cache invalidation misses `[verify]` block changes
- **File:** `compiler/src/Lyric.Verifier/Solver.fs:273-289` (hash inputs: Z3 version + SMT body)
- The plan §7.4 promises cache invalidation when `[verify]` timeout_ms/memory_mb changes, but the hash only includes the SMT body and Z3 version. Lowering the timeout doesn't re-discharge cached unknowns.
- **Fix:** Pass `[verify]` settings into `hashGoal` as part of the cache key salt.

### [LOW] `isWindows()` in self-hosted solver relies on Windows-only env var
- **File:** `compiler/lyric/lyric/verifier/solver.l:378-381`
- Checks `getEnv("OS")` for "windows" substring. OS is unset on macOS/Linux (correct fallback), but `$OS` is also a freely-settable env var; a user with `OS=Windows_NT` in their shell on Linux gets confused PATH separator behaviour.
- **Fix:** Add a host extern for `System.OperatingSystem.IsWindows()` or check `Path.DirectorySeparatorChar`.

---

## Code quality / pattern coverage in VCGen

### [HIGH] `translateExpr` lacks coverage of common expression kinds
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:157-850`
- Explicitly handled: `ELiteral`, `EParen`, `EPath`, `EResult`, `EOld`, `EIf`, `EPrefix`, `EBinop`, `ECall`, `EForall`, `EExists`, `EMember`, `EBlock`, `EUnsafe`, `EMatch`.
- **Not handled (falls through to `_` → `?expr` opaque):** `ETuple`, `EList`, `EIndex`, `EAssign` (an EXPRESSION, not statement; assignments-as-expressions exist), `EAwait`, `EYield`, `ESpawn`, `EPropagate`, `EInterpolated`, `ELambda`, `ERange`, `ETypeApp`, `ETry`, `ESelf`, `EError`.
- Tuples and lists in particular show up in trivial contract patterns like `ensures: result == (a, b)` and silently degrade.
- **Fix:** see CRITICAL above — make this an enumerated match.

### [MEDIUM] `wpBody` block walker misses `STry`, `SDefer`, `SScope`, `SThrow`, `SLoop`, `SFor`, `SBreak`, `SContinue`, `SRule`, `SItem`
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:927-1273` (`walk`)
- Handled: `SReturn(Some)`, `SReturn(None)`, `SExpr` (with `assert`, `unsafe`, generic call, `if` sub-cases), `SLocal`, `SAssign`, `SWhile`.
- All other statement kinds land in the `| st :: _ -> V0026 warning + Wp = trueT` arm. The wp is `true`, which doesn't constrain the postcondition — a goal `Pre ⇒ wp` becomes `Pre ⇒ true`, vacuously discharged. **Soundness hazard** for any function whose body uses `try` or `loop`.
- **Fix:** Either propagate sub-block wp through these constructs, or return `Wp = falseT` so the conclusion fails to discharge (signalling "we couldn't reason about this").

### [MEDIUM] `wpBody` setting `Wp = trueT` for unsupported statements is **unsound by default**
- Same lines as above. Wp of an unmodelled statement should be `falseT` (most-conservative — the verifier can't prove anything about this code), not `trueT` (verifier discharges the obligation vacuously).
- **Fix:** Change line 1273 from `Wp = Term.trueT` to `Wp = Term.falseT`, accompanied by the V0026 error so users get a clear "unverifiable code path" rather than a silent false-positive proof.

### [MEDIUM] `wpBody` ignores `SInvariant` outside loop heads
- Self-hosted `vcgen.l:1114-1117` skips `SInvariant` silently. F# version uses `partition isInvariant` only inside `SWhile` (`VCGen.fs:1166`). An `invariant:` clause in a non-loop position (a user error) is silently dropped instead of triggering a diagnostic.

### [MEDIUM] `goalsForProtectedType` doesn't pass the type fields' invariants into ensures
- Even ignoring the preservation gap (HIGH above), the verifier doesn't propagate the field invariant as a postcondition assumption to callers of the entry. A caller that reads the field after the entry returns has to re-derive the invariant.

### [LOW] `goalsForFunction` doesn't emit a separate `GKPrecondition` goal
- File: `compiler/src/Lyric.Verifier/VCGen.fs:1278-1403`
- Only emits `GKPostcondition` and side goals (`GKAssertion`, `GKLoopEstablish`, `GKLoopPreserve`). The `GoalKind` enum has `GKPrecondition` but it's never produced — only the call-site side-condition (`GKAssertion`) is used for pre-checks. Per the plan's §A.2 JSON schema, `kind` values include "precondition of <fn> at call site", which lands as `GKAssertion`. The enum value is dead.
- **Fix:** Either delete `GKPrecondition` or actually use it for call-site precondition goals (more informative).

### [LOW] `LBVar` without init binds to `SInt` by default — wrong for non-Int locals
- **File:** `compiler/src/Lyric.Verifier/VCGen.fs:1096-1100` and self-hosted `vcgen.l:1321-1326`
- An uninitialized `var x: Bool` is bound as a fresh `SInt` symbolic. The type annotation is dropped on the floor.
- **Fix:** Use the optional type annotation if present (`Param.Type` on the local).

### [NIT] `codepointToLong` in self-hosted `vcgen.l:163-179` is O(n) for what should be a cast
- A loop incrementing `acc: Long` `n` times to convert an `Int` codepoint to `Long`. For `\u{10FFFF}` (max BMP), this is a million-iteration loop per character literal.
- **Fix:** Add a `Std.Conv.intToLong` extern or use an existing kernel helper.

---

## Solver / Z3 shell-out

### [HIGH] No timeout/kill on `WaitForExit()` — relies entirely on solver self-timeout
- **File:** `compiler/src/Lyric.Verifier/Solver.fs:213, 411, 583`
- `proc.WaitForExit()` (no args) is unbounded. Z3 `-T:5` gives a 5-second per-`check-sat` timeout, but a misbehaving Z3 build (resource leak, deadlock in tactic) or a CVC5 invoked with an invalid flag combination can hang the verifier indefinitely.
- **Self-hosted:** `compiler/lyric/lyric/verifier/solver.l:301-316` — `runCapture` is a black box from this file's perspective; same hazard if the host extern doesn't enforce a wall-clock cap.
- **Fix:** `WaitForExit(timeoutMs)`; if it returns false, `Kill(entireProcessTree = true)`. Use 2× the solver-configured timeout as the wall-clock cap.

### [MEDIUM] `querySolverVersion` doesn't redirect stderr and has no timeout
- **File:** `compiler/src/Lyric.Verifier/Solver.fs:397-415`
- `z3 --version` prints to stdout — fine. But CVC5 prints to stdout *and* a copyright notice with version. A misconfigured `LYRIC_Z3=/bin/cat` makes this hang forever waiting for stdin.
- **Fix:** Add `psi.RedirectStandardError <- true`, add a 5s wait-for-exit timeout, kill on miss.

### [MEDIUM] `findBinary` doesn't check that the file is executable
- **File:** `compiler/src/Lyric.Verifier/Solver.fs:167-182`
- `File.Exists` returns true for any regular file — including a non-executable file named `z3` placed on PATH. The subsequent `Process.Start` will fail with a runtime exception.
- **Fix:** On Unix, check `File.GetUnixFileMode` includes user-execute; on Windows, check for `.exe` suffix explicitly.

### [MEDIUM] Solver session model-extraction loop can deadlock on a truncated process
- **File:** `compiler/src/Lyric.Verifier/Solver.fs:520-537`
- `readResponse` loops reading lines until balanced parens. If z3 dies mid-output (OOM, crash, signal), `ReadLine()` returns `null` (handled — `keepGoing <- false`), but `Counterexample (sb.ToString())` returns a partial model the parser will misinterpret.
- **Fix:** Track `depth` at loop exit; if `depth > 0` when `ReadLine` returns null, return `Unknown ("solver disconnected mid-response")`.

### [LOW] No prevention of injection via env-var-supplied binary path
- `LYRIC_Z3` is treated as a trusted path. A repo-local `lyric.toml` or CI env can substitute a malicious binary. This is mostly a "don't run `lyric prove` against untrusted code" caveat but should be documented.

---

## Counterexample / suggestion heuristics

### [MEDIUM] `suggestRequiresClauses` ignores opportunities beyond Int-at-boundary
- **File:** `compiler/src/Lyric.Verifier/Driver.fs:243-294`
- Only generates `requires: x > 0` for `x = 0` and `requires: x >= 0` for `x < 0`. Doesn't suggest:
  - `requires: x != 0` for division-by-zero counterexamples
  - `requires: xs.length > 0` for empty-slice counterexamples
  - `requires: x < N` for upper-bound violations
- The §9.3 list is described as "heuristic-driven; the heuristics evolve" — fine to start small, but the cap-at-three logic eliminates useful suggestions when many parameters are at boundary values.
- **Fix:** Expand the candidate set; suggest based on the *type* of the violated hypothesis, not just the bound value.

### [LOW] `buildCounterexampleTrace` uses unchecked Int64 arithmetic
- **File:** `compiler/src/Lyric.Verifier/Driver.fs:158-169`
- `x + y` for two int64s wraps on overflow. Z3 models can include very large integer values; an addition that wraps yields a misleading "trace" in the counterexample display.
- **Fix:** Detect overflow with `Math.AddChecked` (or wrap each op in try/catch); fall back to displaying the symbolic form rather than a wrong literal.

### [LOW] `eval` doesn't simplify `ite(true/false, …)` — partially handled at line 170-174 for `BOpImplies` only
- Counterexample traces involving conditional branches show unsimplified `if … then … else …` chains even when the model fully determines the branch.
- **Fix:** Add `TIte` simplification alongside `BOpImplies`.

---

## Self-hosted parity vs F# bootstrap

| Feature                              | F# bootstrap | Self-hosted | Severity |
|--------------------------------------|--------------|-------------|----------|
| Cross-package contract reading (`Imports.fs`) | yes  | **no** (driver doesn't take `imports`) | HIGH |
| Datatype encoding via `ProofMeta`    | yes (`registerDatatype`) | **no** (only opaque `$field.` selectors) | HIGH |
| Protected-type goal generation       | yes (`goalsForProtectedType`) | **no** | HIGH |
| `@proof_required(checked_arithmetic)` overflow VCs | yes | **partial** (skeleton only — vcgen.l:378-393 emits min/max bounds, but tested?) | MEDIUM |
| Persistent z3 session + content-hashed cache | yes (`SolverSession`) | **no** (one subprocess per goal) | MEDIUM |
| Trace reconstruction in counterexample (`buildCounterexampleTrace`) | yes | **no** | MEDIUM |
| `suggestRequiresClauses` heuristics  | yes | **no** | MEDIUM |
| Float-division uses `BOpRealDiv`     | yes | yes | OK |
| Symbol collision renaming (`$p` suffix in Smt.fs:217-232) | yes | **no** (collectFreeVars even ignores binder scopes) | HIGH |
| `--allow-unverified` flag plumbing   | yes (`ProveOptions.AllowUnverified`) | yes (param) | OK |
| SMT preamble / push-pop sessions     | yes | **no** | MEDIUM |
| Capture-avoiding subst               | broken | broken | (already CRITICAL) |

The self-hosted version is M4.1-only in practice. The progress log (D-progress-234) accurately describes it as "simplified", but the gap to the F# bootstrap is wider than the docstring suggests, and the bootstrap-progress table calling it "Shipped" overstates parity.

### [HIGH] Self-hosted `collectFreeVars` doesn't track quantifier binders
- **File:** `compiler/lyric/lyric/verifier/smt.l:164-228`
- The comment at line 162-163 says "does not track quantifier binders — the extra declare-consts are harmless since quantifier variables shadow them within their scope". This is wrong if the same name appears both as a quantifier binder AND as a hypothesis free variable in the same goal — the `declare-const` emission gives the global one a sort, and the quantifier shadowing changes that sort within its scope. Result: ambiguous sort errors or silently wrong proofs.
- **Fix:** Track bound names during traversal; only emit a `declare-const` for variables that are free in the *goal* (not shadowed at every use site).

### [MEDIUM] Self-hosted driver collects no `--allow-unverified` CLI parameter
- `compiler/lyric/lyric/verifier/driver.l:151` exposes `proveSourceWithOptions(source, allowUnverified)`, but the `Lyric.Cli` CLI dispatcher (`compiler/lyric/lyric/cli.l`) needs to be checked for whether it threads through. (Out of scope for this review — flagging for follow-up.)

---

## Security

### [MEDIUM] SMT output sanitisation only escapes alphanumerics/dot/underscore — Unicode identifiers may corrupt SMT syntax
- **File:** `compiler/src/Lyric.Verifier/Smt.fs:31-38` and `compiler/lyric/lyric/verifier/smt.l:46-63`
- The Lyric lexer accepts UAX #31 XID_Start/Continue identifiers (CLAUDE.md describes NFC-normalised identifier support). `sanitizeIdent` replaces non-ASCII identifiers with underscores — `λ` and `Λ` both become `_`, causing silent name collisions in the SMT output.
- **Fix:** Use a content-derived suffix when transliterating (e.g. `_xNNNN_` for codepoint), or pipe identifiers through quoted SMT-LIB symbols (`|…|` form).

### [LOW] No guard against malicious `lyric-contract` resources during import
- **File:** `compiler/src/Lyric.Verifier/Imports.fs:51-65` → `ContractMeta.parseFromJson`
- A malicious or corrupted `.lyric-contract` JSON could embed arbitrary contract strings that the verifier then re-parses as Lyric expressions (`parseClause` at VCGen.fs:566-572). Parser issues could be exploited (DoS via stack depth, slow patterns). Treat imported contracts as untrusted input.
- **Fix:** Add a parse-depth / parse-size guard for cross-package contract strings, separate from in-source parsing limits.

---

## Performance

### [MEDIUM] `Term.subst` recurses with `List.map` + `List.fold` — O(n²) on deep substitution maps
- **File:** `compiler/src/Lyric.Verifier/Vcir.fs:178-188`
- Each `TLet`/`TForall`/`TExists` does `binders |> List.fold (fun acc (n, _) -> Map.remove n acc) env` — fine for small binders, but the env grows linearly with hypotheses, and `Map.remove` is O(log n). The deeper concern is `TBuiltin(op, args |> List.map (subst env))` which does `args.Length` recursive calls each rebuilding the same env.
- **Fix:** Memoise via a mutable cache keyed on `(term-identity, env-identity)`, or thread the substitution as an immutable map without copy.

### [MEDIUM] Self-hosted `envBind`/`envBindTerm` copies the entire vars/sorts map on every binding
- **File:** `compiler/lyric/lyric/verifier/vcgen.l:76-107`
- For every let/var/match-binding/forall-binder, a new map is constructed by walking `varNames` and copying both maps. A function body with N statements gets O(N²) map-copy cost.
- **Fix:** Use a persistent map (the comment about TypeBuilderInstantiation suggests there's an IL bug in the bootstrap emitter; if so, fix the emitter rather than working around it with whole-map copies).

### [NIT] `codepointToLong` (already noted) — loops to convert Int → Long.

---

## Documentation / spec gaps

### [LOW] Plan §16 claims "Self-hosting the verifier" is out of scope, but D-progress-234 ships exactly that
- The doc and the progress log disagree. Either update §16 to say "Phase 5 ships a self-hosted port at parity-M4.1", or revert the self-hosted code.

### [LOW] §A.2 JSON schema mandates `kind` strings but the F# emitter doesn't enforce the closed set
- The `GoalKind.display` strings are free-form; an editor extension consuming the JSON has no validation that the kind matches one of the documented values. Reference: `Vcir.fs:203-215`.
- **Fix:** Add a unit test that asserts every `GoalKind` constructor maps to one of §A.2's listed strings.

---

## Positive observations

- The IR / solver decoupling (Vcir.fs ↔ Smt.fs ↔ Solver.fs) is clean and matches the design doc's §6 promise. Swapping in CVC5 is genuinely a few hundred lines (already done in `SolverFlavor`).
- The persistent-session + cache plumbing (`SolverSession` in Solver.fs:417-621) is well-structured; the `Dirty` flag prevents unnecessary cache writes.
- The trivial discharger (`Solver.fs:120-164`) is sound by construction — it only closes structurally tautological shapes, never user terms.
- Loop encoding implements the establish/preserve/conclude trio per §5.3 with separate diagnostics — correct shape and matches the spec.
- Cross-package `@pure` body serialisation + unfold at call sites (`VCGen.fs:592-602`) is the right approach and matches §5.5.
- The Driver's `withSession` higher-order wrapper (`Solver.fs:592-621`) cleanly hides solver discovery, fallback, and teardown from the caller.
- Test coverage (RegressionTests, DriverTests, SmtTests, SolverTests, ModeCheckTests, etc.) is genuinely broad — 266 passing per D-progress-129.
- The `--allow-unverified` UX correctly distinguishes V0007 (unknown) from V0008 (counterexample), matching §A.5's exit-code contract.

---

## Recommended actions in priority order

1. **Stop the CRITICAL bleeders:** fix `Term.subst` capture (Vcir.fs:169 + vcir.l:391), and promote V0024 (unmodelled expression) from warning to error (VCGen.fs:846-850 + vcgen.l:733-735).
2. **Fix mode-check holes:** ModeCheck.fs:233-245 — descend into every statement kind (delegate to a complete block walker).
3. **Fix protected-type preservation gap:** VCGen.fs:1411-1496 — inject invariant as ensures, or emit V0032 hint when missing.
4. **Fix SMT-LIB float rendering:** Smt.fs:46 — round-trip format + reject NaN/Inf.
5. **Add solver wall-clock timeout:** Solver.fs:213 — `WaitForExit(2 * configuredTimeout)` + `Kill`.
6. **Audit cross-package call rule:** wire `imports` into `ModeCheck.checkFunction`'s `onCall` (ModeCheck.fs:190-207).
7. **Self-hosted parity:** import the bootstrap's symbol-renaming, datatype encoding, and binder-tracking from F# Smt.fs into smt.l + vcgen.l.
8. Document the "no async, no aspects, no tuples/lists/lambdas in proof-required contracts" limitations explicitly in `docs/15-phase-4-proof-plan.md` until VCGen covers them.
