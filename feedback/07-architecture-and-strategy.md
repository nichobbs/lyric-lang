# 07 — Architecture and Strategy Review

_Reviewer: Architect agent. Date: 2026-05-17. Repository: `/home/user/lyric-lang`._

This review is concrete and evidence-driven; every claim is anchored to a
specific file or to a `D-progress-###` / `D###` entry. It is organised by the
six themes in the brief.

For context: bootstrap compiler ~41.7k LOC F#
(`find compiler/src -name '*.fs' -exec wc -l`); self-hosted compiler tree
~82.6k LOC Lyric (`find compiler/lyric -name '*.l' -exec wc -l`); ecosystem
libraries ~16.0k LOC Lyric across 24 packages.

---

## Executive summary

Lyric is further along than its v1 plan suggests on the *self-hosting*
axis (R1–R6 all marked complete; MSIL self-hosted PE pipeline is the
default `--target dotnet`) but is taking on substantial *ecosystem
debt* that is not visible in the roadmap.

**Top three blockers for v1.0**, in order:

1. **Silent unsoundness in the verifier for `async` functions.** Every
   `async func` is verified as if `IsAsync = false`
   (`compiler/src/Lyric.Verifier/VCGen.fs:1466`), with no diagnostic.
   For a "safety-oriented" language this is a credibility-critical
   bug. See Finding 8.
2. **20+ ecosystem libraries shipped with zero tests** and several
   built around aspect annotations (`@inline_template`, `pub aspect`
   templates, `config { }` in aspect bodies) that the compiler
   *parses but ignores*. See Findings 9–11.
3. **No `Lyric.SdkVersion` enforcement.** The version-skew check is
   embedded in DLLs and read by `lyric --sdk-info` but never gates a
   build. `LYRIC_STRICT_SDK_VERSION` is documented in `docs/34` §5 but
   not implemented. See Finding 4.

These are the items that would turn first-week-of-adoption into a
support burden. Everything else listed below is either real progress
(self-hosting transition is cleaner than expected — Findings 1–3) or
process-level rather than blocking.

---

## Theme 1 — Self-hosting transition risks

### Finding 1 — Bridge shims are genuinely thin (LOW)

Sampled four `SelfHosted*.fs` shims to validate the "thin shim"
claim in `CLAUDE.md` §"F# surface is frozen":

| File | LOC | Bridge structure |
|---|---|---|
| `compiler/src/Lyric.Cli/SelfHostedFmt.fs` | 163 | driver source + `Assembly.LoadFrom` + two reflected delegates |
| `compiler/src/Lyric.Cli/SelfHostedCli.fs` | 127 | driver source + one `main(string[]): int` delegate |
| `compiler/src/Lyric.Cli/SelfHostedManifest.fs` | 200 | + 90-line protocol parser (line-oriented key=value) |
| `compiler/src/Lyric.Cli/SelfHostedVerifier.fs` | 200 | + 70-line `diag|result|level=` protocol parser |

The shims do exactly what `CLAUDE.md` advertises: a driver-source
constant, a `Directory.CreateDirectory` scratch, an
`Assembly.LoadFrom`, one `GetMethod` per delegate, a lock around
`resolved`. Where the shim grows past ~150 LOC it is parsing the
line-oriented protocol the Lyric side emits (`SelfHostedVerifier.fs:144`,
`SelfHostedManifest.fs:107`). That is unavoidable F# code — the
boundary is `string → string`, so the F# side has to parse what the
Lyric side serialised. The line-protocol is text and human-readable,
which is the right trade-off for an evolvable bridge.

**Recommendation:** None. The discipline is being followed.

### Finding 2 — Bridge boilerplate is duplicated across 12 files (MEDIUM)

Every `SelfHosted*.fs` reimplements: the per-process scratch
directory, the `Emitter.emit` call with an `EmitRequest`,
`preloadStdlibAssemblies()`, the diagnostic dump, the
`stdlibAssemblyPaths` find, the lock+cache pattern. Compare
`SelfHostedFmt.fs:37–143` to `SelfHostedManifest.fs:30–99` to
`SelfHostedVerifier.fs:34–118` — the first ~80 lines of each are
the same pattern with only the driver-source string and the
output-DLL name varying.

**Recommendation:** Extract `Lyric.Cli.SelfHostedBridge` infrastructure
exposing two helpers:
```fsharp
val ensureBridgeAssembly :
    driverPackage:string -> driverImport:string -> targetDllName:string -> string
val resolveStaticMethod :
    asmPath:string -> typeName:string -> methodName:string ->
    argTypes:System.Type[] -> System.Reflection.MethodInfo
```
Each shim collapses to ~30 LOC: driver source, one helper call, one
reflection call, the per-bridge wrapper. The cost is modest (one new
module, ~100 LOC); the win is that adding the next bridge stops
being a copy-paste exercise where 5/12 already forgot
`AppDomain.CurrentDomain.ProcessExit.Add` cleanup (Finding 3).

**Trade-off:** A unified helper makes per-bridge customisation
(e.g. `SelfHostedVerifier.fs:51` passing `allowUnverified: bool` as a
second parameter) require either a parameter array or an
escape-hatch path. Either is acceptable.

### Finding 3 — Five bridges leak per-process scratch directories (LOW)

`SelfHostedBench.fs`, `SelfHostedJvm.fs`, `SelfHostedMsil.fs`,
`SelfHostedOpenApi.fs`, and `SelfHostedVerifier.fs` create
`Path.Combine(Path.GetTempPath(), "lyric-*-bridge-<pid>")` but
*do not* register an `AppDomain.CurrentDomain.ProcessExit.Add`
cleanup. The other seven shims do
(e.g. `SelfHostedFmt.fs:59–60`, `SelfHostedCli.fs:44–45`,
`SelfHostedManifest.fs:44–45`).

In a long-running test harness or CI agent that spawns the F# CLI
hundreds of times this accumulates one driver-DLL-plus-scratch-dir
per invocation in `$TMPDIR`. Not data loss; not a crash; a slow leak
that surfaces as "tmp full on CI" months later.

**Recommendation:** Either add the cleanup hook to the five missing
files, or — better — fix it in the shared helper from Finding 2.

**References:**
- `compiler/src/Lyric.Cli/SelfHostedJvm.fs:50–55` — creates scratch, no `ProcessExit.Add`
- `compiler/src/Lyric.Cli/SelfHostedFmt.fs:54–60` — creates scratch *with* `ProcessExit.Add`

### Finding 4 — `Lyric.SdkVersion` is embedded but never enforced (HIGH)

The compiler embeds a `Lyric.SdkVersion` JSON resource into every
emitted DLL
(`compiler/src/Lyric.Emitter/Emitter.fs:6813–6822`) carrying
`language_version`, `stdlib_version`, `compiler_version`,
`build_date`. `SdkRoot.tryReadSdkVersion`
(`compiler/src/Lyric.Emitter/SdkRoot.fs:59–74`) reads the resource
back via Mono.Cecil.

But the only consumer is `lyric --sdk-info`
(`compiler/src/Lyric.Cli/Program.fs:2196–2227`), which *prints*
the version. There is no compile-time check that:

- a restored Lyric package's `compiler_version` matches the current
  compiler;
- the cached `Lyric.Stdlib.dll` was emitted by *this* compiler version;
- the `RestoredPackages` chain is internally version-consistent.

`docs/34-distribution-strategy.md` §5 promises:

> **Match** — use the pre-compiled stdlib DLL.
> **Mismatch** — warn and fall back to source stdlib, or error if
> `LYRIC_STRICT_SDK_VERSION=1` is set.

`grep -rn LYRIC_STRICT_SDK_VERSION compiler/` returns no hits. The
fallback-to-source path also is not wired.

**Why this is a v1.0 issue:** Lyric distributes a pre-compiled
`Lyric.Stdlib.dll` *and* restored package DLLs via NuGet
(`docs/22-distribution-and-tooling.md`, `docs/21-nuget-linking.md`).
A user upgrading the compiler from `0.1.0` to `0.1.1` will silently
mix old stdlib bytecode with new compiler-emitted call sites. With
no version check the first symptom is a `MissingMethodException` at
runtime, which is the worst diagnostic surface for a
"safety-oriented" language to produce.

**Recommendation:** Make `tryReadSdkVersion` mandatory on every
restored DLL in `Emitter.fs:6089` (`refs:
RestoredPackages.RestoredPackageRef list`). Compare against
`Emitter.VERSION` and emit:

- `B0050 warning`: minor-version skew (e.g. `0.1.0` ↔ `0.1.1`)
- `B0051 error`: major/minor skew under `LYRIC_STRICT_SDK_VERSION=1`,
  or any major-version skew unconditionally.
- `B0052 warning`: missing `Lyric.SdkVersion` resource on a restored
  DLL (i.e. pre-D-progress-126 artefact).

Effort: ~50 LOC in `Emitter.fs` + tests. Impact: replaces a runtime
`MissingMethodException` with a build-time diagnostic.

### Finding 5 — Rollback story is clean for `lyric build`, absent for `fmt`/`lint`/`doc` (MEDIUM)

`lyric build` has a documented rollback: `--target dotnet-legacy`
(`compiler/src/Lyric.Cli/Program.fs:1036–1039`) routes through the
F# emitter instead of `SelfHostedMsil`. The dispatcher's primary
entry also falls back: `Program.fs:2386–2388`:

```fsharp
match SelfHostedCli.tryRun argv with
| Some code -> code
| None      -> bootstrapDispatch argv
```

This is the right design and works.

But the per-command bridges have *no* fallback. `SelfHostedFmt.format`
(line 156), `SelfHostedLint.lint`, `SelfHostedDoc.generate`,
`SelfHostedVerifier.prove`, `SelfHostedManifest.parseText` all
`failwith` on bridge failure (search for `failwithf` in any
`SelfHosted*.fs`). If `Lyric.Fmt.dll` fails to compile because of a
bug introduced into a self-hosted source file, `lyric fmt` is dead
for that release with no escape. The `--legacy` flag is only on
`fmt` (per `docs/36-v1-roadmap.md` §R2); `lint`, `doc`, `prove`,
and `restore` have nothing.

Note: `Doc.fs`, `Fmt.fs`, and `ContractMeta.fs` have already been
*deleted* from `compiler/src/Lyric.Cli/` (`ls
compiler/src/Lyric.Cli/Doc.fs` is `not found`). So `--legacy` for
those commands cannot be re-enabled even if needed; the F# source no
longer exists.

**Recommendation:** Either (a) keep one bootstrap-grade F# fallback
per command in tree (the "F# surface is frozen to bootstrap shims
only" clause in CLAUDE.md §F# arguably permits this for emergency
rollback paths), or (b) accept that v1.0 ships with no rollback
on these commands and document that explicitly in the v1.0
release-risk note. Option (a) is what Rust does
(`rustc -Zforce-bootstrap`). The deletion of `Doc.fs`/`Fmt.fs`
suggests option (b) was implicitly chosen — but the choice is not
documented and would be surprising to a user hitting a
`lyric fmt → emitter errors` cliff mid-release.

### Finding 6 — Bridge cold-start cost is real and uncomfortable (LOW)

Comment from `SelfHostedFmt.fs:36–37`:

> The driver compile is the slow part (~3-5s on a cold cache); we
> only do it once per `lyric` invocation that touches the formatter.

The Lyric CLI now has 12 bridges (count from
`ls compiler/src/Lyric.Cli/SelfHosted*.fs`). A worst-case `lyric`
invocation that runs `build → test → fmt --check → lint` (e.g. a
pre-commit hook) pays 3–5s × N bridges of warm-up before *any*
actual work happens, because each bridge's `ensureBridgeAssembly`
re-runs the throwaway compile. The per-process cache is
process-wide, so the cost is paid once per process, but the *first*
process pays it for *all* the bridges it touches.

**Note:** This is not a v1.0 blocker. It's a known cost of the
in-process reflection bridge. But it should be measured.

**Recommendation:** Add a benchmark in
`compiler/tests/Lyric.Cli.Tests/` that times `lyric --version`
(touches no bridge) and `lyric fmt some.l` (touches one bridge)
back-to-back, and gate on a regression budget. If the bench shows
the cost is worse than the comment claims, consider precompiling
the bridge DLLs at SDK install time and shipping them in
`lib/`, eliminating the cold compile entirely.

---

## Theme 2 — Missing / incomplete subsystems

### Finding 7 — Contract elaborator deferrals are correctly fenced but understated in roadmap (MEDIUM)

`compiler/lyric/lyric/contract_elaborator/elaborator.l:25–47` is
explicit:

- `ensures:` clauses on top-level returns: elaborated.
- `ensures:` clauses on nested returns inside `if`/`match`/loops:
  **not elaborated**; the F# bootstrap emitter still inserts these.
- Loop `invariant:`: **not elaborated**; verifier consumes them,
  runtime checks are absent in both elaborator and bootstrap.
- Protected-type `when:` barriers and `invariant:` clauses: **not
  elaborated**; F# bootstrap emits them directly in IL.

This is correctly fenced — the F# bootstrap fills the gap, so the
runtime behaviour is sound. **But** the moment the F# bootstrap is
demoted (`--target dotnet-legacy` deprecated → removed in 1.x), the
contract elaborator becomes load-bearing and any nested-return
`ensures:` check silently disappears.

`docs/36-v1-roadmap.md` does not list this as a gate. It is mentioned
in `docs/05-implementation-plan.md` §M5.2 stage 2 but only as a
historical note. There is no `R-#` item that says "before
`--target dotnet-legacy` can be removed, the contract elaborator
must reach parity with `Emitter.fs::emitContractCheck`".

**Recommendation:** Add `R7` to `docs/36-v1-roadmap.md` covering
contract-elaborator parity work explicitly. This is a v1.x item but
*must* be tracked because it is the closing gate on F# emitter
sunset (per `docs/23-fsharp-shim-elimination.md`).

### Finding 8 — Verifier silently ignores `async`/`yield` — CRITICAL (CRITICAL)

`compiler/src/Lyric.Verifier/VCGen.fs:1466`:

```fsharp
let entryToFn (ed: EntryDecl) : FunctionDecl =
    { ...
      IsAsync     = false
      ... }
```

`grep -in 'IsAsync\|await\|EAwait\|EYield\|SYield'
compiler/src/Lyric.Verifier/*.fs` returns three hits, all
list-comprehension `yield` keyword usage in F# code, and one
hard-coded `IsAsync = false`. The verifier:

- Sets `IsAsync = false` on every entry it analyses.
- Never inspects `fn.IsAsync` on user functions.
- Has no special case for `await` or `yield` expressions — they fall
  into the generic "expression construct not yet modelled in proof
  translation" diagnostic
  (`VCGen.fs:734`) **only if** they reach the expression walker;
  many flow paths walk only contract expressions which never see an
  `await`.

`grep async compiler/lyric/lyric/verifier/vcgen.l` returns nothing.

**Consequence:** `async func transfer[...]() with requires: ... ensures:
...` is verified as if the body were synchronous. The Hoare call
rule (§10.4) becomes unsound for async callees: the verifier proves
`requires` at the call site and assumes `ensures` from the *value*
returned by `Task.GetAwaiter().GetResult()` — but the wp/sp
calculus has no model for the suspension point. A `requires` clause
on a `Task<T>` returning function might be discharged at the call
site even though the precondition can only hold *after* the
suspension.

**Why this is CRITICAL:** Lyric is positioned as a "safety-oriented"
language. The proof system is the differentiator. Quietly producing
"discharged: 12/12" on a function whose proof was vacuously discharged
because the verifier didn't understand the suspension point is the
worst possible failure mode for the marketing story. A
counterexample-producing failure is recoverable; a false positive
is not.

**Recommendation (immediate):** Add a diagnostic
(`V0008: @proof_required does not support async functions in v1.0;
mark this function @runtime_checked or refactor into a sync core +
async wrapper`) emitted by `Lyric.Verifier.ModeCheck` whenever
`@proof_required` encloses an `async func`. This converts an
unsound silent pass into a hard, documented failure.

**Recommendation (1.x):** Either model `Task<T>` as a sequencing
monad in the wp calculus (academic territory; expect a paper) or
permanently restrict proof to the synchronous fragment and require
users to extract the sync core themselves. The first is the right
answer; the second is what shipping v1.0 looks like.

**References:**
- `compiler/src/Lyric.Verifier/VCGen.fs:1466` — `IsAsync = false` hard-coded
- `docs/15-phase-4-proof-plan.md` — does not address async at all (`grep -in async docs/15-phase-4-proof-plan.md` returns nothing)
- `docs/01-language-reference.md` §11 — promises proof for `@proof_required` packages without carving out async

### Finding 9 — `@inline_template` annotation is parsed but unrecognised (HIGH)

`grep -rln '@inline_template' lyric-*/` returns hits in 11 ecosystem
libraries:

```
lyric-storage, lyric-lambda, lyric-cache, lyric-logging, lyric-ws,
lyric-web, lyric-grpc/aspects.l (multiple), lyric-mq, lyric-mail
(implicit via templates), lyric-jobs, lyric-feature-flags
```

`grep -rln 'inline_template' compiler/` returns **zero** matches.
Neither the F# parser (`compiler/src/Lyric.Parser/`) nor the
self-hosted weaver
(`compiler/src/Lyric.Emitter/Weaver.fs`,
`compiler/lyric/lyric/aspects*`) recognises this annotation.

The annotation is silently dropped during parsing (it's accepted as a
generic `Annotation` AST node and never consumed). The aspect body
runs through whatever the standard `pub aspect` template path is —
which, per `docs/36-v1-roadmap.md` §G-06, is *also* "Parsed; template
instantiation inert."

**Consequence:** Every `@stable(since="0.1") @inline_template
pub aspect RequiresGrpcAuth` declaration in lyric-grpc, etc., is
non-functional. Users who `use RequiresGrpcAuth with (jwtSecret:
...)` in their handler code will not get the wrapper. There is no
diagnostic.

**Recommendation:**
1. Decide whether `@inline_template` is supposed to exist (e.g. as a
   variant of `pub aspect` for C-mode inlining per docs/27).
2. If yes, file a `Q-aspectlib-N'` open question and gate
   `lyric-grpc`/`lyric-mq`/etc. on its closure.
3. If no, sweep the ecosystem libraries and remove the annotation,
   plus issue `A0009 warning: unknown annotation '@inline_template'`
   in the parser / typechecker. This is a one-line check in
   `Lyric.TypeChecker.Checker` against a known-annotations table.

The current state — silently ignoring an unknown annotation that
appears on 60+ public surface items across 11 libraries — is the
worst combination of all three options.

**References:**
- `lyric-grpc/src/aspects.l:74` — `@inline_template` on `RequiresGrpcAuth`
- `lyric-grpc/src/aspects.l:122` — `@inline_template` on `RequiresGrpcRole`
- `compiler/src/Lyric.Emitter/Weaver.fs:15–25` — explicit list of bootstrap-grade limitations; `@inline_template` not mentioned
- `docs/36-v1-roadmap.md` §G-06 — `pub aspect` templates "Parsed; template instantiation inert"

### Finding 10 — Q011 surface-freeze stops at stdlib; ecosystem is unfrozen (MEDIUM)

`docs/36-v1-roadmap.md` R1 is marked done because `stdlib/STABILITY.md`
exists and every stdlib `pub` item is `@stable(since="1.0")` or
`@experimental`. But the v1 roadmap's G4 punts ecosystem libraries
to "Independent versioning per library; each declares its own
stability policy in `lyric.toml`."

Audit the actual state:

```
grep -L '@stable\|@experimental' lyric-*/src/*.l
→ lyric-grpc/src/types.l
  lyric-otel/src/{otel,otlp,types}.l
  lyric-proto/src/{decoding,encoding,proto,types}.l
```

Four files in lyric-grpc, lyric-otel, lyric-proto carry zero
stability annotations. `lyric.toml` for those libraries does declare
a version, but the file-level annotations that `lyric
public-api-diff` consumes are absent. `public-api-diff` will report
every symbol as "added/removed" on the first run rather than
producing a clean baseline.

**Recommendation:** Either annotate them (10 minutes per file) or
amend `STABILITY.md` to include a per-library section. Without this
the G4 promise is decorative. Effort is small; impact is on whether
the v1.0 announcement can credibly claim SemVer for the ecosystem.

### Finding 11 — Q022-2, Q022-4, and FFI phase-3 shapes (per D035) are deferred without a 1.x assignment (LOW)

`docs/36-v1-roadmap.md` §R5 explicitly deferred Q022-2 and Q022-4 to
post-1.0 and §G-11 deferred FFI phase-3 shapes to "on-demand". This
is a reasonable scope cut — but the "on-demand" framing is the
wrong shape for a v1.0 promise. A user with a `List<T>` of
`Span<T>` parameters can't ship until someone files the bug and the
fix is prioritised. There is no SLA.

**Recommendation:** Convert "on-demand" into a 1.1 budget. Pick a
quarter; pre-commit to N FFI-phase-3 escape-hatch tickets. This is
about user expectations, not engineering scope.

---

## Theme 3 — Ecosystem strategy

### Finding 12 — Zero tests across 24 ecosystem libraries — CRITICAL (CRITICAL)

The audit:

```
for d in lyric-*/; do
  loc=$(find "$d" -name '*.l' | xargs wc -l | tail -1 | awk '{print $1}')
  tests=$(find "$d" -name '*test*' -o -name '*tests*' | wc -l)
  echo "$(basename $d) loc=$loc tests=$tests"
done
```

Result: 23 libraries with `tests=0`, one (`lyric-testing`) with
`tests=2` (its own *test helpers*, not tests *of* the helpers). Total
16k LOC of shipped library code with no `*_tests.l` file in any
package. By contrast `stdlib/tests/` has 16 `*_tests.l` files and
`examples/*/tests/` has another 8.

This is across libraries with non-trivial logic: `lyric-grpc` (866
LOC, gRPC marshalling), `lyric-mq` (1204 LOC, queue + DLQ + idempotency),
`lyric-storage` (970 LOC, S3 multipart + presigned URLs),
`lyric-lambda` (1715 LOC, API Gateway/SQS/SNS/EventBridge event
shapes), `lyric-search` (1038 LOC, Elasticsearch query DSL).

**Why this is CRITICAL for v1.0:** The libraries are listed as
shippable in `appendix-b-quick-reference.md` lines 668–684. A user
adopting Lyric will form their first impression of "is this language
production-ready" from these libraries. Zero tests means every bug
ships unobserved.

The aspect-template inertness (Finding 9) is detected immediately by
unit tests of any user that exercises `use RequiresGrpcAuth with
(...)`. Without those tests, the libraries can sit broken indefinitely.

**Recommendation:**

1. **Immediate:** Define a per-library test-budget gate. Each
   ecosystem library must have at least *one* `*_tests.l` smoke
   test that compiles, links, and exercises one public surface
   item. This is the bare minimum to catch the aspect-inertness class
   of regression.

2. **Before v1.0:** Drop the libraries from the v1.0 announcement
   list (move them from "shipped" to "preview" in
   `appendix-b-quick-reference.md`) until they reach a
   per-library coverage target (e.g. ≥40% of public surface).

3. **Strategic:** Acknowledge in `docs/36-v1-roadmap.md` G4 that
   "independent versioning per library" implies "independent
   *credibility* per library" and either centralise QA or admit
   these are user-contributed quality.

**References:**
- `find lyric-*/ -name '*_tests.l'` returns no files
- `lyric-lambda/src/lambda.l` — 1715 LOC, no tests
- `lyric-mq/src/mq.l` — 1204 LOC including DLQ + idempotency aspects, no tests

### Finding 13 — 24 libraries is premature given the compiler isn't out of Phase 5 (HIGH)

`docs/05-implementation-plan.md` puts Phase 6 (ecosystem) *after*
v1.0 ships. The repository ships 24 ecosystem libraries pre-1.0
that have only existed for a single release cycle. Their public
surface is unstable (Finding 10), untested (Finding 12), and
includes constructs that the compiler doesn't fully recognise
(Finding 9).

The maintenance cost is significant and not budgeted:

- Every compiler change that touches the parser surface
  (e.g. an annotation grammar extension) requires regression-testing
  24 libraries.
- Every change to aspect semantics (e.g. closing G-06 in
  `docs/36-v1-roadmap.md`) requires re-validating every `pub
  aspect` template in 11 of the libraries.
- Distribution: each library ships independently per G4, meaning 24
  release pipelines, 24 NuGet identities, 24 SemVer trees.

**Recommendation:**

Pick one of three honest framings and commit:

- **Framing A — "Promo libraries":** Mark these as "showcase /
  early-preview", not production. Drop the appendix-B "shipped"
  language. Accept they're proof-of-concept until v1.1+.
- **Framing B — "Owned libraries":** Stand up a per-library
  CI/test/release pipeline. Hire / allocate maintainer time.
  This is the Rust-Foundation model and is expensive.
- **Framing C — "Community libraries":** Move them out of the main
  repo into separate repos and have the community own them. The
  main repo ships the compiler + stdlib only.

The current implicit framing — "they live in the main repo, they
ship under our brand, but they're independently versioned and
untested" — is the worst of all three.

### Finding 14 — Aspect adoption is too narrow to validate the design (MEDIUM)

D047/D051 (aspect-oriented design) was a substantial language
investment. The validation in the ecosystem:

- 11 libraries declare `*_aspects.l` files with `pub aspect`
  templates.
- Per Finding 9, the template form is parsed but inert.
- `grep -rn 'use [A-Z]' lyric-*/src/*.l examples/*/src/*.l |
  grep -v 'pub use'` returns 5 hits across all of the ecosystem
  *and* the worked examples. Five real `use AspectName with (...)`
  invocations against 11 declared aspect template libraries.

This is the wrong adoption ratio for a language feature claiming to
solve cross-cutting concerns. Either:

- the aspect declarations are speculative (libraries are positioned
  for future users, but users don't exist yet); or
- users are choosing not to use aspects because the templates don't
  work (Finding 9).

**Recommendation:** Before promoting aspects to a v1.0 feature, run
the worked-examples in `examples/` through with `use Trace`,
`use Retry`, `use Audit` actually applied. If those don't validate
the design, defer aspects to a 1.x feature flag rather than
promoting them as a v1.0 differentiator.

**References:**
- `docs/36-v1-roadmap.md` §G-06 — four constructs deferred to 1.1/1.2
- `lyric-cache/src/cache_aspects.l:60–110` — declared but not exercised by any caller
- `examples/ledger/src/`, `examples/product-catalog/src/`, etc. — no `use` applications of any `pub aspect`

---

## Theme 4 — Documentation drift

### Finding 15 — Recent ecosystem libraries lack book chapters or language-reference coverage (HIGH)

`CLAUDE.md` is explicit:

> A task is not complete until the docs and book reflect the shipped
> state. Commit them in the same PR as the feature.

Spot-check on three recent shipped features (per `D-progress-252`):

| Feature | Decision-log | Progress log | Language ref | Book chapter |
|---|---|---|---|---|
| `lyric-proto` (D067) | yes | yes | **no** | **no** (only line in appendix-b) |
| `lyric-grpc` (D068) | yes | yes | **no** | **no** (only line in appendix-b) |
| `lyric-otel` OTLP (D069) | yes | yes | **no** | **no** (only line in appendix-b) |
| `lyric-mq` (D-progress-225-ish) | yes | yes | **no** | **no** |
| `lyric-mail` | yes | yes | **no** | **no** |
| `lyric-storage` | yes | yes | **no** | **no** |
| `lyric-search` | yes | yes | **no** | **no** |
| `lyric-i18n` | yes | yes | **no** | **no** |
| `lyric-feature-flags` | yes | yes | **no** | **no** |

The book has 31 chapters; the most-recent ecosystem-related chapters
are `24-web-services.md`, `25-caching.md`, `26-database-access.md`,
`27-health-checks.md` — i.e. up through `lyric-web` / `lyric-cache`
/ `lyric-db` / `lyric-health`. Everything that shipped after
`D-progress-200` is absent.

`grep -c 'Mq\|Mail\|Storage\|Search\|Session\|Jobs\|I18n'
docs/01-language-reference.md` returns 1 (and that one is
`Session` as a scope kind). The language reference does not mention
any of these libraries.

**Recommendation:** The CLAUDE.md rule is "same PR or immediate
follow-up". The latter has not been honoured for the last ~6
shipped libraries. A choice point:

- Either (a) carve a "Library reference" appendix or
  `book/chapters/29-application-libraries.md` that consolidates
  one section per library (this is the lowest-effort fix; can be
  done by spec-walking the source's `pub` items in ~half a day per
  library); or
- (b) drop the `appendix-b` lines that gesture at these libraries
  until the chapter exists. The current state (gesture without
  chapter) misleads users into thinking documentation exists.

I'd recommend (a); the libraries are real, the absence is just
documentation labour.

### Finding 16 — `Lyric.SdkVersion` documentation promises features that aren't built (LOW)

`docs/34-distribution-strategy.md` §5 documents `LYRIC_STRICT_SDK_VERSION=1`
and the warn/fallback semantics in detail. None of it is implemented
(Finding 4). When the doc is more aspirational than the code, two
things go wrong: users file bugs against documented features that
don't exist, and reviewers approve PRs against documented behaviour
that no test enforces.

**Recommendation:** Either mark `docs/34` §5 as "designed; not
yet implemented (Q-dist-007)" or build it. The latter is the
right move per Finding 4.

---

## Theme 5 — Critical-path risks for v1.0

### Finding 17 — Biggest blocker is Finding 8 (verifier async unsoundness) (CRITICAL)

Re-stated for the critical-path roll-up: the verifier silently
ignores `IsAsync` and produces vacuously-discharged proofs on
async functions. Everything else listed in `docs/36-v1-roadmap.md`
§2 is shipped (R1–R6 all marked complete). The roadmap does not
mention this gap. A v1.0 release with this bug undermines the
marketing pitch.

**Recommendation:** Treat as a release-blocker. Either (a) emit
`V0008` to reject `@proof_required` on async functions, or (b) make
the verifier model async as a sequencing operation. (a) is shippable
in a week and is the right call for v1.0.

### Finding 18 — Non-obvious dependency: R4 (M5.3 stage 6) sunset depends on contract elaborator parity (MEDIUM)

`docs/36-v1-roadmap.md` §R4 marks "Doc, Lint, Pack csproj" as
shipped (D-progress-255) and ContractMeta/Fmt.fs sunset as
"deferred". But Finding 7 surfaces that the *F# emitter's*
contract-check insertion is doing work the self-hosted contract
elaborator hasn't replicated (nested returns, loop invariants,
protected types). So:

- Removing `--target dotnet-legacy` removes the F# emitter.
- Removing the F# emitter removes
  `Emitter.fs::emitContractCheck`'s coverage of nested returns.
- Without contract-elaborator parity, nested-return `ensures:`
  clauses silently disappear.

This dependency is **not** in `docs/36-v1-roadmap.md` §5
"Milestone ordering and dependencies". The R4 → "F# Fmt.fs sunset"
arrow is there; the implicit "→ no removing F# emitter until
contract-elaborator nested-return parity" arrow is not.

**Recommendation:** Add the dependency to `docs/36` §5 explicitly,
and gate any `--target dotnet-legacy` removal on
contract-elaborator parity tests.

### Finding 19 — What to cut to ship (CRITICAL)

If forced to pick a minimum-viable v1.0 from the current state, I
would cut:

1. **All 24 ecosystem libraries from the v1.0 announcement.** Move
   them to "early preview". The compiler + stdlib + tooling alone
   is a credible v1.0; bundling untested libraries dilutes the
   story. (`appendix-b-quick-reference.md` lines 668–684).

2. **Proof on async functions.** Emit V0008. Ship `@proof_required`
   for the synchronous fragment only. Document explicitly. The
   counterfactual (silent unsoundness) is worse than a feature gap.

3. **Aspect templates (`pub aspect` form).** Per G-06, this is
   already deferred to 1.2. Make the deferral louder in the docs;
   right now the library code uses the syntax extensively which
   misleads users.

What I would **not** cut:

- The self-hosted MSIL pipeline. R1–R6 work has paid off — this is
  the right time to lock it in.
- The CST formatter. R2 deprecation notice has shipped; the
  per-expression CST granularity gap is small and tractable.
- Q022-1 / Q021-#4 (R5). Already shipped per D-progress-256.

---

## Theme 6 — Distribution strategy

### Finding 20 — Distribution channels are well-defined; signing is gated on real-world certificates (MEDIUM)

`docs/34-distribution-strategy.md` §2 enumerates: NuGet global tool
(primary), standalone ZIP/tarball (secondary), AOT binary (Phase 7).
`docs/22-distribution-and-tooling.md` covers the SDK layout. No
contradictions between the two.

`.github/workflows/publish.yml` exists and the release workflow is
documented in `docs/34` §7. The signing step is conditional on
repository secrets (`AZURE_KEY_VAULT_URL`, `APPLE_TEAM_ID`,
`NUGET_SIGNING_CERT_BASE64`). `docs/34` §7 explicitly:

> Signing steps are silently skipped if the corresponding secrets are
> absent. A release without signing is valid for developer previews;
> production releases targeted at enterprise deployments should have
> all secrets configured.

The signing-certificate-fingerprint table at `docs/34:283–290` shows
"`<pending — update when certificate issued>`" for all three
certificate types. So v1.0 will ship *unsigned* unless the
certificates are obtained between now and the tag.

**Recommendation:** This is a calendar / procurement task, not an
engineering one. Treat it as a release-blocker on the project-management
side: file an issue with a 6-week certificate-procurement
timeline (Azure Key Vault + Apple Developer + NuGet code-signing
certs), gated on legal review. If the certs don't arrive before the
tag, ship an unsigned 1.0 with an explicit security-warning section
in `README.md` and a documented 1.0.1 plan to add signatures.

### Finding 21 — Bootstrap reproducibility (G5) is correctly deferred but CI doesn't even run the script (LOW)

`scripts/bootstrap.sh` is the three-stage F# → self-hosted →
self-hosted² reproducibility check. G5 in `docs/36-v1-roadmap.md`
correctly defers byte-for-byte parity to Phase 7. But:

```
grep bootstrap.sh .github/workflows/ci.yml
→ (no hits)
```

The script is not exercised in CI at all. So even `--stage 1`
("compile Lyric packages with the F# emitter"; just validates that
self-hosted source files compile cleanly) does not run. The only
reason this works today is that the dispatcher fallback to
`bootstrapDispatch` is well-tested. But the moment a self-hosted
file has a compile regression that the existing F# test suite
doesn't catch, no signal fires.

**Recommendation:** Add the `--stage 1` invocation to `ci.yml` after
the test suite. It's a few minutes of CI time, no `STRICT_VERIFY`
required, and it catches the "Lyric.Cli.dll doesn't compile" class
of regression at PR time rather than at release-build time.

---

## Cross-cutting trade-off table

| Option | Pros | Cons |
|---|---|---|
| **Ship v1.0 with verifier-async unsoundness, document later** | Hits planned tag date | Permanent credibility damage; "safety-oriented" claim becomes a footnote |
| **Ship v1.0 with V0008 (reject `@proof_required` on async)** | Shippable in ≤ 1 week; honest scope; users get a diagnostic | Visible feature gap; needs a follow-up Phase-4 entry for proper async modelling |
| **Defer v1.0 until verifier handles async** | Most rigorous | Open-ended; async modelling is academic-paper territory |
| **Ship v1.0 with ecosystem libraries as "preview"** | Sharpens v1.0 story to compiler+stdlib; offloads ecosystem QA pressure | Loses the "batteries-included" angle that 24 libraries provide |
| **Ship v1.0 with full ecosystem, untested** | Maximum surface | First-week bug reports overwhelm any support channel; aspect inertness (F9) will surface immediately |
| **Centralise ecosystem QA pre-1.0** | Sustainable | Probably 3–6 months of work; misses any near-term v1.0 window |

---

## Final summary by severity

**CRITICAL (3):**
- F8: verifier silently ignores `async`/`yield` → vacuous proof discharge
- F12: 24 ecosystem libraries have zero tests
- F17/F19: cut path for v1.0 — recommend ecosystem-as-preview + V0008

**HIGH (4):**
- F4: `Lyric.SdkVersion` never enforced; version skew is undetected
- F9: `@inline_template` is parsed but unrecognised across 11 libraries
- F13: 24 libraries is premature given Phase 5 isn't done
- F15: 6+ ecosystem libraries lack book / language-reference coverage

**MEDIUM (6):**
- F2: bridge boilerplate duplicated across 12 SelfHosted shims
- F5: rollback story absent for `fmt`/`lint`/`doc`/`prove`/`restore`
- F7: contract-elaborator deferrals correctly fenced but understated
- F10: ecosystem stability annotations are partial
- F14: aspect adoption is too narrow to validate the design
- F18: non-obvious dependency between R4 sunset and contract-elaborator parity
- F20: code-signing certificates are not yet procured

**LOW (4):**
- F1: bridge shims are correctly thin (positive finding)
- F3: 5 bridges leak `$TMPDIR` scratch dirs
- F6: bridge cold-start cost (~3–5 s per bridge) is unmeasured
- F11: Q022-2/Q022-4/FFI phase-3 shapes have no SLA
- F16: `LYRIC_STRICT_SDK_VERSION` documented but not implemented
- F21: `bootstrap.sh` not exercised in CI

