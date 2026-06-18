# Tier 6 — Aspect System Completeness

## Issues
- **#683** — Aspects: wire `config {}` block values into weave sites
- **#682** — Aspects: inject `call` context value inside `around` bodies
- **#681** — Aspects: implement `@inline_template` C-mode body re-compilation

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else, then read `docs/26-aspects.md` and `docs/27-aspect-libraries.md` completely. These are the authoritative specs for the aspect system.

Your task is to implement three missing aspect features. Work on a new branch named `feat/tier6-aspect-system`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

**Critical constraint:** All implementation goes in `lyric-compiler/lyric/weaver/weaver.l` (and companion files in that directory if needed). Do NOT touch `bootstrap/src/Lyric.Emitter/Weaver.fs` under any circumstances — it is on the deletion schedule (Band 7, #859). The self-hosted weaver is the source of truth. If the F# bootstrap weaver does not exercise a new feature, that is acceptable; the self-hosted path must be correct.

---

### #683 — Wire `config {}` block values into weave sites

The `config { }` block inside an aspect declaration parses and is stored in `AspectDecl.config`, but `weaver.l` does not read or inject the config values at weave time. Fields declared in `config {}` (e.g. `config { enabled: Bool = true; thresholdMs: Int = 100 }`) are inaccessible from within the `around` body — they neither compile nor resolve.

**Spec reference:** `docs/26-aspects.md` §config

**Implementation in `weaver.l`:**

1. At weave time, read `AspectDecl.config` from the matched aspect declaration.
2. For each config field, emit a synthetic `val __aspect_cfg_<fieldName> = <defaultValue>` local at the top of the woven `around` body, before any user code.
3. Ensure the type-checker sees these locals as the declared types (Bool, Int, String, etc.) so references like `if __aspect_cfg_enabled { ... }` or simply `enabled` (if the config fields are brought into scope) type-check correctly.
4. Config values are compile-time constants (the default values from the `config {}` block). Override at weave-site is a follow-up; for now, only the defaults are used.

**Tests:** Add a self-test aspect in `lyric-compiler/lyric/weaver/` (or the broader self-test suite) that:
- Declares an aspect with `config { maxRetries: Int = 3; logPrefix: String = "aspect" }`
- Uses those fields in the `around` body
- Verifies the woven output contains the synthetic locals with the correct default values
- Verifies the woven program compiles and runs correctly

---

### #682 — Inject `call` context value inside `around` bodies

The spec defines an ambient `call` value available inside `around(call) -> ret { ... }` bodies. Currently `weaver.l` only substitutes `proceed(args)` calls. References to `call.*` fail to compile.

**Spec reference:** `docs/26-aspects.md` §4

**Fields to inject:**
- `call.shortName: String` — matched function's unqualified name (known at weave time)
- `call.qualifiedName: String` — fully qualified name including package (known at weave time)
- `call.modulePath: String` — source file path (known at weave time from the `IFunc` span)
- `call.annotations: slice[String]` — annotations on the matched function (known at weave time)
- `call.elapsed: Option[Duration]` — time elapsed after `proceed` returns (must be injected dynamically: capture timestamp before `proceed`, capture again after, compute difference)
- `call.sourceLocation: String` — `"<file>:<line>"` of the call site (known at weave time)

**Implementation in `weaver.l`:**

1. Declare an internal `__AspectCallContext` record type in `weaver.l` (not in the public stdlib — this is a compiler-internal synthetic type):
   ```
   record __AspectCallContext {
     shortName: String
     qualifiedName: String
     modulePath: String
     annotations: slice[String]
     elapsed: Option[Duration]
     sourceLocation: String
   }
   ```
2. Before the woven body, inject:
   ```
   val __lyric_call_start = Std.Time.now()
   val call = __AspectCallContext(
     shortName = "<name>",
     qualifiedName = "<pkg>.<name>",
     ...
     elapsed = None
   )
   ```
3. After `proceed` returns, inject:
   ```
   val __lyric_call_elapsed = Std.Time.elapsed(__lyric_call_start)
   val call = __AspectCallContext(..., elapsed = Some(__lyric_call_elapsed))
   ```
   (or update the `elapsed` field if records support mutation, or use a separate local)
4. All string values for `shortName`, `qualifiedName`, `modulePath`, `annotations`, and `sourceLocation` are compile-time string literals derived from the matched `IFunc` item — they are embedded as constants in the woven body.

**Tests:** Add a self-test that:
- Declares an aspect that logs `call.qualifiedName` and `call.elapsed`
- Weaves it onto a target function
- Verifies `call.qualifiedName` is the expected string
- Verifies `call.elapsed` is `Some(...)` after `proceed` returns (positive duration)
- Verifies the woven program compiles and runs without errors

---

### #681 — `@inline_template` C-mode aspect body re-compilation

`@inline_template` on a `pub aspect` is specified as marking the aspect as a C-mode template: the `around` body is re-compiled in the consumer package's context so it can reference named `args` fields (the matched function's parameters by name).

Currently the annotation parses but has no effect. The linter emits `L006` ("@inline_template has no effect: C-mode aspect inlining is not yet implemented").

**Spec reference:** `docs/26-aspects.md` §C-mode, `docs/27-aspect-libraries.md`

**Implementation in `weaver.l`:**

1. When weaving an aspect marked `@inline_template`, instead of inlining the pre-compiled aspect body, re-parse and re-type-check the aspect's `around` body source text in the consumer package's context.
2. In the re-compiled body, `args` resolves to a synthetic record whose fields are the matched function's named parameters. For example, if the matched function is `func transfer(amount: Decimal, from: Account, to: Account)`, then `args.amount`, `args.from`, `args.to` resolve to the actual parameter values.
3. The re-compilation must fail with a clear diagnostic if the aspect body references `args.<field>` that does not exist on the matched function's parameter list.
4. Remove the `L006` linter warning once the feature is implemented.

**Tests:** Add a self-test that:
- Defines an `@inline_template pub aspect` that references `args.amount`
- Weaves it onto a function with an `amount: Decimal` parameter
- Verifies `args.amount` resolves to the actual argument value at runtime
- Attempts to weave the same aspect onto a function without an `amount` parameter and verifies a compile-time diagnostic is emitted (not a runtime error)

---

## Acceptance Criteria

- [ ] `config {}` fields are available as typed locals in woven `around` bodies
- [ ] Aspect with `config { maxRetries: Int = 3 }` compiles; `maxRetries` usable in body
- [ ] `call.shortName`, `call.qualifiedName`, `call.modulePath`, `call.annotations`, `call.sourceLocation` are correct compile-time constants in woven bodies
- [ ] `call.elapsed` is `Some(duration)` after `proceed` returns; `None` before
- [ ] `@inline_template` aspect body re-compiled in consumer context; `args.<param>` resolves correctly
- [ ] Weaving `@inline_template` onto function missing a referenced `args.<field>` emits a compile-time diagnostic
- [ ] `L006` linter warning removed once `@inline_template` is implemented
- [ ] Self-tests for all three features pass via `lyric-compiler/lyric/*_self_test.l`
- [ ] `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes (self-hosted weaver tests)
- [ ] `dotnet run --project bootstrap/tests/Lyric.Cli.Tests` passes
- [ ] Weaver.fs is NOT modified; all changes in `weaver.l` and companion `.l` files
- [ ] No new F# domain logic anywhere
- [ ] No disabled or skipped tests
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
