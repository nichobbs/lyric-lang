# 35 — JS Ecosystem Integration via WASM Component Model (sketch)

**Status:** Unbacked sketch. Design tensions are unresolved; see §11 for the
open questions that must be settled before implementation begins.
**Builds on:** `docs/14-native-stdlib-plan.md` (extern kernel pattern),
`docs/21-nuget-linking.md` (dependency table and shim model),
`docs/09-msil-emission.md` (target model), `docs/18-jvm-emission.md`
(multi-target precedent).
**Decision-log entry:** to follow once §11 tensions are resolved.
**Goal:** Allow (A) JS-first teams to consume Lyric libraries as ordinary
NPM modules and (B) Lyric programs to call NPM packages via declared
host imports — without sacrificing Lyric's safety properties inside the
WASM boundary.

---

## 1. Motivation

Lyric's primary deployment targets are .NET and JVM. For the language to
expand its community it needs to be accessible to JS-first engineering
teams in two directions:

**Direction A — Lyric as a library for JS.** A team using Node, Deno, or
Bun should be able to `npm install @myorg/mypackage` and call Lyric-authored
code from TypeScript without knowing Lyric exists, without a .NET or JVM
runtime on the server, and without giving up Lyric's safety properties inside
the library.

**Direction B — NPM packages from Lyric.** A Lyric author should be able to
reach the NPM ecosystem — `node-fetch`, `@aws-sdk/client-s3`, database
drivers — without waiting for a Lyric-native or .NET equivalent to exist.

Transpilation to TypeScript was considered and rejected as the primary
mechanism. The safety properties that differentiate Lyric — opaque type
boundaries, range subtypes, verified contracts — dissolve in TS output
where the type system is structural and reflection is pervasive. The TS
output would market the Lyric safety story while silently not delivering it.

The WASM Component Model (`wasm32-wasi` + WIT) is the correct abstraction:

- WASM enforces the encapsulation boundary structurally. JS callers cannot
  inspect a WASM module's internal memory; opaque types are genuinely opaque.
- WIT (WebAssembly Interface Types) has a type vocabulary — `record`,
  `variant`, `option<T>`, `result<T, E>`, `list<T>`, `future<T>` — that maps
  cleanly to Lyric's `exposed record`, union types, `Option`, `Result`,
  `List`, and `Async`.
- The `jco` toolchain generates TS/JS bindings from WIT automatically.
  JS consumers get a typed NPM module; Lyric's implementation is invisible.
- .NET already has experimental WASI support
  (`dotnet publish -r wasi-wasm`), giving the Foundation a plausible path
  that does not require writing a new backend from scratch in Phase 1.

This document is not a commitment to a WASM target in any specific phase. It
is a pressure-test sketch to surface tensions before anyone starts coding.

---

## 2. Scope of this sketch

In scope:
- WIT generation from Lyric's `exposed` type surface (§4).
- CLI and `lyric.toml` extensions for the WASM component target (§5).
- The `[npm]` dependency table and NPM extern shim model (§6, §7).
- The degraded-semantics policy for Lyric features without WASM equivalents
  (§8).
- Async lowering for the WASM target (§9).
- Open questions that block implementation (§11).

Out of scope:
- Browser packaging, bundlers, or JS tree-shaking (different use case;
  see §10).
- A full WASM emitter replacing the .NET AOT WASM approach (could be a
  later Phase 6 follow-on; §10).
- Hot reload, REPL, or debugger integration in WASM.
- WasmGC — the newer W3C proposal for GC-typed references in WASM. This
  is the right long-term backend for a standalone WASM emitter, but the
  tooling is immature. Defer to a separate sketch when WasmGC stabilises.

---

## 3. Why not transpile to TypeScript?

A TS transpilation target is simpler to build and has been requested. It
is not the primary mechanism for two structural reasons:

1. **Safety properties dissolve.** TypeScript's type system is structural.
   `opaque type UserId` becomes a branded string; any TS cast defeats it.
   `protected type` semantics have no JS equivalent. Range subtypes become
   runtime checks with no type-level enforcement. Contracts survive as
   runtime asserts but the `@proof_required` story is meaningless.

2. **Semantic confusion.** Developers who encounter Lyric-as-TS and then
   encounter the .NET version will find different semantics at the boundary.
   That undermines trust in the language and confuses the community story.

A TS transpilation target could be justified as an explicitly-degraded
"scripting/tooling" output (e.g., building Lyric-authored CLI tools that
ship as JS without a WASM runtime). That is a separate, narrower use case
and should be tracked as a distinct sketch if appetite exists.

---

## 4. WIT generation from Lyric types

WIT is the interface language for the WASM Component Model. `lyric build
--target wasm-component` generates a `.wit` file alongside the `.wasm`
binary. The WIT surface is derived from the package's `pub` declarations
whose types are entirely in the `exposed` tier.

### 4.1 Type mapping

| Lyric type | WIT type | Notes |
|---|---|---|
| `Bool` | `bool` | |
| `Int` | `s32` | |
| `Long` | `s64` | |
| `Float` | `f32` | |
| `Double` | `f64` | |
| `String` | `string` | |
| `Unit` | (no return type) | WIT functions with no output |
| `Option[T]` | `option<T>` | direct |
| `Result[T, E]` | `result<T, E>` | direct |
| `List[T]` | `list<T>` | |
| `exposed record Foo` | `record foo { ... }` | fields mapped recursively |
| Union type (sum) | `variant` | each constructor becomes a case |
| `Async[T]` | `future<T>` | see §9 |
| `opaque type T` | — | not exported; only the `@projectable` exposed twin appears |
| `protected type T` | — | not exported; see §8.1 |
| Range subtype (e.g., `Int range 0..=150`) | underlying type (`s32`) with contract guard | see §8.2 |
| Generic `T` | `T` (WIT type parameter) | only on WIT-exportable functions |

Types that do not appear in the table (function types, first-class module
references, `inout` parameters in complex positions) are not WIT-exportable.
The compiler emits a diagnostic for each `pub func` whose signature cannot
be lowered to WIT and excludes that function from the generated `.wit` file.
This is informational (`W0040`), not an error.

### 4.2 Example

```lyric
// billing.l
@projectable
pub opaque type InvoiceId = Long

pub exposed record Invoice {
    pub id: InvoiceId,
    pub amount_cents: Long
}

pub func create(in customer_id: String, in cents: Long): Result[Invoice, String] = ...
```

Generates:

```wit
package lyric:billing@1.0.0;

interface billing {
  type invoice-id = s64;

  record invoice {
    id: invoice-id,
    amount-cents: s64,
  }

  create: func(customer-id: string, cents: s64) -> result<invoice, string>;
}

world billing-world {
  export billing;
}
```

WIT naming follows kebab-case per the Component Model convention.
Lyric's snake_case identifiers map to kebab-case automatically.
PascalCase type names map to kebab-case (`InvoiceId` → `invoice-id`).

### 4.3 Generated JS bindings

Running `jco transpile billing.wasm --wit billing.wit` produces a TypeScript
module:

```typescript
export interface Invoice { id: bigint, amountCents: bigint }
export function create(customerId: string, cents: bigint): Invoice | string;
```

JS consumers see idiomatic TypeScript. The Lyric + WASM implementation is
invisible to them.

---

## 5. CLI and `lyric.toml` extensions

### 5.1 CLI

```
lyric build --target wasm-component [--wit-out <path>] [--js-bindings]
```

| Flag | Default | Meaning |
|---|---|---|
| `--target wasm-component` | — | Emit a WASM component + WIT instead of a .NET DLL |
| `--wit-out <path>` | `target/wasm/<pkg>.wit` | Where to write the generated WIT file |
| `--js-bindings` | off | Also invoke `jco transpile` to produce TS/JS bindings alongside the `.wasm` |

`lyric publish --target wasm-component` bundles the `.wasm` + WIT + generated
bindings as an NPM-compatible package tarball, analogous to how `lyric
publish` produces a NuGet-style DLL bundle.

### 5.2 `lyric.toml` extensions

```toml
[wasm-component]
world   = "billing-world"        # WIT world name; defaults to "<package-name>-world"
exports = ["billing", "users"]   # which interface sections to include; default: all eligible pub interfaces

[npm]
"node-fetch"            = "^3"
"@aws-sdk/client-s3"   = "^3.600"
```

| Field | Default | Meaning |
|---|---|---|
| `[wasm-component]` | empty | Present only if the project targets WASM component output |
| `world` | `<package>-world` | WIT world identifier |
| `exports` | all eligible | Subset of interfaces to export if not everything should be public |
| `[npm]` | empty | NPM package dependencies for Direction B (§6) |

---

## 6. Direction B: NPM dependency table (`[npm]`)

`[npm]` in `lyric.toml` declares NPM package dependencies, analogous to
`[nuget]` for .NET packages. The model parallels §§3–4 of
`docs/21-nuget-linking.md` with adaptations for the JS toolchain.

```toml
[npm]
"node-fetch"          = "^3"
"@aws-sdk/client-s3" = "^3.600"
"zod"                 = "^3.22"

[npm.options]
registry = "https://registry.npmjs.org/"   # default
```

`lyric restore` invokes `npm install` (or the user-configured package
manager: `pnpm`, `yarn`) into a `target/npm/node_modules/` directory and
generates extern shim files (§7) for each declared package.

---

## 7. NPM extern shim files

For each `[npm]` entry, `lyric restore` generates a
`_extern_npm/<pkg>.l` file declaring the NPM package's callable surface
in Lyric types. These files are:

- **Committed to the source tree** — reviewers see the imported surface in
  diffs when a dep is added or upgraded. Same policy as NuGet shims.
- **Marked `@axiom`** — NPM packages are unverified host code. The
  `@axiom` annotation places them in the same trust tier as
  `_kernel/*.l` files. Contract reasoning takes their declared behaviour
  on faith.
- **Manually authored in v1** — unlike NuGet shims (which can be
  auto-generated by reflecting on .NET DLLs), NPM packages have no
  machine-readable type signatures beyond TypeScript `.d.ts` files.
  In v1, maintainers author extern declarations by reading the `.d.ts`.
  A future `lyric restore --generate-npm-shims` could automate this
  by translating `.d.ts` to Lyric extern declarations.

### 7.1 Example shim

```lyric
@axiom("from npm node-fetch ^3")
package NodeFetch

@externTarget("npm", package: "node-fetch", symbol: "default")
pub extern func fetch(in url: String): Async[Result[Response, FetchError]]

pub exposed record Response {
    pub status: Int,
    pub ok: Bool
}

pub exposed record FetchError {
    pub message: String
}
```

Consumers write:

```lyric
import NodeFetch.{fetch, Response}

async func loadUser(in id: String): Result[Response, FetchError] =
    fetch("https://api.example.com/users/" + id) await
```

### 7.2 Naming convention

NPM package names map to Lyric package identifiers as follows:

| NPM name | Lyric package name |
|---|---|
| `node-fetch` | `NodeFetch` |
| `zod` | `Zod` |
| `@aws-sdk/client-s3` | `AwsSdk.ClientS3` |
| `@types/node` | `Types.Node` |

Rules: strip `@`; replace `/` with `.`; convert each segment to PascalCase
(split on `-`, `_`). The mapping is deterministic and documented in each
shim's header comment.

### 7.3 Diagnostic codes

| Code | Meaning |
|---|---|
| `B0040` | NPM package failed to install (`npm install` non-zero exit) |
| `B0041` | NPM package declared in `[npm]` but no shim file found in `_extern_npm/`; run `lyric restore` |
| `B0042` | Shim file references a symbol not present in the installed package version |
| `B0043` | `@axiom`-annotated shim was hand-edited to remove the annotation; restore refused |

---

## 8. Degraded-semantics policy

Several Lyric features have no direct WASM or JS equivalent. This section
defines the policy for each. The policy options are:

- **(A) Compile error** — reject the construct on the WASM target explicitly.
- **(B) Runtime approximation** — emit a best-effort equivalent with a
  documented caveat.
- **(C) Silent strip** — emit nothing; the feature disappears silently.

Silent stripping (C) is never correct. Every case is either a compile error
or a documented approximation.

### 8.1 `protected type`

**Policy: (A) Compile error.**

`protected type` is Lyric's structural mutual-exclusion primitive. Its
semantics depend on OS threads or async tasks competing for shared state.
WASM's default execution model is single-threaded (one linear memory, one
call stack); WASM threads via `SharedArrayBuffer` exist but are a separate,
opt-in capability with significant restrictions.

Exporting a `protected type` as part of a WASM component's interface is
rejected with a clear error:

```
E0050: `protected type Ledger` cannot appear in a wasm-component export
       surface. Protected types require OS thread semantics unavailable
       in single-threaded WASM. Consider exposing a non-protected facade
       record with explicit locking at the host boundary.
```

Internal use of `protected type` within a WASM module (not at the export
surface) is an open question (Q-JS-001, §11).

### 8.2 Range subtypes

**Policy: (B) Runtime approximation, documented.**

Range subtypes (`type Age = Int range 0..=150`) have no WIT type-level
representation. They map to their underlying WIT primitive (`s32`). The
range invariant is checked at the WASM export boundary: entering the
component with a value outside the declared range triggers a contract
failure (same as a `requires:` violation in `@runtime_checked` mode).

The WIT-generated TS binding adds a JSDoc comment noting the valid range.
No type-level enforcement exists on the JS side.

### 8.3 `@proof_required`

**Policy: (B) Runtime approximation — silently downgraded to
`@runtime_checked` for WASM target builds.**

SMT verification is a compile-time property of the .NET or JVM build. It
does not affect the emitted WASM binary. On the WASM target, all modules
are treated as `@runtime_checked`; contracts are emitted as runtime asserts.

A `--strict` flag (Q-JS-003, §11) could optionally make this a compile
error if the team wants a hard guarantee that `@proof_required` code never
ships to an unverified target.

### 8.4 Opaque types at the WASM boundary

**Preserved.** Opaque types do not appear in the WIT surface. JS callers
interact only with their `@projectable` exposed twins. The internal
representation is inaccessible to JS — the WASM sandbox enforces this
structurally, not by convention. This is the primary advantage of WASM over
transpile-to-TS.

### 8.5 No-reflection guarantee

**Preserved** for the Lyric implementation inside the WASM sandbox. JS
callers outside the sandbox are subject to JS semantics (they can reflect
on JS values). The WIT boundary types (records, variants) cross into JS as
plain JS objects and are fully inspectable by JS code. This is documented
and expected: the boundary types are `exposed` record twins, not opaque
types.

---

## 9. Async lowering for the WASM target

The bootstrap compiler currently lowers `async func` to blocking
`.GetAwaiter().GetResult()` (a bootstrap-grade shim; see `docs/03-decision-log.md`
D035). This is not acceptable for a WASM target where blocking the event
loop is either forbidden or harmful.

On the WASM target, `async func` must emit proper WASM async:

- Lyric `Async[T]` → WIT `future<T>`.
- `jco` generates a JS async function returning `Promise<T>` from the
  WIT `future`.
- Internal `await` inside Lyric WASM code → WASM async lift/lower
  primitives per the Component Model async proposal.

This requires the self-hosted emitter to implement a real async lowering
pass. The bootstrap F# emitter's blocking shim is not a path here. The
WASM component target therefore gates on the self-hosted emitter having a
proper async story — this aligns it with Phase 5/6 rather than Phase 1.

---

## 10. Out of scope

- **Browser packaging.** `lyric build --target wasm-component` emits a
  WASM component; bundling for the browser (webpack, Vite, Rollup) is the
  JS developer's concern. We provide the `.wasm` + WIT + optional TS
  bindings; we do not own the bundler integration.
- **WasmGC backend.** WasmGC (W3C proposal for GC-typed references in WASM)
  is the correct long-term path for a standalone WASM emitter that does not
  depend on .NET AOT WASM. It requires a new backend. Defer to a separate
  sketch when the WasmGC toolchain matures (currently landing in V8/SpiderMonkey
  but tooling support for .NET is minimal).
- **TS transpilation target.** Addressed in §3. Not the primary mechanism.
  If a TS transpilation use case is compelling for scripting/tooling, it
  deserves its own sketch with an explicit degraded-semantics section.
- **Deno and Bun specifics.** Both support WASM components. Platform-specific
  packaging (Deno modules, Bun-native modules) is deferred; the WASM
  component artefact works on all three today.
- **NPM shim auto-generation from `.d.ts`.** Manually authored in v1. A
  `lyric restore --generate-npm-shims` that translates TypeScript `.d.ts`
  files to Lyric extern declarations is a valuable v2 investment; the
  mapping is nontrivial (TS's structural types, `any`, overloads).
- **Transitive NPM dependencies.** NPM transitive deps are installed (via
  `npm install`) but do not receive auto-generated shims. Users declare
  only what their Lyric code directly imports, matching the NuGet policy
  in `docs/21-nuget-linking.md` §11.

---

## 11. Open questions (for the decision log)

These must be resolved before implementation begins. Each will become a
decision-log entry.

**Q-JS-001 — `protected type` internal use in WASM.**
The §8.1 policy rejects `protected type` at the WASM export surface.
Should `protected type` also be rejected for *internal* use within a WASM
component? WASM threads (shared memory + Atomics) exist but require
`crossOriginIsolation` headers and opt-in; relying on them by default is
hostile to the common single-threaded WASM deployment. Options: (a) reject
entirely on WASM target, (b) allow with a warning if WASM thread support is
detected, (c) allow but emit a degraded spinlock approximation.
Recommendation pending discussion.

**Q-JS-002 — NPM shim ownership: stdlib tree vs. community registry.**
Should the curated NPM shim files (e.g., for `node-fetch`, major AWS SDK
packages) live in `stdlib/npm/` within this repo, in a separate
community-maintained repo (like DefinitelyTyped), or be generated entirely
by `lyric restore` from `.d.ts`? The stdlib-tree model is the simplest to
start; it becomes a maintenance burden as the package count grows. A
community-registry model scales better but requires infrastructure.
Recommendation: start in `stdlib/npm/` for a small curated set; design
the registry model before adding the 20th package.

**Q-JS-003 — Hard error for `@proof_required` on WASM target.**
§8.3 silently downgrades `@proof_required` to `@runtime_checked` on the
WASM target. Should a `--strict` flag (or a `[wasm-component] strict =
true` config) make this a compile error? Teams that rely on formal
verification may want a guarantee that verified code never ships to an
unverified target. Cost: more friction for the common case; benefit:
clear audit trail. Recommendation pending discussion.

**Q-JS-004 — Scoped NPM package naming with collisions.**
The naming convention in §7.2 maps `@aws-sdk/client-s3` →
`AwsSdk.ClientS3`. If two scoped packages from the same org happen to
produce the same Lyric name, one import wins and the other is silently
shadowed. Is a suffix-disambiguator the right solution? Should collisions
be a hard `lyric restore` error?

**Q-JS-005 — `lyric test` on WASM component targets.**
How does `lyric test` work when the build target is `wasm-component`?
Options: (a) run the test suite on the .NET target and only emit WASM for
`lyric build`, (b) run tests inside a WASM runtime (wasmtime, node) using
the WASM binary, (c) both with an opt-in flag. Option (a) is the simplest
and avoids the problem that WASM-target tests may observe different
degraded-semantics behaviour.

**Q-JS-006 — WIT async proposal stability.**
The Component Model's async proposal (`future<T>`, `stream<T>`) is not yet
stable as of this writing. Should the Lyric WASM target gate on WIT async
stabilising, or use the synchronous subset only and emit a warning for
`async func` exports? Gating is safer; the synchronous subset is usable
now but forces blocking designs on the JS consumer.
