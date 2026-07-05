# 09 — MSIL Emission Strategy

Phase 0 deliverable #7 (per `docs/05-implementation-plan.md`).

This document specifies how Lyric source compiles to MSIL — the
intermediate language of the .NET runtime. Its goal is precise enough
that the Phase 1 implementer can build the code generator without
making new design decisions.

The emission strategy is *not* an MSIL tutorial; it assumes familiarity
with the ECMA-335 spec and with .NET's value-type / reference-type
distinction. Where MSIL details matter for correctness (e.g. `in`
parameter conventions, `TypedReference` for ref-locals, async state
machine layout), this document points to the relevant ECMA-335 clause.

This document settles or defers each of the [TBD] items listed in
language reference §13. The settlements are recorded inline; the
defers are flagged for the Phase 1 implementer with a recommended
default.


## 1. Design principles

The strategy is governed by five principles, in priority order:

1. **AOT-first.** Every emission choice must be Native-AOT-compatible.
   No `System.Reflection.Emit` at runtime. No `Activator.CreateInstance`
   on user-supplied types. No type-name lookup. AOT trim-warnings
   surface as compilation errors.

2. **Reified generic identity.** Lyric's distinct, range, and opaque
   types must keep their identity at the CLR level. `UserId` and
   `OrderId` are *different* CLR types even when both wrap `Long`.
   This rules out type erasure or "single underlying primitive with
   a marker attribute" schemes.

3. **Zero-allocation domain values where possible.** A range subtype
   or a small opaque wrapper compiles to a `readonly struct` so it
   lives on the stack or inline in its containing record. Allocation
   is reserved for genuinely heap-shaped data.

4. **Reflection-resistant opacity.** An opaque type's representation
   is hidden from `System.Reflection`. The stronger the host
   guarantee, the better; AOT mode achieves the strong guarantee
   (Q002 §2). JIT mode degrades to "no public surface; private fields
   accessible only via `BindingFlags.NonPublic` and named with
   compiler-generated mangled names."

5. **Boring lowering for everything else.** Pattern matching becomes
   `switch` plus type-tests. Async becomes the standard
   `IAsyncStateMachine` shape. Tuples become `ValueTuple<…>`. Records
   become `readonly struct` or `record class` per a published
   heuristic. Familiar to anyone who reads C# IL output.


## 2. Compilation artifacts

### 2.1 Per-package outputs

For each package `P`, the compiler emits two artifacts:

- **`<P>.lyrasm`** — a CIL assembly (technically a `.dll`, the
  extension is `.lyrasm` to distinguish it). Contains the IL for `P`,
  metadata, and any embedded source generators' outputs.
- **`<P>.lyric-contract`** — a JSON file containing `P`'s public
  contract: `pub` declarations, signatures, contracts (requires/
  ensures/invariant clauses as syntax trees), generic parameter lists,
  projection types, derive lists. This is the artifact downstream
  packages compile *against*.

Both artifacts are versioned by content hash plus the package's
SemVer number; the manifest carries a SHA-256 over a canonical
JSON encoding of the contract metadata, so a downstream package's
incremental cache can invalidate precisely when the public surface
changes.

### 2.2 Manifest structure

`<P>.lyric-contract` is a JSON document of the form:

```json
{
  "package": "Money",
  "version": "0.1.0",
  "lyric_lang": "0.1",
  "level": "proof_required",
  "imports": [ ... ],
  "items": [
    { "kind": "type", "name": "Cents", "underlying": "Long",
      "range": [0, 100000000000], "derives": ["Add", "Sub", "Compare"] },
    { "kind": "opaque", "name": "Amount", "fields": [...],
      "invariant": "value > 0", "projectable": true,
      "view_type": "AmountView" },
    { "kind": "func", "name": "make",
      "params": [{ "name": "c", "mode": "in", "type": "Cents" }],
      "ret": "Result[Amount, ContractViolation]",
      "ensures": ["result.isOk implies result.value.value == c"]
    }
  ],
  "manifest_hash": "sha256:..."
}
```

Body changes do not affect the manifest hash; only `pub` API changes do.

### 2.3 Assembly identity and naming

Each `.lyrasm` is a CLR assembly with:

- **Assembly name:** `Lyric.<package-fully-qualified>` (e.g.
  `Lyric.Money`, `Lyric.std.collections`).
- **Assembly version:** the package's SemVer mapped onto the four-
  number .NET assembly version: `MAJOR.MINOR.PATCH.0`. The fourth
  field is reserved for build metadata.
- **`AssemblyInformationalVersion`:** the full SemVer string,
  including pre-release tags.
- **`InternalsVisibleTo`:** emitted from `<P>.test_module` annotations
  to expose internals to the test assembly.


## 3. Packages map to assemblies; modules map to namespaces

A Lyric package compiles to *exactly one* assembly. Sub-packages compile
to *separate* assemblies (`Account.Internal` is its own assembly,
distinct from `Account`). The CLR namespace of all types in package `P`
is `Lyric.<P>`; types in `Account.Internal` live in
`Lyric.Account.Internal`.

A package authored with the unified file layout (D005) and a package
authored with the split-file layout (D025) produce *bit-identical*
artifacts. The split is purely an authoring choice; the parser merges
the two file kinds before semantic analysis.

`@test_module` packages compile to assemblies named
`Lyric.<package>.Tests`; the test runner discovers them by reflection
over a `[LyricTestAssembly]` attribute placed on the assembly manifest.
This is the *only* runtime reflection the stack uses, and it operates
over compiler-emitted attributes, never user code.


## 4. Primitive types

The Lyric primitives map directly to .NET BCL primitives:

| Lyric    | CLR                  | Notes                                |
|----------|----------------------|--------------------------------------|
| `Bool`   | `System.Boolean`     |                                      |
| `Byte`   | `System.Byte`        |                                      |
| `Int`    | `System.Int32`       |                                      |
| `Long`   | `System.Int64`       |                                      |
| `UInt`   | `System.UInt32`      |                                      |
| `ULong`  | `System.UInt64`      |                                      |
| `Nat`    | `System.Int64`       | distinct CLR type via wrapper struct (§6) |
| `Float`  | `System.Single`      |                                      |
| `Double` | `System.Double`      |                                      |
| `Char`   | `System.Text.Rune`   | Unicode scalar value, not UTF-16 surrogate |
| `String` | `System.String`      | immutable, UTF-16 in memory; UTF-8 only at I/O boundaries |
| `Unit`   | `System.ValueTuple`  | the zero-arity tuple `()`            |
| `Never`  | (no CLR type)        | uninhabited; functions returning `Never` are emitted with return type `void` and a final `throw`/`unreachable` |

### 4.1 Overflow semantics

Reference §2.1 mandates:

- *Checked builds (`--debug`)*: every arithmetic operation on an
  unconstrained primitive panics on overflow.
- *Release builds*: operations on unconstrained primitives wrap
  silently; operations on range subtypes always panic.

This maps to MSIL as follows:

- Checked: emit `add.ovf`, `sub.ovf`, `mul.ovf`, `div`, `rem`. The
  `.ovf` opcodes raise `OverflowException`, which the runtime wraps
  in a `Bug(IntegerOverflow, ...)` per the bug-bridging rules
  (§19.4).
- Release, unconstrained: emit plain `add`, `sub`, `mul`.
- Range subtype: always emit `.ovf` *and* a follow-up bounds check
  against the type's interval (§6.3).

Division-by-zero is uniformly checked; emit `div`/`rem` and let the
CLR raise `DivideByZeroException`, then bridge to
`Bug(DivisionByZero, ...)`.

### 4.2 IEEE 754

`Float` and `Double` follow ECMA-335 §III.1.5 with `RoundToNearestEven`
and traps disabled. Comparisons with NaN propagate per the standard;
the compiler emits `cgt.un`/`clt.un` for `NaN`-tolerating comparisons
where Lyric's semantics calls for them, and the standard `cgt`/`clt`
otherwise (mirroring C#'s emit choices for `<`, `<=`).

### 4.3 `String` interning and equality

`==` on `String` is value equality (`String.Equals(StringComparison.
Ordinal)`). Reference equality is *not* exposed at the language level.


## 5. Records

A record may compile to either a CLR `readonly struct` or a `record
class`. The choice is determined per Q001 by the following heuristic,
applied at compile time and frozen for the program:

> A record with total field size ≤ 16 bytes (counting the largest
> alignment-padded layout per ECMA-335 §II.10.1) and no async-unsafe
> fields lowers to `readonly struct`. Otherwise, it lowers to `record
> class`.

Where field sizes are themselves records, the heuristic applies
recursively. The implementer rounds up: a record with a `Long` and a
`Bool` is 9 bytes raw, padded to 16; the heuristic admits it as
`readonly struct`.

### 5.1 Annotation override

Two annotations override the heuristic:

- `@valueType` — force lowering to `readonly struct`. The compiler
  rejects this on records that contain fields the heuristic
  classifies as async-unsafe (e.g. mutable cells).
- `@referenceType` — force lowering to `record class`.

The record-vs-class decision is *per declaration*, not per use site;
a record is one or the other consistently throughout the program
(reference §2.4 and Q001).

### 5.2 Field layout

Fields appear in declaration order with default CLR layout
(`LayoutKind.Auto` on classes, `LayoutKind.Sequential` on structs).
The compiler does not emit `[StructLayout]` attributes; for FFI
scenarios that require explicit layouts, the user must define an
`exposed record` and annotate it (Q011, deferred to stdlib design).

### 5.3 Equality and hashing

Records have structural equality. The compiler emits:

- `Equals(object)` and `Equals(SelfType)` — field-by-field equality.
- `GetHashCode()` — combination via `HashCode.Combine`.
- `==` and `!=` operators.

For `readonly struct` records the equality is value-equality; for
`record class` records, the C# `record class` machinery handles it
identically (the compiler may simply target `record class` syntax
and let Roslyn-generated semantics apply; for the bootstrap, we emit
the IL ourselves to avoid Roslyn dependency).

### 5.4 Construction and `copy`

Records are constructed by `RecordType(field1 = e1, ...)` (grammar
§7 RecordCtor). The compiler emits a single constructor with all
fields as parameters, in declaration order; named-argument calls
reorder at the call site.

The non-destructive `copy(field = e)` method is emitted as a
generated instance method that returns a new record with the named
fields overridden and all others copied. For `readonly struct`, the
method is by-value; for `record class`, it allocates a fresh
instance.

### 5.5 Default values

A record field with a default value compiles to a parameter with a
default in the constructor. Default-value expressions must be
constant expressions (evaluated at compile time per §12).


## 6. Distinct types and range subtypes

### 6.1 Lowering shape

A distinct type or range subtype is lowered to a `readonly struct`
wrapper:

```cs
[Lyric.DistinctType(typeof(long))]
public readonly struct UserId : IEquatable<UserId>
{
    private readonly long _value;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public UserId(long value) { _value = value; }

    public long ToLong() => _value;
    // generated equality, hashing, comparison per derives clause
}
```

The struct is a single field of the underlying primitive plus
generated methods. JIT and AOT aggressively inline; the runtime cost
of the wrapper is zero in straight-line code.

The `[Lyric.DistinctType]` custom attribute is for tooling (LSP,
debugger, `lyric public-api-diff`); the runtime ignores it.

### 6.2 `derives` clauses

Each marker in the `derives` clause emits a specific set of methods
(see Q017):

| Marker     | Generated members |
|------------|-------------------|
| `Add`      | `operator +` (same-type binary), `static T Zero` if `Default` is also derived |
| `Sub`      | `operator -` (binary), `operator -` (unary, only if underlying is signed) |
| `Mul`      | `operator *` (binary, same-type only) |
| `Div`      | `operator /` (binary, same-type) |
| `Mod`      | `operator %` |
| `Compare`  | `IComparable<T>`, `<`, `<=`, `>`, `>=` |
| `Hash`     | `GetHashCode` (delegates to underlying `_value.GetHashCode()`) |
| `Equals`   | `IEquatable<T>`, `Equals`, `==`, `!=` |

A type without any `derives` is *opaque to operators* — only
`ToLong()` (or the analogous `To<Underlying>()` method) is exposed.

### 6.3 Range checks at construction

A range subtype carries an interval `[lo, hi]`. The compiler emits
two construction paths:

- **`tryFrom(value: Underlying): Result[T, RangeError]`** — checked,
  returns `Err` on out-of-range.
- **`from(value: Underlying): T`** — panicking, raises
  `Bug(IntegerOverflow, "T")` on out-of-range.

Both paths are `static` methods on the distinct-type struct. Inside
the same package, the compiler also emits an *unchecked* internal
constructor for use after the bounds have already been proven (e.g.
in arithmetic results that the prover or release-mode optimiser knows
are in-range). The unchecked constructor is `[EditorBrowsable(Never)]`
plus a Lyric-internal access modifier; cross-package use is rejected
post-emit.

### 6.4 Arithmetic and bound preservation

`Cents + Cents → Cents` is the typical signature emitted by `derives
Add`. The result must satisfy the range; the compiler chooses one of
two strategies depending on the build mode:

- *Debug*: emit the `add.ovf` plus a follow-up `Cents.from(...)`
  (panicking on out-of-range).
- *Release with proof*: when the function lives in a
  `@proof_required` module and the prover discharges the in-range
  obligation, emit just `add` (no overflow check, no bounds check).
- *Release without proof*: emit `add.ovf` plus `Cents.from(...)`
  but mark the result as a `Bug` rather than a recoverable error.

### 6.5 Conversions

All conversions are explicit:

- `T.toLong()` (or analogous) — extract the underlying value.
- `Long.toUserId(x)` — *only emitted if* the user explicitly declares
  this conversion (e.g. via `derives From[Long]`, deferred to v2).
- `T.tryFrom(underlying)` — Result-returning checked construction.

There are no implicit conversions; every numeric crossing is a
visible call.


## 7. Opaque types

### 7.1 Lowering form

An `opaque type T` whose body is `record { f₁: T₁, …, fₙ: Tₙ;
invariant: φ }` lowers to a struct or class (per the §5 heuristic
applied to its fields), with three differences from a plain record:

1. The fields are emitted with a *mangled* name format:
   `<lyric>$<original-name>`. C# cannot reference identifiers
   containing `<` or `$`, so the names are unforgeable from C# code.
2. The struct/class is sealed and decorated with `[Lyric.Opaque]`.
3. The constructor and any field-mutation methods are emitted as
   `internal` to the package's assembly; cross-package construction
   goes through the package's exposed `pub` constructor functions.

### 7.2 Reflection sealing (Q002)

Per Q002, the strongest available guarantee on .NET combines:

- **Mangled field names** as above.
- A custom `[Lyric.OpaqueRepresentation]` attribute on the type that
  AOT trim warnings respect.
- AOT-mode *trimming* of the type's reflection metadata, controlled by
  a per-type `<TrimMode>` rule the compiler emits into the assembly's
  `<TargetFrameworkAttribute>` block.
- A built-in analyzer (`LyricSealingAnalyzer`) that errors on
  `Type.GetField`, `Type.GetMembers`, `BindingFlags.NonPublic`, and
  similar APIs targeting `[Lyric.Opaque]`-marked types.

In JIT mode, reflection over private fields is a CLR capability we
cannot block. The language reference documents this caveat: the full
opacity guarantee requires AOT mode. The Phase 1 implementer is
expected to implement the four mechanisms above and *document the JIT
caveat in `lyric build`'s help text.*

### 7.3 Projectable opaque types (`@projectable`)

For a `@projectable` opaque type `T`, the compiler additionally emits:

- A sibling `exposed record TView` in the same namespace, containing
  the non-`@hidden` fields of `T` recursively projected per §2.9 of
  the language reference.
- An instance method `T.toView(self): TView`.
- A static method `TView.tryInto(self): Result[T, ContractViolation]`
  that runs `Inv_T` on the candidate and returns `Err` on failure.
- A `@generate`-style hook so source generators (e.g. JSON) can emit
  serialisers for `TView` *without* seeing `T`.

Cycles in the projection graph are caught at compile time per Q003
(implementer recommendation: option 3, mandatory `@projectionBoundary`
annotation).

### 7.4 Construction inside the package

The package author writes a `pub func make(...): T` (or analogous)
that is the canonical constructor. Inside the package, the type's
internal constructor is reachable; outside, it is not. The
implementer should *not* expose a `T(...)` value-syntax constructor
for opaque types crossing the package boundary, even if the
underlying record's constructor would otherwise be public.


## 8. Sum types and enums

### 8.1 Union (sum) lowering

A `union T { case Aᵢ(field₁: U₁, …) ... }` lowers to a sealed CLR
class hierarchy:

```cs
public abstract class T { internal T() {} }

public sealed class T_A : T {
    public readonly U1 Field1; public readonly U2 Field2; ...
}
public sealed class T_B : T { ... }
```

Plus:

- A `Discriminator` enum: `enum T_Tag { A, B, ... }` and a
  `T_Tag Tag { get; }` virtual property.
- Helper static factories: `T.A(U1, U2, ...)`, `T.B(...)`.
- Equality (structural) and `GetHashCode` derived from the tag and
  payload.

The discriminator enables fast `switch` lowering for pattern matching
(§13).

When all variants are payload-free (i.e. an `enum` declaration), the
type lowers to a CLR `enum` directly, with the variants assigned
sequential `int` values starting at 0. This is consistent with the
language reference §2.6's "explicit conversion required to interop
with numeric APIs" — the compiler does not emit implicit conversions
between a Lyric `enum` and `int`.

At the IL level, enum *values* are ordinal `int32`s: a case reference
emits `ldc.i4 <ordinal>`, a `case X ->` pattern compares ordinals with
`ceq`, and enum-typed signature positions encode `ELEMENT_TYPE_I4` —
never `ELEMENT_TYPE_CLASS` naming the enum TypeDef, which the CLR
loader rejects with a value-type mismatch (an enum extends
`System.Enum`, a value type). The CLR `enum` TypeDef (with its
`value__` field and one literal field + `Constant` row per case) is
still emitted for metadata fidelity and host-side interop. Both the
F# bootstrap emitter and the self-hosted backend follow this model.

### 8.2 Variant-free unions vs. enums

A `union` with all payload-free variants is *not* the same as an
`enum` — the former retains its sealed-class hierarchy because future
variants might add payloads. The user chose `union` deliberately.
The lowering preserves the choice: `enum` → CLR `enum`,
payload-free `union` → sealed-class hierarchy.

### 8.3 Generics in unions

`union Result[T, E] { case Ok(value: T), case Err(error: E) }` lowers
to:

```cs
public abstract class Result<T, E> { internal Result() {} }
public sealed class Result_Ok<T, E> : Result<T, E> { public readonly T Value; }
public sealed class Result_Err<T, E> : Result<T, E> { public readonly E Error; }
```

CLR generics are reified, so `Result<UserId, OrderError>` and
`Result<OrderId, OrderError>` are distinct CLR types (good — preserves
distinct-type identity per principle §1.2).

### 8.4 Adding a variant is a breaking change

The compiler emits the variant set into the contract metadata; adding
a new `case` to a `pub union` is a SemVer-major change detected by
`lyric public-api-diff`.


## 9. Generics

### 9.1 Reified, not erased

Lyric generics are reified at the CLR level. A generic function or
type compiles to a CLR generic; instantiations are reified by the CLR
just as they are for C#. There is no erasure, no reflection-based
dispatch, no boxing of value-type parameters.

### 9.2 Monomorphisation vs reification

The reference (§2.11) calls Lyric "monomorphized." That is true for
the *type checker* — every instantiation is treated as a concrete
type — but at the IL level the CLR's reification machinery does the
actual specialisation. Concretely:

- The compiler emits *one* IL definition per generic source
  declaration, parameterised by CLR type parameters.
- Each instantiation `Result<UserId, OrderError>` is a distinct CLR
  type at runtime, with its own method tables, allocated on demand
  by the CLR.
- Value-type parameters (e.g. our distinct-struct types) get
  per-instantiation method bodies; reference-type parameters share a
  single shared method body. This is exactly C#'s behaviour.

The advantage of leaning on CLR reification is that we get the
behaviour we need without inflating the code base or AOT-binary size
beyond what C# does. AOT mode pre-instantiates the generics seen in
the program; trim warnings flag any instantiation only reachable
through reflection (which Lyric forbids — so this is moot).

### 9.3 Value generics

Reference §2.11 admits value generics: `generic[T, N: Nat] record
FixedVec { data: array[N, T] }`. The CLR has no first-class value
generics, so we lower these to type-parameterised "tag types":

- The compiler emits a phantom marker struct per `const N: Nat`
  value that appears in the program: `struct N_42 : INatTag { static
  long Value => 42; }`.
- The generic `FixedVec<T, NTag>` takes a phantom type parameter
  `NTag : INatTag`.
- All references to `N` in the body lower to `NTag.Value`.

This is the same trick C# uses internally for `Span` length tags in
some BCL APIs. It is AOT-compatible and zero-cost (the JIT/AOT
inlines `NTag.Value`).

### 9.4 Constraints (`where`)

**Bootstrap lowering (shipped).** Marker constraints are not lowered
to CLR generic constraints in the bootstrap; they are checked at
monomorphization call sites by a closed lookup function
(`satisfiesMarker` in `Lyric.Emitter/Codegen.fs`).  This avoids the
need to emit CLR interface types for each marker.  The satisfaction
rules are:

1. **Same-package distinct types:** a type `T` defined as
   `type T = U derives M1, M2` satisfies markers `M1` and `M2`.
   The compiler records the `derives` list on `DistinctTypeInfo` and
   consults it at every call site where a bound is checked.

2. **CLR primitives:** numeric types satisfy `Add`, `Sub`, `Mul`,
   `Div`, `Mod`, `Compare`, `Hash`, `Equals`, `Default`.  Ordered
   primitives (numeric + `Char` + `String`) satisfy `Compare`.
   All primitives satisfy `Hash`, `Equals`, `Default`.

3. **User-defined interfaces:** when the marker names a same-package
   `interface`, any record type that `impl`s that interface satisfies
   the bound (resolved via the `ImplsTable` populated in Pass A.5).

4. **`Copyable`:** any value type (CLR `struct`) satisfies `Copyable`.
   `Default` maps to a `where T : new()` check in the same table.

The closed marker set (`Equals`, `Compare`, `Hash`, `Default`,
`Copyable`, `Add`, `Sub`, `Mul`, `Div`, `Mod`) is fixed by
decision-log D034.

**Phase 5 target (future).** Once the compiler is self-hosted, marker
constraints will be lowered to CLR generic constraints (interface or
`struct`/`new()` as appropriate) so that cross-assembly generics carry
constraint metadata in IL and CLR verification can enforce them without
re-running the Lyric checker.


## 10. Exposed records

`exposed record T` lowers to a plain CLR `record class` (or `class`
with manually emitted equality, for the bootstrap that doesn't depend
on Roslyn) with all fields public, no opacity, no invariant clause.
This is the wire-level type — DTOs, log payloads, configuration —
intended to be reflected upon by serialisers, ORMs, and similar.

`@generate(Json)`, `@generate(Sql)`, etc. are processed at compile time
by source generators that emit serialisers as additional types in the
package's assembly. The serialisers are AOT-compatible by
construction (no runtime reflection).

A projectable opaque type's generated `TView` is an exposed record;
the same lowering applies.


## 11. Functions, parameter modes, closures

### 11.1 Function lowering

A regular `func` lowers to a CLR static method on an internal class
named `<package-name>$Funcs`. There is no equivalent of C#'s
"top-level statements"; every function lives in some emitted class.

### 11.2 Parameter modes — `in`/`out`/`inout`

Lyric mode → CLR convention:

| Mode    | CLR convention                                |
|---------|-----------------------------------------------|
| `in`    | by-value for primitives and small structs (≤ 16 bytes); `in` for larger structs (CLR `[IsReadOnly]` ref); plain reference for reference types |
| `out`   | CLR `out` (a managed pointer with definite-assignment requirement) |
| `inout` | CLR `ref`                                     |

The compiler emits `[IsReadOnly]` on `in` parameters whose underlying
type is a struct ≥ a threshold (the same 16-byte threshold as §5).
Smaller structs pass by value to avoid the indirect-load cost.

### 11.3 Definite-assignment for `out`

The compiler enforces `out` definite-assignment per §5.2 of the
reference at IL emission time: every control-flow path through the
function body must assign the `out` parameter exactly once before
return. CLR verification rejects programs without this property
anyway, but emitting the precise diagnostic at compile time is the
user-facing requirement.

### 11.4 `inout` and async

Per Q005, `inout` parameters used after an `await` are rejected at
compile time. The MSIL emitter does not need a special case here;
the analysis is purely on the AST.

### 11.5 Closures and lambdas

A closure `{ x: Int -> x + n }` lowers to a generated class with:

- one field per captured variable,
- an `Invoke` method whose IL is the closure body,
- a constructor taking the captured values as arguments.

Captured `val` bindings (immutable) are captured by value; the field
holds the value at closure creation. Captured `var` bindings,
following Q007, default to *snapshot at closure creation* (by-value).
Capturing a `var` for write-back across an async boundary is a
compile error; the user must wrap in `protected type` or stdlib
`Atomic[T]`.

The closure's class is sealed and emitted in the same assembly as
the enclosing function. AOT compilation pre-instantiates closures
that appear in the call graph.

### 11.6 Default parameter values

A default parameter value lowers to a CLR `[DefaultParameterValue]`
attribute when the value is a constant (compile-time-constant
expression). For non-constant defaults, the compiler emits an
overload pair: the full-arity method plus a thunk that supplies the
default.


## 12. Compile-time constants

Constants emit as `static readonly` fields on `<package>$Consts`,
initialised in a class constructor that runs once per AOT image.
Where the constant is purely arithmetic and the value computable at
emit time, the compiler folds it into the IL directly (a literal
operand on each use) and skips the field altogether.


## 13. Pattern matching

### 13.1 Lowering shape

A `match e { ... }` lowers to a `switch` on the matched value's
discriminator (§8.1) plus IL `isinst` checks for type-test patterns,
plus a sequence of `brfalse`/`brtrue` for guards. Concretely:

```
match shape {
  case Circle(r) -> 3.14159 * r * r
  case Rectangle(w, h) -> w * h
}
```

lowers to:

```
ldarg.0
isinst Shape_Circle    ; null if not a Circle
brfalse  L_NotCircle
  ldarg.0
  castclass Shape_Circle
  ldfld Shape_Circle::Field0   ; r
  ; ... 3.14159 * r * r ...
  br L_End
L_NotCircle:
  ldarg.0
  isinst Shape_Rectangle
  brfalse  L_NotRectangle
  ; ... w * h ...
  br L_End
L_NotRectangle:
  ; if exhaustive, this is unreachable; emit a panic
  ldstr "non-exhaustive match (compiler bug)"
  newobj Bug
  throw
L_End:
```

For `enum`-form unions (no payload), the compiler emits a CLR
`switch` directly on the underlying integer.

### 13.2 Exhaustiveness

The semantic analyser confirms exhaustiveness; the IL emitter assumes
it. A non-exhaustive match without `case _` is rejected at compile
time and never produces IL. The trailing "compiler bug" panic in
§13.1 is defensive: it triggers only if the runtime dispatched a
type the compiler believed unreachable (e.g. via an unsafe FFI
pathway).

### 13.3 Guards (`where` / `if`)

A guard expression is emitted as a `brfalse` after the matching
branch's bindings are established but before the arm's body runs.
A failed guard falls through to the next arm.

### 13.4 Range and literal patterns

Range patterns (`0 ..= 9`) lower to a pair of comparisons
(`>= lo && <= hi`). Literal patterns lower to `ceq`. String literal
patterns use `String.Equals(_, StringComparison.Ordinal)`.

### 13.5 Record-shape patterns

`Point { x = 0.0, y }` lowers to a sequence of field-load + compare
(for `x`) and field-load + bind (for `y`), in declaration order.
The `..` ignore-rest marker emits no further checks.


## 14. Async functions

### 14.1 State-machine shape

An `async func f(...): T` lowers to the standard CLR async pattern:

- the original method emits a *stub* that allocates the state
  machine, calls its `MoveNext`, and returns a `Task<T>` (or
  `ValueTask<T>` per §14.2).
- the body lowers into a generated `IAsyncStateMachine` struct with
  `MoveNext`, captured locals as fields, and an `AsyncTaskMethod
  Builder<T>` that drives the resumption.

This is the same shape Roslyn emits for C# `async`. We do not invent
a new state-machine layout; the CLR already supports this and AOT
mode handles it natively.

### 14.2 `Task<T>` vs `ValueTask<T>` (Q010)

Default: `Task<T>`. The compiler emits `ValueTask<T>` only for
functions annotated `@hot`. The annotation is transparent at the IL
level — only the state-machine builder type changes.

`@hot` triggers a static analysis: any callsite that re-awaits the
returned value is reported as a diagnostic, because re-awaiting a
`ValueTask` is undefined behaviour. The diagnostic is upgraded to an
error if the same `ValueTask` value is used in two `await`
positions.

### 14.3 The implicit `cancellation` parameter

Every `async func` carries an implicit `CancellationToken
cancellation` parameter. The compiler emits it as a regular CLR
parameter at the *end* of the method's signature (after the user-
declared parameters). At call sites, the compiler threads the
caller's `cancellation` automatically; explicit overrides go through
a stdlib `withCancellation(...)` combinator.

`cancellation.checkOrThrow()` lowers to a method call that checks the
token and, if cancelled, raises a `Bug(Cancelled)` (which propagates
per the bug-bridging rules).

### 14.4 Cross-package async

`async func` signatures across package boundaries are subject to
Q016: a synchronous implementation may satisfy an async-declared
interface method. The compiler wraps the synchronous body in
`Task.FromResult(...)` (or the `ValueTask` equivalent for `@hot`).
The wrap is invisible to the caller and zero-cost in the
synchronous-completion path.

### 14.5 `await` lowering

`await e` inside an `async func` body is lowered by the Phase B
state-machine emitter (`AsyncStateMachine.fs`).  The generated `MoveNext`
method contains a state-dispatch switch on `<>1__state` at its entry
point; each `await` site is one state index.  The protocol for each
await site is:

```
// --- fast path (awaiter already complete) ---
var awaiter = e.GetAwaiter();
if (!awaiter.IsCompleted) {
    // --- slow path: suspend ---
    <>1__state = N;
    <>u__N  = awaiter;           // stash typed awaiter field
    builder.AwaitUnsafeOnCompleted(ref awaiter, ref this);
    return;                      // exit MoveNext; scheduler resumes later
    // --- resume label (state dispatch jumps here on re-entry) ---
    awaiter  = <>u__N;
    <>u__N   = default;
    <>1__state = -1;
}
result = awaiter.GetResult();    // only reached when complete
```

Locals whose lifetimes span a suspend point are promoted to fields on
the state-machine struct (Phase B+ and later).  Awaits in `while`/`loop`
bodies, `defer` blocks, `try`/`catch` arms, and `for` loop bodies are
each handled by the Phase B+/B++/B+++ extensions in `AsyncStateMachine.fs`.

The M1.4 blocking shim (`.GetAwaiter().GetResult()` synchronously) is
retained as a fallback for ineligible shapes — awaits in expression
positions where stack-spilling has not been applied, or inside lambda
bodies that form a separate async context.  Ineligible functions are
diagnosed at compile time.

For non-task awaitables (rare in Lyric — primarily custom awaiters
from FFI) the same state-machine pattern applies, dispatching through
the awaiter's interface.

### 14.6 Async generators (`yield` in `async func`)

An `async func f(...): T` whose body contains at least one `yield`
expression is an *async generator*. The compiler selects one of two
synthesis strategies based on whether the body also contains `await`.

#### 14.6.1 Eager-producer (no `await` in body)

Synthesises a sibling class `<f>__Gen_N`:

```
sealed class <f>__Gen_N :
    IAsyncEnumerable<T>, IAsyncEnumerator<T>, IAsyncDisposable {
  // parameter fields (public, populated by kickoff)
  List<T> _values; int _pos; T _current;
  void RunBody() { /* user body; yield e → _values.Add(e) */ }
  IAsyncEnumerator<T> GetAsyncEnumerator(CancellationToken) {
    _values = new List<T>(); _pos = -1; RunBody(); return this; }
  ValueTask<bool> MoveNextAsync() { /* serves from _values[_pos] */ }
  T Current { get { return _current; } }
  ValueTask DisposeAsync() { return default; }
}
static IAsyncEnumerable<T> f(...) {
  var gen = new <f>__Gen_N(); gen.p0 = arg0; …; return gen;
}
```

`RunBody` is called synchronously by `GetAsyncEnumerator`; all `yield`
expressions execute eagerly before the first `MoveNextAsync` returns.
Correct for generator comprehensions and producer pipelines whose body
has no internal `await` (D-progress-260).

#### 14.6.2 Async-iterator (body has both `yield` and `await`)

Gap-4a (D-progress-261): synthesises a combined class `<f>__AsyncIter_N`
that is simultaneously an `IAsyncStateMachine` and the enumerable:

```
sealed class <f>__AsyncIter_N :
    IAsyncStateMachine,
    IAsyncEnumerable<T>, IAsyncEnumerator<T>, IAsyncDisposable {
  // Fields
  int <>1__state;                       // -2=done, -1=running, 0..A-1=await, A..A+Y-1=yield
  AsyncTaskMethodBuilder <>t__builder;  // used only for AwaitUnsafeOnCompleted
  T <>2__current;                       // value of the latest yield
  TaskCompletionSource<bool> _tcs;      // signal for the pending MoveNextAsync
  // parameter and promoted-local fields (one per user local straddling an await/yield)
  // awaiter fields (one per await site, lazily allocated)

  void MoveNext() { /* Phase-B state machine: awaits + yields */ }
  void SetStateMachine(IAsyncStateMachine sm) { <>t__builder.SetStateMachine(sm); }

  IAsyncEnumerator<T> GetAsyncEnumerator(CancellationToken) {
    <>1__state = -1;
    <>t__builder = AsyncTaskMethodBuilder.Create();
    return this;
  }
  ValueTask<bool> MoveNextAsync() {
    _tcs = new TaskCompletionSource<bool>();
    this.MoveNext();           // drive one step synchronously
    return new ValueTask<bool>(_tcs.Task);
  }
  T Current { get { return <>2__current; } }
  ValueTask DisposeAsync() { return default; }
}
```

**State layout**: states `0..A-1` are await-resume states (Phase B
protocol: `AwaitUnsafeOnCompleted` stores the awaiter, sets state N,
`Leave` past try/catch, `Ret`; resume label reloads awaiter, `GetResult`).
States `A..A+Y-1` are yield-resume states: each `yield e` stores `e`
into `<>2__current`, sets state `A+i`, calls `_tcs.SetResult(true)`,
flushes promoted locals to their fields, then `Leave`s past the try/catch
and returns.  When `MoveNextAsync` calls `MoveNext` again the dispatch
switch jumps to resume label `A+i`, resets state to -1, and continues
the body.

**Promoted locals**: any local variable whose lifetime spans an `await`
or a `yield` boundary is promoted to a field (`<l>__name`) and shadowed
by an IL local.  At every `MoveNext` entry the fields are loaded into the
IL locals; at every suspend point (await or yield) the IL locals are
flushed back to the fields.

The kickoff stub is identical to the eager-producer: create instance,
copy params to fields, return as `IAsyncEnumerable<T>`.

Both strategies are implemented in
`bootstrap/src/Lyric.Emitter/AsyncGenerator.fs`; the routing is in
`bootstrap/src/Lyric.Emitter/Emitter.fs`.

`for x in gen() { … }` lowers to a standard `await foreach` —
`GetAsyncEnumerator`, loop on `MoveNextAsync`, `Current` access,
`DisposeAsync` in a `finally` block.

The JVM-target equivalent uses `java.lang.Iterable` + `java.util.Iterator`
with the same eager `runBody()` pattern (B129, `lyric-compiler/jvm/lowering.l`).


## 15. Structured concurrency scopes

> **Status (D119).** This section is rewritten to the *implementable*
> self-hosted lowering. The earlier design (a `Lyric.Runtime.Scope`
> runtime type with `try { __scope.JoinAll() } catch { __scope.Cancel();
> throw }`) was never ported to the self-hosted backend and is
> **not implementable as written** — V0012 rejects an `await` inside any
> protected region, and `JoinAll()` awaits. The lowering below is
> BCL-only (no bespoke runtime type) and keeps the join out of every
> `try`. It lands as D119 slice S6, on the §7.3 cancellation token from
> slice S5.

### 15.1 Scope-block lowering

A `scope { ... }` block opens a `CancellationTokenSource` linked to the
ambient `cancellation` token (§16), plus a `List<Task>` collecting the
tasks spawned inside it, then runs the body, then joins at exit:

```cs
var __cts = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
var __scopeTasks = new List<Task>();
// ... body: each `spawn e` registers its Task in __scopeTasks (§15.2) ...
var __agg = Task.WhenAll(__scopeTasks.ToArray());
await __agg.ContinueWith(_ => { });   // non-throwing join — NOT in a try (V0012-safe)
if (__agg.IsFaulted) throw __agg.Exception;   // AggregateException, outside any try
```

The join awaits a *non-throwing* continuation of `Task.WhenAll(...)`, so
it needs no protected region and does not trip V0012. The
`AggregateException` is materialised and rethrown **after** the await,
outside any `try`.

### 15.2 `spawn`

`spawn e` lowers to the call `e` with `__cts.Token` threaded in as the
ambient cancellation token (§16), producing the hot `Task<T>` (or
`ValueTask<T>` when annotated) that .NET has already begun running. The
emitter:

1. registers the `Task` in the enclosing scope's `__scopeTasks`, and
2. attaches a fault continuation
   `task.ContinueWith(t => { if (t.IsFaulted) __cts.Cancel(); })` so the
   *first* failure cancels `__cts`, and still-running sibling tasks
   (which observe `cancellation`) stop cooperatively rather than running
   to completion.

The `Task<T>` is also bound to the caller's local for a later `await`
(which, on a settled task, reads the result). A `spawn` outside a
`scope` block is rejected at compile time by the shared front-end
(**V0013**, D119 slice S2): the parser admits `spawn`, but the checker
requires the enclosing lexical context to be a `scope` (or a function
whose entire body is the scope, by sugar). No fire-and-forget.

### 15.3 Aggregate failure

`Task.WhenAll` already implements §7.4's aggregation: its faulted task's
`.Exception` is a `System.AggregateException` whose `InnerExceptions`
carry every child failure, with `InnerException` (the primary cause)
being the first. The scope IL does not aggregate manually — it rethrows
`__agg.Exception` (§15.1). Sibling *cancellation* on first failure is
driven by the per-task fault continuation of §15.2 cancelling `__cts`,
independently of the final `WhenAll` join.


## 16. Cancellation

Cancellation is cooperative and driven by `CancellationToken`. Every
`async` boundary checks the token. Long synchronous loops in `async`
contexts are expected to call `cancellation.checkOrThrow()` per
iteration.

The runtime lowers cancellation tokens onto CLR
`System.Threading.CancellationToken`. Scope cancellation is
implemented as `CancellationTokenSource.Cancel()` on the scope's
linked source (§15.2).

> **Status (D119).** The implicit `cancellation` parameter, its ambient
> propagation to child async calls, and `cancellation.checkOrThrow()`
> (→ `CancellationToken.ThrowIfCancellationRequested()`) are **not yet
> shipped** on the self-hosted MSIL backend; they land as D119 slice S5
> and are the prerequisite for the §15 structured-concurrency lowering
> (slice S6). Threading a token into every async signature is an
> async-ABI change (kickoff stub, state-machine field set, and every
> async call site), so it lands as its own slice with full parity.


## 17. Protected types (Q008, Q009)

### 17.1 Lowering shape

A `protected type P { ... }` lowers to a sealed CLR class `P` with:

- private fields for each declared `var`/`let`/field,
- a lock field whose type is chosen by the tri-modal flavour
  selection in §17.4 (`SemaphoreSlim`, `ReaderWriterLockSlim`,
  or `Object` (Monitor)),
- one CLR method per `entry` and `func` declaration, each wrapping
  the body in lock-acquire / lock-release.

Internal helper functions (private, no `entry`) compile to private
methods that *do not* re-acquire the lock — they assume the caller
already holds it.

### 17.2 Entry method shape

For `entry tryAcquire(count: in Double): Bool` with `requires:
count > 0.0` and a body, the emitted IL shape is:

```cs
public bool tryAcquire(double count) {
    // precondition (per §6.1 of contract semantics)
    if (!(count > 0.0)) throw new Bug.PreconditionViolated("tryAcquire");

    _lock.Wait(this.cancellation);
    try {
        // invariant on entry
        AssertInvariant();

        // body
        var result = ...;

        // invariant on exit
        AssertInvariant();
        return result;
    }
    catch (Bug) {
        // §8.3: rollback intermediate writes
        RollbackTo(_snapshot);
        AssertInvariant();
        throw;
    }
    finally {
        SignalBarriers();
        _lock.Release();
    }
}
```

`RollbackTo` and `_snapshot` are generated only when the protected
type has fields whose mutation could be observed before the abort.
For idempotent or write-only entries the rollback is omitted.

### 17.3 `when:` barriers

Any protected type that declares at least one `when:` barrier is
forced onto a `Monitor`-backed lock (`PLMonitor` flavour) because
`Monitor.Wait` / `Monitor.PulseAll` are the only BCL primitives that
support condition-variable semantics under an exclusive lock.

The emitted IL for a barrier entry is a wait-loop:

```
Monitor.Enter(this.<>__lock)
.try {
  L_check:
    if (!barrier_1) goto L_wait
    ...
    if (!barrier_n) goto L_wait
    goto L_body
  L_wait:
    Monitor.Wait(this.<>__lock)   // returns bool (always true), discarded
    pop
    goto L_check                  // re-evaluate on wake
  L_body:
    result = <unsafe>__name(this, args)
    // invariant checks
    if (isEntry) Monitor.PulseAll(this.<>__lock)
    leave end
} finally {
  Monitor.Exit(this.<>__lock)
}
end:
  [ldloc result]
  ret
```

`Monitor.Wait` releases the lock and suspends the caller until
another thread calls `PulseAll` (emitted at the end of every
`entry` body). The wait is **infinite**: Lyric follows Ada
semantics — an `entry … when …` that is never satisfiable causes
the caller to block forever. The programmer is responsible for
ensuring progress. A future uplift (CancellationToken integration)
would require replacing `Monitor` with a `Lock` + `SemaphoreSlim`
pair that supports `Wait(CancellationToken)`; this is deferred to
Phase 2 / Phase C scope.

### 17.4 Lock-flavour selection (Q008, D-progress-087, D-progress-092)

Three lock flavours are chosen at compile time, keyed off the
declarations in the protected type body:

| `hasBarriers` | `hasFuncs` | Lock emitted            |
|---------------|------------|-------------------------|
| true          | (any)      | `Object` (Monitor)      |
| false         | true       | `ReaderWriterLockSlim`  |
| false         | false      | `SemaphoreSlim`         |

Barrier-bearing types are forced onto `Monitor` because
`ReaderWriterLockSlim` and `SemaphoreSlim` do not support
`Wait`/`Pulse`. The cost is that concurrent `func` reads are
serialised on barrier-bearing types; this matches Ada's model
(protected functions are exclusive under an active barrier entry).

`func` operations on non-barrier types acquire the read lock;
`entry` operations acquire the write lock.

### 17.5 Pattern matching is rejected (Q019)

Per Q019, the compiler rejects any pattern that destructures a
protected type at the outer level (`case Foo { tokens, ... } -> ...`).
This is enforced in the type-check pass; no IL is emitted for such
matches.


## 18. Wire blocks (DI)

### 18.1 Lowering shape

A `wire ProductionApp { ... }` block lowers to a generated `static`
class `ProductionApp` with:

- `static <T> Bootstrap(<provided values...>): <Wire>` — entry
  point. Returns a wire instance with the singletons constructed.
- `static <T>` accessors for each `expose`d value.
- `private static <T>` factories for each `singleton` and `scoped`
  declaration.

### 18.2 Singleton resolution

Each `singleton` is emitted as a `static Lazy<T>` initialised by the
factory; its first `.Value` access constructs the instance, and the
CLR's `Lazy<T>` semantics ensures thread-safe single initialisation.

### 18.3 Scoped resolution

Each `scoped[Scope]` is emitted as an `AsyncLocal<Scope, T>`-keyed
dictionary lookup. The host integrates with the relevant scope tag
via stdlib types (`HttpScope`, `TransactionScope`, etc.).

### 18.4 Lifetime checking

The compile-time DI resolver enforces: a singleton may not depend on
a scoped value; a wider scope may not depend on a narrower one. This
check runs over the AST of the wire block; if it fails, no IL is
emitted.

### 18.5 Multiple wires

A program with several `wire` blocks (test, prod, integration)
emits one class per wire. Wires do not share instances; each is its
own DI graph.


## 19. Contract elaboration

### 19.1 Where contracts insert IL

Per `docs/08-contract-semantics.md` §6, the runtime semantics requires
contract evaluation at specific points. The MSIL emitter inserts
checks at exactly those points:

| Contract clause       | Insertion point                                  |
|-----------------------|--------------------------------------------------|
| `requires:` on `f`    | first IL instructions of `f`'s body              |
| `ensures:` on `f`     | wrapping every `return` (or trailing expr)       |
| `invariant:` of T     | end of every constructor of T; before-call invariant on parameters of public functions; after-return invariant on public functions returning T |
| `when:` on entry      | inside the lock-acquire wrapper, in a `while` loop until the barrier holds |
| `result`              | a generated CLR local populated immediately before `ensures:` IL |
| `old(e)`              | a generated CLR local populated at function entry, after `requires:` succeeds |

A failing check does *not* simply throw the corresponding CLR
exception. It calls into the runtime's `Bug.Raise(...)` helper, which
constructs the canonical `Bug` value and then `throw`s a CLR
exception that the rest of the stack treats as a Bug carrier.

### 19.2 Snapshotting for `old(e)`

The compiler emits an `old`-snapshot prelude based on the syntactic
set `free_old(Post_f)` (per §5.2 of contract semantics). For each
distinct `e` appearing inside an `old(...)`:

- Allocate a CLR local of `e`'s type.
- Emit the IL for `e` and store it into the local, *after*
  `requires:` succeeds.
- In the `ensures:` IL, every reference to `old(e)` loads from this
  local.

For slice-typed and mutable-record-typed `e`, the local stores a
*snapshot copy* (an `ImmutableArray<T>` for slices; a deep copy for
mutable records). The runtime cost is paid only for functions whose
contracts read those values.

### 19.3 Elision in release mode

In `--release` mode, `@runtime_checked` modules may have certain
checks elided per `lyric.toml`'s `[contracts]` section:

- `panic_on_internal_violations = true` (default) keeps every check.
- `elide_internal_preconditions = true` removes `requires:` checks on
  package-private functions, on the assumption that their callers
  inside the same package have been audited.
- `elide_invariants_on_intra_package = true` (default) — invariants
  are only checked at public boundaries, never on intra-package
  helpers.

Public-boundary checks are *never* elidable. The `lyric.toml` settings
for elision compile into the assembly's metadata so `lyric public-api-
diff` can warn on a downgrade.

### 19.4 Bug bridging

The CLR raises specific exceptions for many of the conditions Lyric
classifies as Bugs (`OverflowException`, `DivideByZeroException`,
`IndexOutOfRangeException`, `NullReferenceException`). The runtime's
top-level handler inserts a `try`/`catch` wrapper at every Lyric
function entry that *re-wraps* such CLR exceptions into the
corresponding `Bug` tag:

- `OverflowException` → `Bug(IntegerOverflow)`
- `DivideByZeroException` → `Bug(DivisionByZero)`
- `IndexOutOfRangeException`, `ArgumentOutOfRangeException` →
  `Bug(ArrayBoundsViolated)`
- `NullReferenceException` → `Bug(NullDereference)` (which can only
  arise if the type system has been bypassed — opaque types do not
  permit `null`; nullable `T?` is a Lyric union, not a CLR null)
- `OperationCanceledException` → `Bug(Cancelled)`

The wrapper is emitted only on functions whose IL actually contains
operations that can raise these exceptions; pure functions over
range-bounded values get no wrapper, no overhead.


## 20. `@generate` and source generators

`@generate(Json)`, `@generate(Sql)`, `@generate(Proto)`, `@generate(Equals)`,
etc. are processed by source generators that run as part of the compilation
pipeline. The bootstrap compiler (Phase 1) ships with a fixed set of built-in
generators (bare single-segment names). Custom third-party generators are invoked
with dotted package references (`@generate(Pkg.Name)`) and are declared as
`kind = "source-generator"` dependencies; see `docs/40-source-generators.md` and D075.

**Built-in generators** (`Json`, `Sql`, `Proto`, `Equals`) run inline inside the
compiler's synthesis pass with direct AST access. They are hard-coded and require
no subprocess invocation or JSON bridge.

**Custom generators** receive a structured `GeneratorRequest` descriptor (via
`Lyric.GeneratorSdk`) and return `lyricSource`: a string of complete Lyric item
declarations. The compiler re-parses that string and inserts the resulting items into
the same file before type checking. Custom generators run as a pre-processing step
driven by the self-hosted `Lyric.Cli` pipeline; the F# bootstrap never sees the
raw `@generate(Pkg.Name)` annotation.

The output of both paths is AOT-compatible by construction: no runtime reflection,
no `IDictionary` lookups against type tokens. Serialisation is generated as
straight-line code over the type's fields.

`@generate(Equals)` is the only auto-applied generate on `record` and `union` types
(structural equality is part of the language reference §2.4); all others are opt-in.


## 21. AOT compatibility

### 21.1 What we can't emit

The following are forbidden in compiler output:

- `System.Reflection.Emit` (no DynamicMethod)
- `Activator.CreateInstance` over user types
- `Type.GetType(string)` lookup
- `BindingFlags.NonPublic` reflection over user types
- Late-bound delegate creation via reflection
- `AppDomain.CurrentDomain.GetAssemblies()` walks for dispatch

Source generators replace each legitimate use case (DI resolution,
serialisation, test discovery, mocking via `@stubbable`).

### 21.2 Trim and AOT tooling

The compiler emits assemblies with `<IsTrimmable>true</IsTrimmable>`
and `<IsAotCompatible>true</IsAotCompatible>` metadata. AOT-mode trim
warnings are upgraded to compilation errors by the Lyric build
driver.

### 21.3 Reflection by attribute

The single permitted reflection pathway is reading compiler-emitted
*attributes*. The test runner reads `[LyricTestAssembly]` and
`[LyricTest("name")]`. The DI runtime reads `[LyricWire("name")]`.
These attributes are emitted by the compiler, not user code, and the
trim model preserves them by default.


## 22. Putting it together — example pipeline

Compiling `money.l` from `docs/02-worked-examples.md`:

1. **Parse.** Source tokens → AST per `grammar.ebnf`.
2. **Resolve.** Names are bound; imports resolved; package
   `Money` selected.
3. **Type-check.** `Cents` is `Long range 0 ..= 1_000_000_000_00`;
   `Amount` is opaque with one field `value: Cents` plus invariant.
4. **Mode-check.** `make`, `valueOf` parameters are all `in`.
5. **Contract elaborate.** `make`'s `ensures:` produces a snapshot
   prelude (none — no `old`), a `result`-loading sequence, and the
   ensures-check IL.
6. **Lowering.**
   - `Cents` → `readonly struct Cents { private readonly long _value;
     ... }` with derives-generated `Add`, `Sub`, `Compare`.
   - `Amount` → `internal sealed class Amount` (or readonly struct,
     given its single `Cents` field, which is small) with mangled
     field name `<lyric>$value` and `[Lyric.Opaque]` attribute.
   - `make` → static method on `Money$Funcs`, emitting the IL for
     the `if`/`return`, the `Result.Ok`/`Result.Err` constructors,
     and the ensures-check.
7. **Emit.** Write `Money.lyrasm` and `Money.lyric-contract`.
8. **Verify (proof-required).** Run the VC generator against
   `make`'s contract; Z3 discharges the trivial obligation.

A downstream package `Account` that imports `Money` reads
`Money.lyric-contract` for type-checking; at link time, the
`Account.lyrasm` references `Money.lyrasm` by assembly name, and the
CLR or AOT linker resolves the actual code.


## 23. References

- ECMA-335 (CLI): the reference for IL semantics, value-type vs
  reference-type rules, and async state machines.
- ECMA-334 (C#): contains the original definitions of `in`/`out`/
  `ref` parameter conventions we inherit.
- *.NET Native AOT documentation* (Microsoft): trim model, AOT
  warnings, supported APIs.
- *Roslyn source*: the `record class` and `async` lowering patterns
  are the de-facto reference; we deliberately match them where we
  can.
- *Decision log* (`docs/03-decision-log.md`): D001 (target),
  D002 (memory), D006 (no reflection), D008 (DI as language feature),
  D015 (`@projectable`), D023 (no JVM in v1).
- *Open questions* (`docs/06-open-questions.md`): Q001, Q002, Q005,
  Q007, Q008, Q009, Q010 — each cross-referenced inline above.
- *Operational semantics for contracts* (`docs/08-contract-semantics.md`):
  the source of truth for *when* contracts are checked; this document
  is the source of truth for *how* the checks are emitted.

---

## Appendix A. Quick-reference: Lyric construct → CLR shape

| Lyric                           | CLR                                          |
|---------------------------------|----------------------------------------------|
| primitive                       | matching BCL primitive                       |
| `record T`                      | `readonly struct T` if ≤ 16 B; else `record class` |
| `exposed record T`              | `record class T` (or class with eq for bootstrap) |
| `type X = Y range a ..= b`      | `readonly struct X` wrapping `Y`             |
| `type X = Y` (no range)         | `readonly struct X` wrapping `Y`             |
| `alias X = Y`                   | (no CLR type; X resolves to Y)               |
| `opaque type T`                 | sealed struct/class with `[Lyric.Opaque]`     |
| `union U { case A, case B(...) }`| sealed-class hierarchy `U`, `U_A`, `U_B`     |
| `enum E`                        | CLR `enum E : int`                           |
| `array[N, T]`                   | `T[]` of fixed length, length checked statically |
| `slice[T]`                      | `ImmutableArray<T>` (or `ReadOnlyMemory<T>` for views) |
| `T?`                            | union: `case Some(T)`, `case None` (sealed-class hierarchy) |
| function (`func`)               | `static` method on `<package>$Funcs`         |
| `async func`                    | `async` state machine; `Task<T>` (or `ValueTask<T>` if `@hot`) |
| closure                         | sealed class with `Invoke` and captured fields |
| `protected type`                | sealed class with `SemaphoreSlim` (or RWLock) |
| `wire`                          | static factory class with `Bootstrap`        |
| `interface`                     | CLR interface                                |
| `impl I for T`                  | `class T : I` with method bodies             |
| `extern package`                | references to BCL types via marshalling shims |


## Appendix B. Per-Q resolution summary

| Q     | Topic                              | Resolution in this document        |
|-------|------------------------------------|------------------------------------|
| Q001  | Record vs class lowering           | §5: 16-byte heuristic, with `@valueType`/`@referenceType` overrides |
| Q002  | Sealing opaque types               | §7.2: mangled names + `[Lyric.Opaque]` + AOT trim + analyzer |
| Q003  | Projection cycles                  | §7.3: defers to contract metadata; mandatory `@projectionBoundary` per Q003 recommendation |
| Q004  | Generic constraint markers         | settled by D034 (closed list of 10 markers); §9.4 documents lowering |
| Q005  | Async + `inout`                    | §11.4: enforced by the static analyser; no special IL needed |
| Q006  | `?` in non-error functions         | grammar §7 / contract validator: enforced before IL emission |
| Q007  | `var` capture across async         | §11.5: snapshot by value; cross-await write requires `protected type` |
| Q008  | Concurrent `func` on protected     | §17.4: tri-modal lock selection; barrier entries use `Monitor` (infinite wait, Ada-orthodox); CancellationToken integration deferred to Phase 2 |
| Q009  | Protected type lowering            | §17.1–17.4: tri-modal lock; `Monitor.Wait`/`PulseAll` for barriers |
| Q010  | Task vs ValueTask                  | §14.2: default `Task<T>`; `@hot` opts into `ValueTask<T>` |
| Q011  | Stdlib API surface                 | deferred (Phase 3); §10 discusses derive interaction |
| Q012  | Package registry                   | deferred (Phase 3); `<assembly-name>` mapping is independent |

---

## Appendix C. Self-hosted MSIL emitter (Phase R5/R6)

This document describes the **F# bootstrap** MSIL strategy (Phase 0 design,
Phase 1 implementation).  The self-hosted MSIL compilation pipeline shipped
in Phase R5/R6 and lives in `lyric-compiler/msil/`.  Its design follows the
same strategy but is implemented in Lyric itself.

### Packages

| Package | File | Description |
|---|---|---|
| `Msil.Pe` | `pe.l` | Raw PE binary writer — section headers, directory entries, PE32+ layout |
| `Msil.Opcodes` | `opcodes.l` | IL opcode encoding helpers (M1–M83) |
| `Msil.Tables` | `tables.l` | CLI metadata table helpers — TypeDef, MethodDef, Field, MemberRef, TypeSpec rows |
| `Msil.Heaps` | `heaps.l` | `#Strings`, `#Blob`, `#GUID`, `#US` heap writers |
| `Msil.Assembler` | `assembler.l` | `assemblePe` top-level assembler |
| `Msil.Lowering` | `lowering.l` | High-level MSIL IR (`MsilType`, `MInsn`, `MFunc`, `MRecord`, `MUnion`), signature blob builders (`buildInstanceMethodSig`, `buildStaticMethodSig`), TypeSpec/MemberRef helpers, `lowerMFunc`/`lowerMRecord`/`lowerMPackage` |
| `Msil.Codegen` | `codegen.l` | Typed AST → MSIL IR lowering (`lowerExprMsil`, `lowerStmtMsil`, `lowerFuncMsil`, `typeExprToMsil`) |
| `Msil.Bridge` | `bridge.l` | Entry point `compileToMsil(source, outputPath): Bool` — chains lexer → parser → type checker → codegen → lowering → PE |

### F# bridge

`bootstrap/src/Lyric.Cli/SelfHostedMsil.fs` bootstraps `Msil.Bridge.dll` via a
throwaway driver compile on first use, preloads all stdlib DLLs into the
AppDomain, reflects out `Msil.Bridge.Program.compileToMsil`, and caches the
delegate process-wide.  `--target dotnet` (the default) routes through this
bridge; `--target dotnet-legacy` falls back to the F# bootstrap emitter
(`Lyric.Emitter`) as an escape hatch.

### Self-hosted emitter diagnostics

| Code | Condition | Notes |
|---|---|---|
| `F0015` | `@externTarget` declared signature does not match any overload of the named CLR method in reference-assembly metadata | Fired by `emitExternTargetBody` (Phase 4, `codegen.l`). Shows the declared Lyric signature and the target FQN. Skipped for `out`/`inout` params, generic shapes that have no `SigType` equivalent, and types absent from the metadata index (e.g. Lyric-host types in `Lyric.Emitter.dll`). |
| `F0015-J` | JVM analog of F0015: `@externTarget` declared signature does not match any overload in JDK class metadata | Fired by `lowerExternTargetBody` (Phase 5, `jvm/codegen/04_calls.l`). Silenced when the class is absent from the JDK jmods / `LYRIC_FFI_JARS` index. |

`F0010`–`F0013` are documented in `docs/24-build-features.md` (cfg-erasure diagnostics).

### Key design note: MemberRef signatures on TypeSpecs

Per ECMA-335 §II.14.4.2, a MemberRef whose parent is a TypeSpec (a generic
instantiation such as `List<object>`) must encode method parameter and return
types using `ELEMENT_TYPE_VAR` (0x13 + index) for positions occupied by the
enclosing type's generic parameters — not the concrete instantiated types.
`Msil.Lowering` exposes `MTypeVar(index: Int)` in the `MsilType` union and a
`bufMsilType` helper that emits the two-byte encoding; all TypeSpec MemberRef
setups in `Msil.Codegen` use `MTypeVar` for `List<T>::Add`, `get_Item`, and the
equivalent `Dictionary<K,V>` methods. (D-progress-240)

