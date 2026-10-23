# 12 — Open work

The phased plan in `docs/05-implementation-plan.md` is the strategic view.
**This file is the single source of truth for outstanding work.**  It was
rewritten on 2026-10-21 after an audit of every planning doc against the
progress log (`docs/progress/`, 313 entries), the decision log
(`docs/decisions/`, D001-D200) and the issue tracker (379 open issues, most
carrying a `group:*` label).  The previous version was stamped 2026-06-12 and
had drifted four months.

Related status docs, each now carrying its own current-status header:
`docs/36-v1-roadmap.md` (v1.0 gates), `docs/41-self-hosted-compiler-gap-analysis.md`
(dotnet audit, historical), `docs/44-jvm-production-readiness-plan.md` (JVM),
`docs/57-stdlib-ecosystem-library-review.md`, `docs/59-compiler-stdlib-deep-review.md`,
`docs/67-native-graphics-plan.md`, `docs/68-structured-tasks-sketch.md`.

_Last verified against source and tracker: **2026-10-21**._

---

## What has shipped (do not re-plan)

- **Self-hosted compiler soundness floor (old Tier 0).** Front-end soundness,
  backend correctness (`?`, `==`, `defer`, closures including multi-level
  capture), async state machines, feature completion (cross-package generics,
  protected types, projectable twins, range subtypes, wire, config, derives)
  and F# elimination are all done.  Single-file and project builds abort on
  type errors on dotnet and JVM.  Stage-2/stage-3 fixpoint holds (D-progress-531).
  No `.fs`/`.fsproj` file remains in the repository.
- **Native (LLVM) backend.** N0-N8 and N9 (HTTP/TLS) shipped in substance:
  ARC, records/unions, closures, generics, interfaces, protected types,
  async/spawn/scope, FFI and callbacks, stdlib kernel twins, project
  dependencies, `[native]` manifest table.  See `native/plan/08-work-items.md`.
- **wasm32 and npm (docs/35, W0-W5 and the #8117/#8118 follow-ups).**  Module
  and component shapes, `[wasm]`/`[npm]`, shim generation, component async
  (D184).
- **Language additions.** 32-bit `Float` on every backend, by-value records
  and inline unions on native, `array[N, T]`, `buffer[T]` and the `Plain`
  marker, `foreign record`, `@userdata` callbacks, unsigned arithmetic,
  checked integer conversions, out/inout by reference (D183), generator
  `for`, `spawn` only inside `scope` (V0034, D165), built-in `Task[T]` (D166),
  enforced `[layers]`, custom `@generate` source generators, C bindings on
  every target.
- **Libraries.** `lyric-ui` U1-U5, `lyric-window`, `lyric-gpu`, `lyric-text`,
  `lyric-draw`, `Std.Linalg`, `Std.JsonValue`, JSON-RPC/MCP stateless core,
  `lyric bindgen`.
- **Band F follow-ups (old F1-F11).** F2, F3, F7, F10 shipped; F4, F5, F6, F9,
  F11 are obsolete (the F# bridges and `Codegen.fs` they referenced are gone).
  F1 and F8 remain open (below).

---

## Triage rule

A program the language reference says should work that produces invalid IL,
a verifier-rejected class, a type-checker ICE, or a silently wrong result is a
Tier 1 bug regardless of where it sits in this list.  It jumps the queue.
Anything not yet correctly lowered must hard-error, never silently pass through.

---

## Tier 1 — silent miscompiles and unsoundness (fix first)

Issue clusters, by `group:*` label.  Counts are open issues as of 2026-10-21.

1. **Generics at codegen (`compiler-mono-codegen`, 12).**  The largest single
   source of cross-target failures: generic call at `T = Unit` (#8236),
   Unit-typed parameters (#8266), generic member calling a generic free
   function with the type's own `T` (#8271, #8370), method-level generics on
   record methods (#8241), `?` inside a restored generic function (#8337),
   open type argument fixed only by a pattern binding (#8250), enclosing type
   parameter as explicit type argument (#8280, #8282).
2. **Async and inout (`async-concurrency` 8, `inout-out-params` 10).**  An async
   function's inout write is silently lost on dotnet (#8229, #8318); aspect-woven
   async returns garbage on dotnet (#8287); `ldloca.s` slot >= 256 corrupts
   memory in async (#7822); async call result stored as raw `Task` (#7196);
   captured `var` passed as inout still copies in three shapes (#8204); JVM
   `async_sm_self_test.l` fails verification (#8294); `Std.Task.Scope` spawn
   (#5329, verify stale); flaky native task race (#8259, #8367).
3. **Invalid IL where a diagnostic is owed (`msil-codegen` 6).**  `+` on object
   operands lowered as numeric add (#8344), overload chosen through default
   arguments (#8355), `Option[Int]` parameter match panics on `None` (#8273),
   `Self` spelling in impl (#8313), `Result == Ok(..)` literal false (#8144),
   Unit function values `Func` vs `Action` (#7219), module-val shadowing shifts
   MethodDef tokens (#7963).
4. **Type-checker and mode-checker gaps (`typechecker-diagnostics` 5,
   `compiler-frontend-resolution` 5, `contracts-invariants` 2).**
   `List`/`Map` method arguments unchecked (#7683, with #7978, #7786, #8104,
   #8161), writes through an `in` parameter not rejected (#8289), `?` on a
   non-Result/Option (#8249), interface method contracts never type-checked
   (#8331), record invariant never enforced (#7222, epic #7221), unknown
   methods on primitives accepted (#8334).
5. **Verifier soundness (`verifier` 7 plus an unlabelled family).**  Match arm
   guards ignored (#8142), `sortEq` ignores datatype arguments (#8354), no
   bounds obligation on index (#8157), no array/slice/buffer model (#8394),
   sibling-file record fields (#8306), Float as Real (#8141), no heap model
   (#8110).  The verifier must fail closed; these are the unsound ones.
6. **Silent build-system behaviour (`build-system-toolchain` 10).**  JVM project
   builds skip unreachable packages so type errors are lost (#8357),
   `--features` ignores undeclared features (#8362), CLI ignores unknown flags
   (#8321), `prove --target jvm/native` uses the MSIL front end (#8311),
   `prove` and build disagree on package files (#8245).
7. **Security-labelled issues** (#7253, #7249, #7247, #7241, #7240, #7239,
   #7236, #7231 HPACK bomb).  Review and close or fix before any v1.0 tag.

## Tier 2 — expected-type inference, lambdas, UFCS

- `expected-type-inference` (7): bracket literals not adopted as `List` in
  argument and nested positions (#8277, #8293), JVM `Int` literal to
  `List[Long]` ClassCastException (#8278), bare `None`/`Ok`/`Err` built with
  erased type arguments (#8303, #8346), `newMap()` as nested map value (#8274).
- `lambdas-closures` (6): lambda default values (#8302), function-typed field
  of a generic record (#8319), boxed lambda parameters (#8349), capture
  analysis vs `for` shadowing (#8345), chained curried call member read (#8347),
  assert in lambda in generic function (#8232).
- `ufcs-method-calls` (3): async dot-named methods (#8253), enum receivers
  (#8254), lambda reading `self` (#8291).

## Tier 3 — JVM and native parity

- **JVM.**  `docs/44` bands J0-J7 are shipped; what remains is the long tail
  (`jvm-production-readiness` 12): J008 on `+` over `String` elements and
  `slice.toList()` (#8237, #8281, #8323, #8351), `List[List[Long]]` casts
  (#8242), wire bootstrap stackmap (#8372), inout through generic field or
  aspect weaving (#8272, #8368), inout `Ref` megamorphism (3-5x slowdown,
  #8371), array/buffer passed to `spawn` copied inside the task (#8391).
  Still `NOT_IMPLEMENTED` on JVM: lyric-storage S3/Azure, lyric-mq brokers,
  lyric-mail providers, lyric-search (docs/57 §3).  `F8`: `@externTarget`
  catches only `java/lang/Exception`, not `Error` (accepted limitation, see
  docs/18 Q-J009).  `F1`: `self_test_b128.l` hardcodes `/tmp/lyric-jvm-b128`.
- **Native (`native-backend` 11).**  `N0007` family: impl method for a generic
  target (#8300), method call on a captured `List` in a lambda (#8330),
  one-argument `String.substring` (#8335), function-type alias and tuple `for`
  pattern (#8348), `slice[(Int) -> Unit]` literal (#8315), `isNone(None)`
  (#8352), or-patterns (#8428); closure `var` capture by value, `println` of non-scalars, `String +
  Int`, `UInt`/`ULong` (#7891, umbrella epic #4607 is stale and should be
  rewritten or closed); reachability keyed by bare method name (#8413); clang
  collision with no diagnostic (#8360); `nativeAddrOf(var: Int)` (#4845).
  Missing: arm64 and macOS native CI legs (#8419); Windows (docs/67 G9) runs the
  core suite (D205), child processes (D208), sockets and TLS over Winsock and
  Schannel (D209), and the compiler-hosted self-tests with AddressSanitizer (D213);
  the graphics examples on Windows remain (#8435).
- **Private helpers of a generic.**  A `pub` generic carries the private generics it
  reaches on every target (D215); a private non-generic helper is still T0123 on
  dotnet and the JVM (docs/01 §3.3, #8427).
- **Cross-target stdlib divergence.**  `Std.Time.toIsoString` (#8314), `Map.add`,
  tuple key and `==` on `List` differ by target (#7301, #8169, #8170),
  JVM `Std.Set` unusable (#7312), JVM `format1..4` drop args (#7367).

## Tier 4 — v1.0 gates and release

The dotnet soundness floor that gated v1.0 (`docs/36` §R7) is closed; what is
left is verification and release work, tracked in `docs/36`:

- Re-run the Tier 1 triage; no open silent-miscompile on `--target dotnet`.
- Stability promotions (#367) and the `@stable(since="1.0")` surface walk.
- State the "supported but not v1.0 SemVer-guaranteed" JVM note in
  `docs/01` §0.1 (G1, D-progress-620; flagged not-yet-done).
- Release items from `docs/63`: `--release` does no optimisation and does not
  relax overflow checking (#6263), `--shape standalone` unimplemented (#6262),
  bands B2-B7 (debug info, debugger).
- Distribution: AOT binary and signing are shipped; ISO submission is Phase 6+.

## Tier 5 — feature work, in dependency order

1. **Graphics (docs/67).**  G7 `lyric-game` (D201), `Std.Parallel` on a worker
   pool (D202) and the native `lyric-ui` host (D203, D204) are implemented on
   Linux.  Remaining: the multi-threaded coroutine scheduler (G8, #7947), G9
   Windows (#7948; core target D205, processes D208, sockets and TLS D209, self-tests D213, remaining #8435), accessibility through AccessKit (G10, #8430) and pruning
   dependency kernels from the link (#8429); G4 macOS CI, G5 Cocoa/Win32
   surfaces and the macOS `.app` bundles (#8401, #8419); `lyric-text` bidi and
   UAX #14 (#8410); `buffer[T]` lazy copy (#8389) and the warn-on-copy lint
   (#8395); explicit mutable-record marker (D157 follow-up, #7955).
2. **Structured tasks (docs/68).**  `Std.Task` handle API (`waitFor`, `isDone`,
   `cancel`, `awaitAll` over handles, `awaitAny`), the handle-escape rule (new
   diagnostic code **V0037**; V0035 is taken by the verifier), MSIL scope-exit
   join, native `Task[T]`; open Q-TASK-002/004/005/006/008.
3. **Ecosystem backends (docs/57).**  lyric-storage S3/Azure, lyric-mq brokers,
   lyric-mail SES/SendGrid (#7462), lyric-search wiring (#5067), Hangfire/
   Quartz.NET on dotnet; missing `Lyric.Testing` mocks (Jobs, Search, Queue
   consumer, i18n, Ws); `.new()` migration of remaining `..ctor` wrappers in
   lyric-mq/jobs/ws/resilience kernels and `_kernel/collections_host.l`.
4. **Tooling.**  LSP: stdlib not loaded by the type check, hover/go-to on
   dot-named calls (#8304, #8338); formatter/parser losslessness (#2280);
   test runner v2 (#678); native coverage (#5294); `lyric doc` roll-up index.
5. **wasm/npm.**  Q-JS-002/007/009, NPM shims beyond plain functions,
   transitive NPM deps, stackful lift and error-context gating (#8117, #8118).
6. **Contracts.**  `Std.Core.Proof` structural induction (gated on verifier
   induction support); stubbable DSL beyond `_value`/`_counter` (docs/36 G-01);
   `@projectionBoundary` `asId` (G-10); `call.caller` aspect context.
7. **Compiler structure (docs/59).**  Four independent type systems (H10),
   capture-analysis extraction, match decision tree, intrinsic table, stdlib
   API consolidation, performance band (JVM auto-FFI caching, MSIL
   `methodBodyRvas`).

## Tier 6 — deferred, low priority

- **Regex RE2** (`Std.Regex`): `regex_safe.l` mitigates; full RE2 backend
  waits for a program exposed to attacker-controlled patterns.
- **FFI shapes:** `Span<T>`, `params T[]`, extension methods, `inout` struct
  receivers, value-type property set, out/ref null-to-Option convention.
- **CST type-expression multi-line layout** in the formatter (unverified).
- **TLS/HTTP2:** native h2 (#6808), dotnet h2 send pump (#6107), native TLS
  (#5890, #6106); epic #5874.
- **ISO standardisation** and conformance programme (Phase 6+).

---

## Issue tracker hygiene (do alongside Tier 1)

- Stale epics: #4607 (native umbrella) and #7944 (G5, all three golden-image
  examples pass in CI) were closed on 2026-10-21; the native CI matrix residual
  is #8419 and the G5 residual is #8404. Deliberately left open because their
  own exit criteria are unmet: #7945 (G6: no real-hardware frame-budget run,
  bidi in #8410), #7941 (G2: JVM `spawn` copy #8391, verifier array model
  #8394, copy-before-loop lint #8395), #8118 (NPM, items 2-8) and #8149
  (value-generic protected types cannot be `pub`, T0166).
- Close the ten `review-finding` doc-hygiene issues (#6982, #6999, #7066,
  #7068, #7070, #7073-#7077) after confirming each is fixed on `main`.
- 239 of 379 open issues carry no `group:*` label; label them so clusters
  above stay countable.
