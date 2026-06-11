# 12 — Open work

Everything in Bands A–D and Tiers 1–5 of the previous version of this file
has shipped.  What remains is tracked here.

The phased plan in `docs/05-implementation-plan.md` is the strategic view.
**This file is the single source of truth for outstanding work.**
`docs/36-v1-roadmap.md` (§R1–R6 all complete) is superseded for tracking
purposes and retained as a historical reference only.  Technical per-gap
evidence lives in `docs/41-self-hosted-compiler-gap-analysis.md`.

_Last verified against source: **2026-06-10**._

---

## Tier 0 — self-hosted `--target dotnet` soundness & correctness floor (v1.0 blocker)

This is the top of the queue and the real remaining v1.0 work.  In priority
order:

1. **Front-end soundness (CRITICAL).** **Shipped:** gatekeeper flip done — single-file
   `lyric build` now aborts on type errors, matching the project path (C1,
   D-progress-438); match exhaustiveness for unions/enums/`Bool`/unbounded scalars
   (T0016, #1483 split 1); `EPropagate` (`?`) unwrap typing (#1483 split 2a);
   `EIndex` element typing (D-progress-407); `EIf`-branch unified typing
   (D-progress-414); `EMatch`-branch unified typing with per-arm pattern variable
   binding (D-progress-419); generic union-constructor typing (D-progress-418);
   generic return-type instantiation (D-progress-424); argument-type overload
   resolution (D-progress-421); `EBlock`/`EUnsafe`/`EResult` typing
   (D-progress-408); visibility enforcement (H14, #1484); opaque
   representation-hiding (C10, #1485); §5.2 parameter-mode pass for all packages
   (C13-front-end, #1487); impl-conformance start — missing-abstract-method and
   arity-mismatch errors, interface subtyping at argument positions (C11 PARTIAL,
   #1486); remaining `TyError` expression forms — `ELambda`, `ETypeApp`,
   `EForall`/`EExists`, `EAssign`, tuple-destructure sub-bindings, record-ctor
   argument checking (C2, #2939); full impl-conformance signature type matching
   (C11, #1486, #2939); `where T: Marker` bound satisfaction at call sites (H15,
   #2939); `alias X = Long` as a usable type (H16, #2939); numeric widening —
   `Int`/`Long` and `Float`/`Double` in arithmetic, comparisons, and argument
   positions (M6, #2939); default interface method (DIM) bodies lowered as
   concrete .NET DIM MethodDefs in the self-hosted MSIL emitter (C11 DONE,
   `lowerMInterface` + `lowerImplMethodMsil`). **Remaining:** none — Band 1 is
   complete.
2. **Backend correctness (CRITICAL). Shipped:** `?` (C3, #1475); `==`/`Map`-key
   structural equality (H1, #1480/#1837); `defer` (C7, #1477); all of #1481;
   try/catch-as-value-expression IL (#1823); capturing closures (H20, #1479
   v1+v2 — immutable by value into `object[]`, `var` by heap-cell reference,
   single-level incl. escaping); function-value invocation for zero-arg lambdas
   (#1877) and annotated/HOF-propagated param-using lambdas (#1939); M7 closed
   (loop invariants lowered by the elaborator; `SItem` never produced by the
   parser). **Remaining:** multi-level nested closure capture (nested lambda
   captures enclosing lambda's locals, #1479); lambdas in `@test_module` bodies
   (#1854, LOW). **Anything not yet correctly lowered must hard-error, never
   silently pass through.**
3. **Async tail (CRITICAL).** Async SM synthesis shipped (Epic #2070 Phases
   B.0–B.3 + spawn): `IAsyncStateMachine` / `AsyncTaskMethodBuilder` / `Task[T]`
   returns and `ESpawn` are implemented in `lyric-compiler/msil/` (verified by
   `async_sm_self_test.l`). Remaining correctness gaps:
   - `await` inside a `try` block emits invalid IL (#2725, open, recent).
   - Hardcoded `maxStack=8` risks `VerificationException` on complex methods
     (#2712).
   - Lazy `IAsyncEnumerable[T]` generator synthesis (C5, Phase 5, #1490).
   (docs/41 C4 Phase B done; C5 + #2725 + #2712 remain.)
4. **Feature completion (HIGH).** Cross-package user generic *types* (C8 —
   in-bundle MSIL records/unions done #2362/D-progress-453/455; cross-package
   reification and stdlib self-compile remain, #1496), protected-type locking
   (C12 — zero mutual exclusion emitted, #1499), `@projectable` twins (H2, #1500),
   range-subtype validation (H3, #1501), custom `@generate` wiring (H10, #1505),
   `old()`/quantifier lowering (H11, #1506), `config{}` lowering (M3, #1508),
   `@derive(Ord)`/union-enum derives (M4, #1507), user cross-package generic-fn
   mono (H6, #1498 — stdlib wired, user cross-package funcs not yet collected),
   wire `@provided`/`WMBind` + topo sort + cycle detection (H4, #1502 —
   **shipped** D-progress-494: `@provided` params lower as `ACC_PRIVATE+STATIC`
   fields bootstrapped from the `bootstrap()` method, `WMBind` lowers as a
   static field under the interface's simple name, Kahn's BFS topo sort emitted
   on both MSIL and JVM targets, cycle panics `W0001`; `WMScoped` scoped
   lifetime remains stubbed pending #2972),
   call-site named/default args (H5, #1503 — **shipped** D-progress-494:
   `reorderAndFillMsil`/`reorderAndFillJvmArgs` reorder named args and fill
   omitted defaulted params in codegen on both targets; self-hosted
   `Lyric.TypeChecker` T0042 check updated to allow omitted trailing defaulted
   params via `minRequired` count, so the type checker no longer rejects
   valid calls).
5. **F# elimination + AOT (HIGH).** AOT is now wired: `release.l` emits
   `<PublishAot>true</PublishAot>` and invokes `dotnet publish -p:PublishAot=true`
   for the `.lyric-release` target — a CI smoke test using this path is still
   needed. F# residue still load-bearing: close the `HttpClientHost` class-`val`
   `.cctor` gap (#1576), port `ProcessCapture` to async (#1489 tail), fix the
   migrate `Lyric.Session.Host` off F#
   (#1777). (docs/41 H12, H13 partial.)

---

## Band F — post-review follow-ups (resolved in D-progress-261)

All tractable items below have shipped.  None were blocking v1.0.

### F1. B128 self-test `/tmp` path is non-portable

`bootstrap/tests/Lyric.Emitter.Tests/JvmLoweringB128Test.fs:55` and
`lyric-compiler/jvm/self_test_b128.l:216,241` hardcode
`/tmp/lyric-jvm-b128/parse.jar`.  Fails on Windows CI runners and may
collide across parallel test runs.

**Fix:** Use `Path.GetTempPath()` + a per-test unique subdirectory on the
F# side; update the Lyric self-test to accept the path as a parameter.

### F2. `in List[T]` parameter mutation — spec clarification needed

`appendDiags(target: in List[LintDiag], ...)` in `lint.l` declares
`target` as `in` but calls `target.add(...)` which mutates the list content.
The spec does not clarify whether `in` means "reference-immutable" or
"content-immutable".  The self-hosted compiler uses reference-immutable
throughout.

**Fix:** Add a paragraph to `docs/01-language-reference.md` §4 (modes)
clarifying that `in` prohibits rebinding the parameter but does not prevent
mutation through a mutable container type.  Update the mode checker's V0001
diagnostic message to match.

### F3. `@externTarget` static-vs-instance naming convention — document in spec

`isStaticExternByName` in `lyric-compiler/jvm/codegen.l:1592-1602` detects
static vs instance calls by checking whether the Lyric function name starts
with a PascalCase prefix before `_`.  A hand-written extern that doesn't
follow this convention will be silently miscompiled.

**Fix:** Document the naming convention in `docs/01-language-reference.md`
§11.3 alongside `@externTarget`.  Long-term fix is an explicit `kind`
parameter on `@externTarget(...)`.

### F4. Lint bridge protocol breaks on multi-line diagnostic messages

`lyric-compiler/lyric/lint_bridge.l:29-30` serialises one diagnostic per
line using `'|'` fields and `'\n'` as the row separator.
`SelfHostedLint.fs:107-118` splits on `'\n'` and drops any line where
`parts.Length < 5`.  A lint rule emitting a `'\n'` in its message will have
the spillover line silently discarded.

**Fix:** Escape `'\n'` inside the message field as `\\n` before serialising
(option b); deserialise accordingly in the F# bridge.

### F5. Scratch directories under `Path.GetTempPath()` are never cleaned up

`SelfHostedDoc.fs`, `SelfHostedLint.fs`, `SelfHostedFmt.fs`,
`SelfHostedPack.fs`, `SelfHostedManifest.fs`, and `SelfHostedTestSynth.fs`
each create a `lyric-<feature>-bridge-<pid>` directory but never delete it.
For a long-lived process (e.g., the LSP server) this accumulates stale
directories across restarts.

Note: `SelfHostedCli.fs` already registers a `ProcessExit` handler for its
scratch directory — the pattern just needs to be applied to the other bridges.

**Fix:** Register a `System.AppDomain.CurrentDomain.ProcessExit` handler in
each bridge to delete its scratch directory on normal exit.

### F6. Pack XML generation — unit test coverage gap

`PackTests.fs` round-trips raw TOML through `SelfHostedPack`, giving
integration coverage but making it hard to isolate XML-generation bugs.
`Lyric.Doc` bridge has no F#-side unit test.

**Fix:** (a) Add a `pack_self_test.l` or direct-call test that exercises
`publishCsproj` with a known `Manifest` value and asserts specific XML
fragments.  (b) Add a `DocTests.fs` stub covering two or three fixture
inputs against known Markdown output.

### F7. GitHub Actions pinned by tag, not commit SHA (supply-chain hygiene)

`.github/workflows/publish.yml` uses floating tags for third-party actions:
`actions/checkout@v4`, `actions/setup-dotnet@v4`, `softprops/action-gh-release@v2`.
The publish workflow has `id-token: write` and access to signing secrets; a
tag hijack could exfiltrate them.

**Fix:** Pin each action to its commit SHA with the human-readable tag in a
comment.  Consider adding Dependabot or Renovate to automate SHA updates.

### F8. `lowerExternTargetBody` catches only `java/lang/Exception`, not `Error`

`lyric-compiler/jvm/codegen.l` emits catch blocks targeting
`java/lang/Exception`.  JVM `Error` subclasses (`OutOfMemoryError`,
`StackOverflowError`, `AssertionError`) are not subtypes of `Exception` and
will not be caught.

**Fix (v1.x):** Accept an optional exception-class parameter in
`@externTarget(...)` so callers can widen to `java/lang/Throwable` when
needed.  Track as a known limitation in `docs/18-jvm-emission.md`.

### F9. `findExternTarget` double-walks the annotation list

`lyric-compiler/jvm/codegen.l:1487-1510` walks `decl.annotations` twice:
once to find `@externTarget` and once to check `@noJvmBridge`.  Minor
optimisation opportunity; non-blocking.

**Fix:** Merge into a single pass or cache the result on `FunctionDecl` at
parse time.

### F10. Hand-rolled `joinStrs` / `typeArgsStr` helpers — stdlib enhancement

`doc.l` and `lint.l` each define local list-to-string join helpers.

**Fix:** Add `join(xs: in List[String], sep: in String): String` to
`lyric-stdlib/std/string.l` (kernel: `String.Join` BCL extern) and update
`doc.l`, `lint.l`, and any other callers.  Mark `@stable(since="1.0")`.

### F11. Test coverage gaps — Q021-4 Path 1.5 and Q022-1 pubUseDecls

Two code paths added in PR #291 have no dedicated regression tests:
- `satisfiesViaImportedDistinct` / Path 1.5 in `Codegen.fs:689-693`
- `pubUseDecls` in `ContractMeta.fs:432-456`

**Fix:** Add one test each in `Lyric.Emitter.Tests` or `Lyric.Cli.Tests`
exercising these paths end-to-end.

---

## Tier 6 — deferred, low priority

These items don't block v1.0 and will be pulled in as real programs
surface the need.

- **Regex RE2** (`Std.Regex`) — deferred until a Lyric program is exposed
  to attacker-controlled regex input that forces an upgrade off the BCL ECMA
  backtracker.
- **FFI score-based matching + special shapes** (C4 phases 2/3) — strict
  auto-FFI is shipped; score-based coercion, by-ref structs, `Span<T>`,
  `params T[]`, and extension methods land on demand.
- **CST type-expression multi-line layout** — the formatter defers
  multi-line layout inside type expressions (comments inside type
  annotations, multi-line generic argument lists).  Real programs haven't
  hit this yet.
- **`format7+`** — format arities beyond 6 wait for a varargs story or an
  explicit program need.
- **Async SM for generic impl methods** — `asyncSmEligible` gates on
  `sg.Generics.IsEmpty`.  The SM wiring is mechanical once generic impl
  methods are exercised with async; no program has needed it yet.
- **`Std.Core.Proof` structural-induction** — `List[T]` / `Result[T,E]`
  proof surface deferred to Phase 4 polish; gated on verifier structural-
  induction support past the M4.2-core primitives.

---

## Band E — long-horizon

- **JVM backend completion** (Phase 6+): JVM self-hosted emitter stages B127+,
  `LyricTestEngine` JUnit 5 adapter completion, Maven resolver polish.
- **ISO standardisation** (Phase 6+): language specification submission.
- **Distribution channels** (Phase 6+): AOT binary, standalone ZIP, signed
  installers per `docs/34-distribution-strategy.md`.

---

## Triage rule

When the type checker or emitter throws `failwithf` or produces invalid IL
on a program the language reference says should work, that is a Band A bug
regardless of where it sits in this list — it jumps the queue.
