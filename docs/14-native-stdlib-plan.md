# 14 — Native Stdlib Plan

> **Scope.** This document plans the migration of the Lyric standard
> library from "Lyric API surface backed by BCL types and an F# shim"
> (the current model in `docs/10-stdlib-plan.md`) to "Lyric API surface
> backed by Lyric implementations down to a small audited extern
> kernel." It is complementary to `10-stdlib-plan.md`, not a
> replacement: that doc owns *what* the stdlib offers; this doc owns
> *how deep* it is implemented in Lyric.
>
> **Status.** Draft. Several load-bearing decisions are unresolved and
> flagged in §10. Do not begin implementation work past §6 P0 until
> those are settled.

---

## 1. Motivation

Today, `compiler/lyric/std/*.l` (≈3500 lines) layers safe Lyric APIs
over `Lyric.Stdlib/Stdlib.fs` (≈1200 lines of F#) and `extern type`
declarations bound directly to BCL generics. The Lyric source is
mostly *syntactic* — it defines the surface (`Std.List[T]`,
`Std.HashMap[K, V]`, `Std.Sort`, `Std.Math.gcd`) but immediately
delegates to BCL implementations via `@externTarget` or BCL method
dispatch. The stdlib is "Lyric on top, BCL underneath."

Three forces push back on this model:

1. **Verification surface.** Lyric's distinguishing feature is
   contract-based reasoning (`docs/08-contract-semantics.md`).
   `@axiom`-marked extern targets are reasoning black boxes — the
   prover takes their behaviour on faith. A pure-Lyric `List[T]`
   carries `invariant: length >= 0 and length <= capacity` that the
   prover sees and uses. This matters for Phase 4.

2. **Range-subtype payoff.** A pure-Lyric `List[T]` can index using
   `Int range 0 ..= length - 1`, eliding bounds checks at compile
   time per `docs/01-language-reference.md` §2.7. The BCL indexer
   cannot — every call pays a runtime check. This is one of Lyric's
   distinguishing performance stories and we cannot tell it through
   wrapped BCL types.

3. **Self-hosting (Phase 5).** The bootstrap compiler will eventually
   be rewritten in Lyric. If its stdlib dependencies are BCL-wrapped,
   the rewrite either drags BCL types into the self-hosted compiler
   or reimplements stdlib at the same time. Doing the data structures
   in Lyric earlier de-risks Phase 5.

Counter-pressure:

- BCL types are battle-tested and tuned. A naive port will be slower.
- Some surfaces (`Math.Sin`, `String.Format`, regex, JSON, HTTP,
  cryptography, datetime) have no realistic pure-Lyric reimplementation
  and must remain extern forever.
- Self-imposed scope. A native stdlib expansion competes with Phase 2
  type-system work and Phase 3 v1.0 polish for the same engineering hours.

The resolution: **rebuild a defined kernel of the stdlib in Lyric,
keep an explicit, audited extern surface for everything that
fundamentally cannot move, and treat the boundary as a first-class
verification artefact.**

---

## 2. Definitions

| Term | Meaning |
|---|---|
| **Native module** | A stdlib module whose implementation is pure Lyric (modulo a transitive dependency on the extern kernel). |
| **Extern kernel** | The fixed, small set of `@externTarget` declarations that bottom out at the BCL. Audited. `@axiom`-marked. |
| **Wrapper module** | A stdlib module that today is a thin Lyric API over BCL types, slated for native rebuild or for retention as a wrapper. |
| **Boundary primitive** | A language-level primitive (e.g., `newSlice[T](n)`) the compiler must provide before a native module can be expressed. |
| **`Std.Bcl.*`** | Proposed namespace housing residual BCL-typed escape hatches for users who explicitly want raw BCL access. |

---

## 3. The extern kernel (what stays extern forever)

The kernel is the floor. Every language has one (Rust's `std` calls
`libc`; Java's calls JNI). Lyric's kernel is:

| Surface | Why it cannot move | Approx. extern count |
|---|---|---|
| Console / file / network / process / time syscalls | Syscalls. No language can replace these. | ~30 methods |
| `System.Math` transcendentals (`Sin`, `Cos`, `Log`, `Exp`, `Sqrt`, `Pow`) | Implementing in Lyric is possible (Taylor / CORDIC) but pointless: BCL ships hardware-tuned forms; matching them is a research project. | ~20 methods |
| Regex engine | A correct, performant regex implementation is a multi-year project. Vendor BCL `System.Text.RegularExpressions`. | ~10 methods |
| JSON tokenizer | Implementable in Lyric eventually, but `System.Text.Json`'s SIMD-tuned tokenizer is a perf cliff we don't want to fall off. Source generators (`@derive(Json)`) keep most users out of the tokenizer anyway. | ~15 methods |
| Cryptography primitives | Audit cost. Use BCL `System.Security.Cryptography`. | ~10 methods |
| HTTP transport (TLS, connection pool) | Same. Use BCL `System.Net.Http`. | ~15 methods |
| Threading / Task scheduler | Lyric uses .NET TPL by D001. The scheduler stays. | ~10 methods |
| String parsing of `Double` / `Decimal` | Correct float parsing is a research-grade problem (Bellerophon, Eisel-Lemire). Use BCL `Double.TryParse`. | 5 methods |

**Target kernel size:** ≤120 extern declarations, all in
`compiler/lyric/std/_kernel/*.l`, all `@axiom`-marked, all
hand-audited at every release. This replaces the ad-hoc shim surface
of `Lyric.Stdlib/Stdlib.fs` with a structured boundary.

**Non-goals.** No goal of "zero externs." Anyone shipping a Lyric
program is implicitly trusting the .NET runtime; pretending otherwise
is a lie.

---

## 4. Language gaps that gate native modules

These are the boundary primitives. Each is a small piece of compiler
work. They are roughly ordered by leverage.

### 4.1 P0 (gating). Required to start.

#### G1. Dynamic-size slice allocation

```
func newSlice[T](length: in Int): slice[T]   // intrinsic
  requires: length >= 0
  ensures: result.length == length
```

Lowers to MSIL `newarr` (`Codegen.fs:945` already emits this for list
literals; lift to a callable intrinsic). Without this, no growable
container can be expressed in Lyric. Smallest change with highest
leverage. **Estimated effort: 1-2 days.**

#### G2. Slice copy intrinsic

```
func copySlice[T](src: in slice[T], srcStart: in Int,
                  dst: inout slice[T], dstStart: in Int,
                  count: in Int): Unit
  requires: srcStart >= 0 and srcStart + count <= src.length
  requires: dstStart >= 0 and dstStart + count <= dst.length
```

Lowers to `Array.Copy`. Needed for `List.add` resize and any
`String`/`StringBuilder`-shaped buffer. Without it, growing a
container is O(n²) (element-by-element loop). **Estimated effort:
1 day.**

#### G3. Generic `where` clauses with the D034 marker set

`docs/03-decision-log.md` D034 closes the marker set at `Equals`,
`Compare`, `Hash`, `Default`, `Copyable`, `Add`, `Sub`, `Mul`, `Div`,
`Mod`. The Phase 1 implementation explicitly defers `where` clause
support (`docs/05-implementation-plan.md` §"Language subset for
Phase 1"). Lifting that deferral is the gating work for **all** of:
`HashMap[K, V]`, `Sort`, generic `min`/`max`, `Set[T]`, and any
generic algorithm that needs to compare or hash.

The needed sub-features:

- Type checker accepts and validates `where T: Hash + Equals` clauses.
- Monomorphisation can emit specialized methods that dispatch to the
  appropriate constraint method (`T.hash(x)`, `T.equals(a, b)`).
- Built-in primitive types (`Int`, `Long`, `String`, …) auto-satisfy
  `Hash`, `Equals`, `Compare`, `Default` per D034.

**Estimated effort: 2-3 weeks.** The single largest gating item.

### 4.2 P1 (high leverage but not gating).

#### G4. UTF-16 code-unit access on `String`

Today `s[i]: Char` works (Char is the U+00xx-aware type). For native
hashing, parsing, and Unicode normalization we want a primitive
`s.codeUnit(i): UShort` (the raw `char` underneath, no UCS interpretation).
**Estimated effort: 2-3 days.**

#### G5. `inout slice[T]` element write through indexed assignment

`xs[i] = v` for `var xs: slice[T]` should already work; needs
verification that `inout` parameters carry the slice reference
correctly. Audit + tests; no new feature if it already works.
**Estimated effort: 1 day audit, up to 1 week if it doesn't.**

### 4.3 P2 (unlocks specific modules; not blocking on P0/P1).

#### G6. Iterator protocol

A native `Std.Iter` that doesn't materialize a `slice[T]` for every
combinator (`map`, `filter`, `take`, `chain`) needs an `Iterator[T]`
interface or a yield-style coroutine. Today's `Std.Iter` is
slice-allocating, which is fine for correctness but bad for perf on
long pipelines. **Estimated effort: 2 weeks (interface form) or 6+
weeks (coroutine form).** Coroutine form is Phase 3-shaped work.

#### G7. `protected type` (Phase 3 work, already planned)

Required for native `Mutex`, `AtomicInt`, `SyncQueue`, anything
shared-mutable. Already on the roadmap; native stdlib piggy-backs
on it. **No incremental cost.**

### 4.4 Out of scope for this plan

- Async state machine (D035 documents the bootstrap shim; full lowering
  is Phase 4 work). Native concurrency primitives wait for it.
- Reflection. Permanently rejected (`docs/04-out-of-scope.md`).
- Inline assembly, intrinsics beyond what is enumerated here.

---

## 5. Module-by-module plan

| Module | Today's status | Native target | Gating | Notes |
|---|---|---|---|---|
| `Std.Core` (Option, Result) | Native already | — | — | ✅ Already done. |
| `Std.Iter` (slice-allocating) | Native already | — | — | ✅ `forEach`, `fold`, `map`, `filter`, etc. are pure Lyric. May want G6 perf upgrade in Phase 3. |
| `Std.Errors` | Native already | — | — | ✅ Sum types. |
| `Std.Math` (integer ops) | Extern wrappers (`absInt`, `min`, `max`, `gcd`, …) | Native | — | Trivial: write inline. `gcd`, `lcm`, `pow_int` are 5-line functions. |
| `Std.Math` (transcendentals) | Extern | **Stays extern** | — | Kernel item per §3. |
| `Std.String` (algorithmic: `repeat`, `join`, `split-on-char`, `compare`) | Some native, some BCL dispatch | Native | G4 for hashing-shaped ops | Most pure-algorithm parts are already Lyric. |
| `Std.String` (BCL dispatch: `toUpper`, `trim`, `indexOf`) | BCL | **Stays BCL kernel** | — | Unicode-correct string ops are BCL responsibility. |
| `Std.List[T]` (growable list) | `extern type List[T] = "System.Collections.Generic.List`1"` | Native | G1, G2 | The flagship migration. ~150 LoC native. |
| `Std.HashMap[K, V]` | `extern type Map[K, V]` | Native | G1, G2, G3 | ~300 LoC. Needs `where K: Hash + Equals`. |
| `Std.Set[T]` | extern | Native | Same as HashMap | Built on HashMap. |
| `Std.Queue[T]`, `Std.Stack[T]` | not yet | Native | G1, G2 | Built on `Std.List[T]`. |
| `Std.Sort` (slice in-place) | not yet | Native | G3 | Quicksort with insertion-sort cutoff. ~80 LoC. |
| `Std.Parse` (`tryParseInt`, `tryParseLong`) | F# shim (`Parse.fs`) | Native | — | Doable today on `String` + arithmetic. ~50 LoC each. Float parsing stays kernel. |
| `Std.Hash` | F# shim implicit | Native primitives + native FNV/Murmur for byte slices | G4 | Per-primitive hashes are 1-line; byte-slice hashes are real Lyric. |
| `Std.Format` (`String.Format`-shaped) | F# shim (`Format.Of1..6`) | Native | — | Drop the F# shim; implement template parsing in Lyric. ~120 LoC. |
| `Std.Json` (parser) | extern (`System.Text.Json`) | **Stays kernel** | — | See §3. |
| `Std.Json` (encoder for `@derive(Json)`) | F# shim (`JsonHost.Render*`) | Native | — | Just buffer concatenation; pure Lyric is fine. |
| `Std.Regex` | extern | **Stays kernel** | — | Per §3. |
| `Std.Console`, `Std.File`, `Std.Directory`, `Std.Path`, `Std.Time`, `Std.Random` | extern wrappers | **Surface stays Lyric, kernel calls are extern** | — | The Lyric-side `Result`-returning wrappers are already native. The host call below is kernel. |
| `Std.Http`, `Std.HttpServer` | extern wrappers | **Same** | — | TLS / connection pool stays kernel. |
| `Std.Task`, `Std.Cancellation` | extern (`System.Threading.Tasks`) | **Stays kernel** | — | TPL by D001. |
| `Std.Logging` | extern wrappers | Mixed | — | Sink dispatch native; OS / file destination kernel. |

**Total LoC estimate for new native code:** ~1500-2000 LoC of Lyric.
**Total LoC removed from F# shim:** ~600-800 LoC of `Stdlib.fs`.

---

## 6. Phasing

### P0. Pre-work (1 sprint)

No language changes. Doable today.

1. ✅ **Move trivial `@externTarget` math wrappers to native Lyric.**
   `absInt`, `min`/`max`, `gcd`, `lcm`. ~100 LoC. *(PR #68.)*
2. ✅ **Remove obsolete monomorphic shims.** Deleted `IntList`,
   `StringList`, `LongList`, `StringIntMap`, `StringStringMap` from
   `Stdlib.fs`. ~89 LoC removed. *(PR #70.)*
3. 🟡 **Convert trivial `Console.Println` / `Print` / `Format.Of1..6` to
   `@externTarget` declarations.** *(PR #71 covered the Console arms;
   `Format.Of1..6` deferred to a follow-up because the emitter would need
   to pack `object[]` for arity 4-6.)*
4. ✅ **Establish `compiler/lyric/std/_kernel/*.l`** as the audited
   extern boundary. Move every `@externTarget` declaration into this
   subdirectory. Add a CI lint that rejects new `@externTarget`s
   outside `_kernel/`.
   * **P0/4a (PR #73):** directory created, four already-pure-extern
     files (`environment_host`, `http_host`, `log_host`, `time_host`)
     moved. File-discovery in `Emitter.fs`, `Cli/Program.fs`, and
     `StdlibSeedTests.fs` updated to recurse and prefer top-level on
     collision.
   * **P0/4c (PR #79):** ratchet test
     `KernelBoundaryTests.fs` enforces "extern declarations outside
     `_kernel/` never grow" (started at 139 — the ceiling drops as
     migrations land) and reports the total against Decision F's
     soft cap of 150 (becomes hard at v1.0).
   * **P0/4b batch 1 (PR #81):** `io.l`, `parse.l`, `testing_mocking.l`,
     `regex.l`, `random.l`, `http_server.l` migrated. Ratchet 139 → 103.
   * **P0/4b batch 2 (PR #83):** `math.l` and `time.l` split into
     native trampolines (`math.l`, `time.l`) and
     `_kernel/{math,time}_host.l`. Ratchet 103 → 44.
   * **P0/4b batch 3 (PR #86):** `json.l` split, `task.l` moved.
     Ratchet 44 → 5.
   * **P0/4b finale (PR #93):** `collections.l` migrated.
     `extern type List[T]`, `Map[K, V]` and their constructors plus
     `tryGetValue` move to `_kernel/collections_host.l`. Required
     two compiler fixes — both in `Lyric.Emitter/Emitter.fs`:
     (a) the artifact compiler's typechecker now sees a transitive
     closure of stdlib deps' items, so iter.l (which imports
     `Std.Collections`) sees `List[T]` from `Std.CollectionsHost`;
     (b) selector-alias resolution now walks across all loaded
     artifacts, so `import Std.Collections.{newList as mkList}`
     keeps working even though `newList` actually lives in the
     kernel package. **Ratchet 5 → 0.** Q022 partially resolved
     (the practical blocker is gone; `pub use` proper and opaque
     wrapping with generic params remain as language work for
     future stdlibs).
5. ✅ **Document the kernel** in `compiler/lyric/std/_kernel/README.md`
   plus the §3 / §6 sections of this doc. Cross-references to the
   decision log (D038) and open-questions doc (Q022) in place.

**Exit criterion:** F# `Stdlib.fs` shrinks by ≥30%; all remaining
externs are concentrated in `_kernel/`. No new language features
required.

### P1. Boundary primitives (3-4 sprints)

Land G1, G2 (P0 gating items in §4.1) plus G4 audit. **Decision A**
(see §10) determines whether G3 (`where` clauses) lands here or in
P2.

**Exit criterion:** `newSlice[T](n)`, `copySlice[T]`, and indexed
slice writes are tested end-to-end. No native modules ship yet.

### P2. Native containers, sort, hash (4-6 sprints)

Land G3 if not already done. Then:

1. `Std.List[T]` native, with full contract surface
   (`length >= 0`, `length <= capacity`, capacity-doubling resize).
   Replace `extern type List[T]`.
2. `Std.HashMap[K, V]` native (open addressing or chaining —
   **Decision B**).
3. `Std.Set[T]` native (built on HashMap).
4. `Std.Sort.sort[T] where T: Compare` native (introsort or
   pdqsort-lite).
5. `Std.Queue[T]`, `Std.Stack[T]` native.
6. `Std.Hash` for primitives + native FNV-1a for byte slices.

**Exit criterion:** All of `Std.List`, `Std.HashMap`, `Std.Set`,
`Std.Sort`, `Std.Hash` ship without depending on
`System.Collections.Generic.*` types. Benchmarks added (see §8).

### P3. Native parsing + format (2-3 sprints)

1. `Std.Parse.tryParseInt`, `tryParseLong` native. Float parsing stays
   kernel.
2. `Std.Format` template engine native. Delete `Format.Of1..6` from
   `Stdlib.fs`.
3. `Std.Json` encoder native (the writer half; tokenizer stays).

**Exit criterion:** `Stdlib.fs` is reduced to the kernel surface
defined in §3.

### P4. Iterator protocol overhaul (Phase 3 alongside `protected type`)

G6: real iterator interface with non-allocating combinators. Major
work, properly Phase-3-shaped. Out of scope for this plan past flag
status.

---

## 7. Validation strategy

The native stdlib is only useful if its semantics match users' (and
the prover's) expectations. Three layers of validation:

1. **Property-based parity tests.** For each native module that
   replaces a BCL surface (`List[T]`, `HashMap[K, V]`, `Sort`),
   run the same operation sequence on the native impl and the BCL
   impl, assert equivalent results. Property tests live in
   `compiler/tests/Lyric.StdlibParity.Tests/` (new project).
2. **Contract assertions.** Every native data structure declares its
   invariants and runtime-checks them in `@runtime_checked` mode.
   Contract failures during parity testing are a parity bug.
3. **Microbenchmarks.** A perf budget per native module
   (**Decision C** sets the budget). Regressions block merge.
4. **Proof obligations** (Phase 4). Native data structures' invariants
   become proof targets. `BCL`-backed types remain `@axiom`-marked.
   This is the long-term verification payoff.

---

## 8. Performance targets

Native pure-Lyric implementations will not match heavily-tuned BCL
generics on the first cut. **Decision C** sets the contract; here are
the candidate budgets:

| Operation | Reasonable target vs. BCL | Aggressive target |
|---|---|---|
| `List.add` (amortised) | 3× | 1.5× |
| `List` indexed read (with range subtype) | 0.8× (we beat BCL because no bounds check) | 0.5× |
| `HashMap.get` (hit) | 4× | 2× |
| `HashMap.put` (insert) | 5× | 2.5× |
| `Sort` (random Int slice, 100k) | 2.5× | 1.5× |
| `Std.Math.gcd` | 1× | 1× |
| Native `tryParseInt` | 2× | 1.5× |

The "reasonable target" column is what we should accept for v1.0.
Tighter ratios mean optimisation work the user (you) is signing up
for.

---

## 9. Compatibility, naming, migration

Two routes for the user-facing names:

- **Route A (replace).** `Std.List[T]` is the native impl. The old
  `extern type List[T]` either disappears or moves to `Std.Bcl.List[T]`
  for explicit BCL access. Cleaner; some breaking changes for early
  adopters.
- **Route B (versioned).** Native gets a different name: `Std.LyricList[T]`
  / `Std.NativeList[T]`. Original `Std.List[T]` keeps wrapping BCL.
  Two implementations forever. Avoids breakage.

**Decision D** (see §10) picks one. The author of this doc recommends
**Route A**: a v1.0-shaped language is allowed to break a few names
in pre-release, especially when the swap is a strict improvement on
verifiability and perf headroom.

---

## 10. Decisions (resolved)

All seven decisions resolved on 2026-05-03; see `docs/03-decision-log.md`
D038 for the umbrella record. Resolutions reproduced inline.

| ID | Resolved | Summary |
|---|---|---|
| **A** | **A1** | Land G3 (`where` clauses) before any native module work. P0 cleanup proceeds independently; P2 (containers/sort/hash) waits for G3. |
| **B** | **B2** | HashMap uses chaining for the first cut. Revisit B1 (open addressing) in Phase 3 if benchmarks demand. |
| **C** | **C1** | "Reasonable" perf budget — §8 "Reasonable target" column (~2-5× BCL). Verifiability and self-hosting are the wins; peak perf is not the differentiator. |
| **D** | **A (replace)** | Native impl takes the canonical name (`Std.List[T]`); raw BCL access available via `Std.Bcl.List[T]` for users who explicitly want it. Pre-1.0 breakage is acceptable. |
| **E** | **E1** | Decision log entry D038 added. **Q021** opened in `docs/06-open-questions.md` for G3 specifically; G1/G2/G4 stay tracked in this doc as pure compiler work. |
| **F** | **150** | Hard cap of 150 extern declarations. Treated as a v1.0 release gate. Expansion past 150 requires this doc to be amended. |
| **G** | **P0 then G3** | Begin P0 immediately (no language changes required). G3 work begins in parallel with P0's last steps so it lands before P1's primitives consume it. |

### Resolved order of operations

1. **P0 (now)** — cleanup + `_kernel/` reorganisation. No language changes. See §6 P0.
2. **G3** — `where`-clause support with the D034 marker set. Begins toward end of P0; tracked as Q021.
3. **P1** — boundary primitives G1, G2, G4 (G3 already landed in step 2).
4. **P2** — native containers, sort, hash, all relying on G3.
5. **P3, P4** — as §6.

---

## 11. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Native `HashMap` has subtle bug under load | High | High | Property-based parity tests vs. BCL `Dictionary` (§7) |
| Native containers ship with surprise perf cliff | Medium | Medium | Microbenchmarks gated in CI per Decision C |
| `where` clause work (G3) takes longer than estimated | Medium | High | A1 path keeps P0 cleanup independent of G3 |
| Native impl loses `@runtime_checked` parity with BCL semantics (e.g., null handling, ordering stability) | Medium | High | Spec each module's behaviour explicitly in `docs/10-stdlib-plan.md`; parity tests |
| Self-hosting goal slips and we never reap the verification benefits | Low | Low | Native modules are independently valuable for contract reasoning today |
| Scope creep: every BCL type becomes a candidate for native | Medium | High | The kernel list in §3 is the boundary; expansion requires this doc to be amended |

---

## 12. Out of scope for this plan

- Concrete lowerings for any specific G-item beyond what §4 sketches
  (the emitter team owns those).
- Phase 4 proof-system integration. The native stdlib feeds it; the
  proof work itself is `docs/05-implementation-plan.md` Phase 4.
- Migration paths for downstream Lyric users. None exist yet; we're
  pre-1.0.

---

## 13. References

- `docs/10-stdlib-plan.md` — API surface plan (this doc's sibling).
- `docs/05-implementation-plan.md` — phasing.
- `docs/03-decision-log.md` — D034 (constraint markers), D035 (M1.4
  scope cuts including the F# shim's bootstrap-grade status), D038
  (this plan's umbrella decision).
- `docs/06-open-questions.md` Q021 — `where`-clause activation
  (the G3 gating item).
- `docs/09-msil-emission.md` — the lowering rules the boundary
  primitives in §4 will follow.
- `docs/04-out-of-scope.md` — reflection rejection (relevant to why we
  can't auto-derive `Hash`/`Equals` via reflection).
- `docs/06-open-questions.md` Q011 — the "stdlib API surface" question
  this plan partly addresses.
