# 01 — Language Reference (v0.1)

This document is the authoritative description of the Lyric language at the v0.1 design stage. It is not yet a formal specification; sections marked **[TBD]** require Phase 0 work before implementation.

## 1. Lexical structure

### 1.1 Source representation

Source files are UTF-8 encoded. The file extension is `.l`. Line endings may be LF or CRLF; the lexer normalizes to LF. Source files are case-sensitive.

### 1.2 Identifiers

Identifiers conform to **Unicode UAX #31** (Default Identifier Syntax) with the following restrictions:

- ASCII identifiers are recommended. Non-ASCII identifiers are permitted but the formatter normalizes Unicode identifiers to NFC.
- Identifiers may not begin with `_` followed by a single uppercase letter (reserved for compiler-generated names).
- Identifiers may not match a reserved keyword.

Naming conventions (enforced by the formatter, not the compiler):
- `lowerCamelCase` for values, functions, and parameters
- `UpperCamelCase` for types, interfaces, and packages
- `SCREAMING_SNAKE` for compile-time constants

### 1.3 Keywords

Reserved keywords:

```
alias       and          as           async        await
bind        case         do           else         end
ensures     entry        enum         exposed      extern
false       fixture      for          func         generic
if          impl         import       in           inout
internal    interface    invariant    is           let
match
mut         not          old          opaque       or
out         package      property     protected    pub
record      requires     result       return       scope
scoped      self         singleton    spawn        test
then        throw        true         try          type
union       use          val          var          when
where       while        wire         with         xor
yield
```

`result` is a **contextual** keyword (D086): its only language-level meaning is the
return-value reference inside an `ensures:` clause (§9). The compiler also accepts
`result` as an ordinary local binding / parameter name, and a `result` binding in
scope shadows the contract reference — a read resolves to the binding before the
return-value keyword. Outside an `ensures:` clause (where no such binding exists) a
bare `result` has no meaning.

Annotation-style keywords (always preceded by `@`):

```
@axiom         @bench           @bench_module          @generate
@experimental  @global_clock_unsafe  @hidden           @opaqueHandle
@projectable   @proof_required  @provided              @runtime_checked
@stable        @stubbable       @test_module
```

**Stability annotations** (`@stable` / `@experimental`) mark the API stability of `pub` items (D040):

- `@stable(since="X.Y")` — the item's API is stable from version X.Y and is covered by SemVer guarantees.
- `@experimental` — the item may change without a SemVer major bump.

The compiler enforces one direction: a non-experimental `pub` function may not call an `@experimental` item in the same package (diagnostic S0001). `lyric public-api-diff` uses the stability field to decide whether a removal or signature change is a SemVer-major event (experimental removals are no-ops SemVer-wise).

### 1.4 Literals

**Integer literals** follow Rust's syntax:
```
42          // decimal
0xFF        // hex
0o755       // octal
0b1010      // binary
1_000_000   // underscore separators permitted
100u32      // type suffix: u8, u16, u32, u64, i8, i16, i32, i64
```

C-style leading-zero octal (`0755`) is rejected by the lexer.

An unrecognised suffix on a numeric literal (e.g. `100xyz`) is a lexer error (`L0015`). A based literal with no valid digits after the prefix (e.g. bare `0x`, `0b___` with only underscores) is also a lexer error (`L0016`).

**Float literals**:
```
3.14
2.5e10
1_000.5
3.14f32     // type suffix: f32, f64
```

**String literals**:
```
"hello, world"
"line one\nline two"
"interpolation: ${name}"        // expression interpolation
"escaped: \${not interpolated}"
```

Triple-quoted multiline strings:
```
"""
multi-line
string
"""
```

Raw strings (no escape processing, no interpolation):
```
r"C:\path\to\file"
r#"contains "quotes""#         // hash delimiters for embedded quotes
```

**Character literals**: `'a'`, `'\n'`, `'\u{20AC}'`. Single UTF-16 code unit (BMP scalar, U+0000–U+FFFF excluding the surrogate range U+D800–U+DFFF). Non-BMP code points require a string literal; use `"\u{1F600}"` to embed emoji.

**Boolean literals**: `true`, `false`.

### 1.5 Comments

```
// line comment
/* block comment, may /* nest */ arbitrarily */
/// doc comment for following item (markdown)
//! doc comment for enclosing module (markdown)
```

Doc comments are part of the contract metadata and surface in `lyric doc`. Doctest code blocks are extracted and run by the test harness.

`///` (an *outer* doc comment) attaches to the **item that follows it** and so must precede an item declaration. `//!` (an *inner* doc comment) documents the **enclosing module** and is the correct form for a file-header doc block at the top of a source file — i.e. *before* the `package` declaration. A `///` placed before `package` has no item to attach to and is rejected with `error[P0020]: a '///' doc comment before 'package' has no item to document; use '//!' for a module-level doc comment`.

### 1.6 Whitespace and significance

Whitespace is not significant beyond token separation. Statements are terminated by newlines; semicolons are optional but permitted for multiple statements on one line. Blocks use braces.

## 2. Type system

### 2.1 Primitive types

| Type | Description | Range |
|---|---|---|
| `Bool` | Boolean | `true`, `false` |
| `Byte` | 8-bit unsigned | `0 ..= 255` |
| `Int` | 32-bit signed | `-2_147_483_648 ..= 2_147_483_647` |
| `Long` | 64-bit signed | full Int64 range |
| `UInt` | 32-bit unsigned | `0 ..= 4_294_967_295` |
| `ULong` | 64-bit unsigned | `0 ..= 2^64 - 1` |
| `Nat` | non-negative Long | `0 ..= 2^63 - 1` |
| `Float` | 32-bit IEEE 754 | per IEEE 754-2019 |
| `Double` | 64-bit IEEE 754 | per IEEE 754-2019 |
| `Char` | UTF-16 code unit (BMP scalar) | U+0000..U+FFFF excl. U+D800..U+DFFF |
| `String` | immutable UTF-8 | unbounded |
| `Unit` | unit type | single value `()` |
| `Never` | bottom type | uninhabited |

Integer arithmetic panics on overflow in checked builds (default for `--debug`). In `--release` builds, overflow on unconstrained integer types wraps; range-constrained subtypes always panic on overflow regardless of build mode.

Floating-point follows IEEE 754-2019 with default rounding mode (round-to-nearest-even) and traps disabled. NaN comparisons follow the standard (`NaN != NaN` is `true`, `NaN < x` is `false` for all `x`).

### 2.2 Range subtypes

A range subtype constrains a numeric type to a contiguous range:

```
type Age = Int range 0 ..= 150
type Cents = Long range 0 ..= 1_000_000_000_00
type DiceRoll = Int range 1 ..= 6
```

Range subtypes are **distinct types**. `Age + Int` is a compile error; conversion is explicit:

```
val age: Age = Age.tryFrom(human.years)?
val total: Int = age.toInt() + 5
```

Range-violating values cause a runtime check failure on construction (`tryFrom` returns `Result`; `from` throws `System.ArgumentOutOfRangeException` on .NET). JVM bounds-checking is not yet implemented (tracked in #2997). Inside a `@proof_required` module, the prover discharges the range obligation statically; runtime checks are elided when proof succeeds.

Range syntax:
- `a ..= b` — closed range, both endpoints included
- `a .. b` — half-open, `b` excluded
- `..= b` — `MIN ..= b`
- `a ..` — `a ..= MAX`

A range refinement may also appear inline as a type annotation
(`val x: Int range 0 ..= 9 = 5`). An inline refinement is transparent for type
equivalence — it is interchangeable with its underlying numeric type — but when
the initialiser is an integer literal outside the declared bounds the compiler
rejects it at compile time (**T0015**). (Validating *non-literal* constructions
of a refined type is a runtime/proof obligation, as above.)

### 2.3 Distinct types

Type aliases vs. distinct types:

```
alias Distance = Long          // structurally identical to Long
type UserId = Long             // distinct nominal type
type OrderId = Long            // also distinct from UserId
```

A type alias is fully transparent: `alias Distance = Long` introduces no new type, and `alias` may re-export a type from another module (`alias Random = Std.RandomHost.Random`) so callers need only import the re-exporting module. Alias targets are resolved transitively through chains (`alias B = Foo; alias C = B`); a cyclic alias chain (`alias A = B` with `alias B = A`) does not denote a type and is rejected at compile time (**T0017**).

`UserId + OrderId` is a compile error. `UserId.toLong()` and `Long.toUserId(x)` (where the latter exists only if explicitly declared) are the conversion paths. Distinct types from underlying primitives may declare which arithmetic operations are inherited:

```
type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare
type UserId = Long derives Compare, Hash    // no arithmetic on user IDs
```

Available derives: `Add`, `Sub`, `Mul`, `Div`, `Mod`, `Compare`, `Ord`, `Hash`, `Equals`, `Default`. `Ord` synthesises a total ordering (`compare(self, other): Int` returning negative/zero/positive); valid on records, unions, enums, and distinct types. Numeric distinct types with `Add`/`Sub` permit operations only with values of the *same* type. `derives Default` is rejected when the underlying primitive's default value falls outside the declared range. The closed marker set is fixed by D034; see `docs/03-decision-log.md`.

### 2.4 Records

```
record Point {
  x: Double
  y: Double
}

record Customer {
  id: CustomerId
  email: Email
  joinedAt: Instant
  isActive: Bool
}
```

Records are value types (compile to .NET `readonly struct` for primitives, `record class` otherwise — see `docs/09-msil-emission.md` §5 for the selection rule). Records have structural equality by default. Construction:

```
val p = Point(x = 1.0, y = 2.0)
val p2 = p.copy(x = 3.0)        // non-destructive update
```

All fields must be named at construction. Positional construction is rejected by the parser.

Constructor calls must use an unqualified type name — `Point(x = 1.0, y = 2.0)`, not `Pkg.Point(x = 1.0, y = 2.0)`. A qualified path is not recognised as a constructor call; use `import` to bring the type name into scope.

Every type reference in a declaration position is validated when the package is checked: record and exposed-record fields, union case fields, interface member signatures, opaque and protected type fields, member function signatures, `alias` targets, and module-level `val`/`const` annotations. A name that resolves to no type in scope is a compile error at the declaration (**T0010** for an unknown simple name, **T0014** for an unknown qualified path, **T0013** when the name resolves to a non-type) — it never degrades silently to a host `Object`.

**Mutable record fields (`var`):** A field may be prefixed with `var` to signal that it is intended to be mutated by the record's owning code:

```
record Counter {
  var count: Int
  label: String
}
```

The `var` prefix is accepted by the parser. The self-hosted parser (`lyric-compiler/lyric/parser/`) consumes the keyword but does not yet carry a mutability flag in `FieldDecl` — the resulting AST node is identical to a non-`var` field. Full AST tracking and mutability enforcement (preventing external reassignment, restricting write sites to the owning package) are tracked as T6+ type-checker work; the emitter currently treats `var` and non-`var` fields identically at the IL/bytecode level. The syntax is intentionally similar to local `var` declarations so that the intention is clear in code review.

### 2.5 Unions (sum types)

```
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Triangle(base: Double, height: Double)
}

union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}
```

Pattern matching is exhaustive. The compiler refuses to compile a `match` that doesn't cover all cases or include a wildcard (**T0016**); a guarded arm (`case … if …`) does not count toward coverage because its guard may fail. For union and enum scrutinees every case must be matched (or a `_`/binding catch-all supplied); a `Bool` match must cover both `true` and `false`; a match on an unbounded scalar (`Int`, `String`, `Char`, …) requires a `_` arm:

```
val area = match shape {
  case Circle(r) -> 3.14159 * r * r
  case Rectangle(w, h) -> w * h
  case Triangle(b, h) -> 0.5 * b * h
}
```

Adding a new variant to a `pub` union is a breaking change.

### 2.6 Enums

```
enum Color {
  case Red
  case Green
  case Blue
}
```

Enums are unions with no payload. Values are distinct from integers; explicit conversion is required to interoperate with numeric APIs. Ordinals are non-negative — `.toNat()` returns the zero-indexed ordinal as `Nat`, and `Color.fromNat(n): Option[Color]` converts back (returning `None` for out-of-range values). **Status: specified; compiler synthesis of `toNat`/`fromNat` is planned for v1.0 and not yet shipped.**

### 2.7 Arrays and slices

```
val fixed: array[16, Byte]        // fixed-size, length in type
val dynamic: slice[Int]            // dynamic length
val empty: slice[Int] = []
val literal = [1, 2, 3]            // type inferred as slice[Int]
```

Array indexing is bounds-checked. The check is elided in release builds when the index type's range proves the access is in-bounds (this is one of the practical payoffs of range subtypes):

```
val xs: array[100, Int]
val i: Int range 0 ..= 99 = ...
val v = xs[i]                      // no runtime bounds check; proof discharged
```

### 2.8 Opaque types

```
opaque type AccountId
opaque type Account {
  balance: Cents
  invariant: balance >= 0
}
```

An `opaque` declaration in the type's package specifies its existence; the body is only visible inside the same package. Outside the package:

- Clients can declare values of the type, pass them around, store them.
- Clients cannot read fields, construct values directly, or pattern-match on representation. The type checker enforces this: cross-package direct construction is a compile error (**T0100**), and cross-package pattern-matching of the representation (a record or constructor pattern) is a compile error (**T0102**). Binding or wildcard match arms remain legal — the value is opaque but usable.
- Reflection cannot inspect the type's fields. The compiler emits the type with sealed metadata: no public properties, no exposed constructor, fields marked invisible to .NET reflection (uses `[CompilerGenerated]` + sealed attribute scheme — see `docs/09-msil-emission.md` §7.2).
- The proof system can reason about the type's invariants because they're declared in the spec.

Inside the package, the opaque type is an ordinary record. Authoring functions provide controlled construction and access.

### 2.9 Projectable opaque types

```
opaque type User @projectable {
  id: UserId
  email: Email
  createdAt: Instant
  passwordHash: PasswordHash @hidden
  invariant: email.isVerified or createdAt > now() - days(7)
}
```

The `@projectable` annotation directs the compiler to generate a sibling `exposed record UserView` with:

- All non-`@hidden` fields, recursively projected if their types are also `@projectable`
- Opaque field types kept as opaque handles if not `@projectable`
- A projection function `User.toView(self): UserView`
- A reverse function `UserView.tryInto(self): Result[User, ContractViolation]` that runs the invariant

Configurable surfaces:

```
@projectable(json, sql)            // only generate for these targets
@projectable(version = 2)          // versioned views: UserViewV2
```

Cycles in the projection graph require explicit `@projectionBoundary` markers — see `docs/03-decision-log.md` D026 for the resolved syntax.

### 2.10 Exposed records

```
exposed record TransferRequest @generate(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
}
```

`exposed` types are flat, host-visible, and may be inspected by reflection. They compile to plain .NET `record class` types. They cannot have invariants beyond what the type system enforces structurally (no `invariant:` clause). They are intended for wire-level shapes — DTOs, log payloads, config records.

`@generate(Json)`, `@generate(Sql)`, `@generate(Proto)` invoke built-in source generators that emit serializers at compile time. No runtime serialization library is needed. Third-party generators are invoked with dotted names (`@generate(Pkg.Name)`); see `docs/40-source-generators.md` and D075.

An `opaque` type cannot have an `exposed` field. An `exposed` type may hold an opaque field, but only as an opaque handle — the inner representation remains hidden.

### 2.11 Generics

Generics are monomorphized. Each instantiation produces a concrete type at compile time. Type parameters appear in brackets immediately after the declared name:

```
func identity[T](x: T): T = x

func unwrapOr[T, E](r: Result[T, E], default: T): T = ...

record Box[T] {
  value: T
}
```

(The legacy `generic[T] func identity(x: in T): T = x` form parses for back-compat. Prefer the bracket form in new code; mixed-mode `: in T` is also still legal but redundant.)

Constraints expressed via `where`:

```
func sum[T](xs: slice[T]): T
  where T: Add + Default
{
  var total = T.default()
  for x in xs { total = total + x }
  return total
}
```

Constraints may be user-defined interfaces or built-in trait-like markers. The closed set of built-in markers is `Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Add`, `Sub`, `Mul`, `Div`, `Mod` (see decision log D034). All but `Copyable` are also valid in `derives` clauses; `Copyable` is structural — it asserts the type lowers to a CLR value type. An unrecognised constraint name in a `where` clause (e.g. a typo) produces a **T0111** warning — the constraint is treated as satisfied at compile time, but the warning surfaces likely typos without breaking code that references cross-package interfaces not yet visible.

Type arguments in instantiations (e.g. `Box[Int]`) must be type expressions. Writing a value expression where a type argument is expected is a compile error (**T0109**). Generic record and union constructors infer their type arguments from the supplied field values when every type parameter appears in at least one field (named arguments may be given in any order); `Pair(first = 1, second = "x")` types as `Pair[Int, String]` with no annotation. When one or more type parameters cannot be inferred — a phantom parameter that appears in no field, or an uninferable argument shape — the constructor call is a compile error (**T0110**) naming the unresolved parameter(s); supply explicit type arguments (`Tagged[Int, Meters](value = 1)`) to resolve it. A missing required field is reported as a missing-field error (**T0105**), not T0110.

Value generics:

```
generic[T, N: Nat] record FixedVec {
  data: array[N, T]
}
```

Package generics (Ada-style parameterization of whole modules) are deferred to v2.

### 2.12 Interfaces

```
interface Repository[T, Id] {
  async func findById(id: in Id): T?
  async func save(entity: in T): Unit
}

@stubbable
interface Clock {
  func now(): Instant
}
```

Implementations declared with `impl`:

```
impl Repository[User, UserId] for PostgresUserRepository {
  async func findById(id: in UserId): User? {
    // ...
  }
  async func save(entity: in User): Unit {
    // ...
  }
}
```

**Impl-block generics and generic interface methods** are supported:

- An impl block can carry its own type parameters with `impl[T] Iface for Target[T] { … }`.
  The type parameters correspond to the target record's own class-level GTPBs.
- An interface or impl method can be generic with the bare-bracket form
  `func name[U](x: in U): U`.  This makes the CLR method itself generic;
  call sites emit `MakeGenericMethod` with type arguments inferred from
  the argument expressions.
- Both forms may be combined:
  `impl[T] Transformer for Container[T] { func transform[U](x: in U): U = x }`.

Async state-machine lowering for generic impl methods (Phase B SM) is deferred;
generic async impl methods fall back to the `Task.FromResult` path.

Interfaces support default methods. Interfaces may be stable or `@stubbable` (generates a stub builder for tests; see §10).

Multiple inheritance of interfaces is permitted; diamond conflicts are resolved by requiring explicit override.

## 3. Visibility

### 3.1 Visibility tiers

Three visibility tiers are recognised:

| Modifier | Cross-project surface | Cross-package surface inside the project | Package-internal |
|---|---|---|---|
| `pub` | Visible | Visible | Visible |
| `internal` | Hidden | Visible | Visible |
| (unmarked) | Hidden | Hidden | Visible |

By default, declarations are package-private (visible only within the same package). The `pub` keyword exposes a declaration as part of the package's external contract; the `internal` keyword (Phase 5 §M5.1 stage 2c addition) exposes it across packages within the same project but hides it from external consumers.

Visibility is enforced at use sites: referencing a package-private declaration (no modifier) from another package is a compile error (**T0097**). `pub` and `internal` declarations are both referenceable across packages within a project; the cross-*project* hiding of `internal` is enforced by the publish/restore layer, which only includes `pub` declarations in a package's external contract. Extern types / extern packages (FFI host-binding declarations, e.g. the `List`/`Map` aliases) are not subject to these tiers — their cross-package use is governed by the kernel-boundary convention.

A public function that exposes an **imported nested** host extern type (a CLR FQN containing `+`, e.g. `System.Text.Json.JsonElement+ArrayEnumerator`) in its signature emits a warning (**W0006**): these are host implementation-detail structs whose FFI boundary is meant to stay in the `_kernel/` layer. A kernel file that *declares* the extern type locally is exempt; the fix for a consumer is to wrap the host type in an opaque Lyric type (as `Std.Json` does with `JsonArrayCursor` / `JsonObjectCursor`). Top-level domain extern types (e.g. `JsonElement` itself) are deliberately re-exposable and are not flagged.

```
pub type AccountId = Long range 0 ..= MAX_ACCOUNT_ID
pub func openAccount(owner: in CustomerId): AccountId

internal func projectVisible(x: in Int): Int   // visible to other
                                                // packages in this project,
                                                // hidden from consumers

func packagePrivate(x: in Int): Int             // package-private
```

For records:

```
pub record Customer {
  pub id: CustomerId          // visible field
  pub email: Email
  internal billingId: Long    // cross-package within project
  internalNotes: String       // package-private field
}
```

A `pub` record may have non-`pub` fields, but constructing the record from outside the package requires every field to be `pub`. Outside callers use a constructor function the package provides.

For opaque types, `pub opaque type T` exposes the type's existence but not its representation. The fields inside `opaque type T { ... }` are always invisible to clients, regardless of `pub`/`internal` markers.

`internal` symbols are excluded from the `Lyric.Contract` resource embedded in published DLLs (per §3.3) — downstream consumers reading the contract see only the `pub` surface. Internal-to-internal references resolve through the in-process symbol table when the project is built as a single DLL (per `docs/20-project-as-dll.md`); the tier is principally useful when paired with `output = "single"` mode.

### 3.2 Test-module access

Modules annotated `@test_module` may access non-`pub` declarations of the package they test:

```
@test_module
package Account

test "internal helper handles edge case" {
  expect(internalHelper(0) == 0)
}
```

This is the only mechanism for crossing the visibility boundary. Test modules have no access to opaque types' representations from packages they don't test (the boundary is per-package).

### 3.3 Contract metadata emission

For every package, the compiler emits two artifacts:

- `<package>.lyrasm` — the .NET assembly containing IL for executing the code
- `<package>.lyric-contract` — JSON-encoded contract metadata: `pub` declarations, signatures, contracts, generic parameters, projection types

Downstream packages depend on the contract metadata for incremental compilation. Body changes that don't affect `pub` declarations don't invalidate downstream compilation caches.

Binary distribution publishes both artifacts together. The contract metadata is what consumers compile against; the assembly is what they link to and run.

### 3.4 Optional split-file mode

Projects may opt into split-file authoring at the project level (in `lyric.toml`):

```toml
[project]
file_layout = "split"   # default: "unified"
```

In split mode, packages are authored as `<package>.lspec` (containing `pub` declarations only) and `<package>.lbody` (containing implementations). Semantics are identical to unified files; the split is purely an authoring choice for teams that want Ada-style discipline.

### 3.5 Build kind — `[build]`

A project's `lyric.toml` may declare an output kind that controls what artifact `lyric build` produces on the **.NET** target:

```toml
[build]
kind = "exe"   # default: "lib"
```

| `kind` | Artifact | Runs as | Runtime needed? |
|---|---|---|---|
| `"lib"` | managed `<name>.dll` + `<name>.runtimeconfig.json` | `dotnet exec <name>.dll` | .NET runtime |
| `"exe"` | the above **plus** a native apphost launcher `<name>` (`<name>.exe` on Windows) | `./<name>` directly | .NET runtime (framework-dependent) |
| `"bundle"` | self-contained launcher with the runtime bundled | `./<name>` | none — *planned, not yet emitted* |
| `"aot"` | native ahead-of-time compiled binary | `./<name>` | none — Linux (`x64`/`arm64`) and macOS; system compiler/linker required on `PATH` |

`kind = "exe"` writes a *native* launcher beside the managed DLL by binding the .NET SDK's apphost template (the launcher boots the CLR and runs the assembly), so the program starts with `./myapp` instead of `dotnet myapp.dll`. When several `Microsoft.NETCore.App.Host.<rid>` packs are installed, the one matching the host runtime identifier (`Std.Environment.runtimeIdentifier()`) is preferred, so the correct architecture is selected on cross-compilation machines. It is still framework-dependent — a .NET runtime must be installed. `bundle` is accepted by the manifest parser but not yet emitted; declaring it is a hard build error rather than a silent fallback. `kind = "aot"` is implemented on Linux (`x64` and `arm64`) and macOS: `lyric build` invokes `ilc` and the platform linker (`clang` or `ld64`) directly — no generated C#, no `dotnet publish` — and produces a self-contained native binary with no .NET runtime dependency. A system linker must be on `PATH` (e.g. `apt install clang` on Debian/Ubuntu, or Xcode Command Line Tools on macOS). Windows is tracked in #1975. `lyric build --release` (§ below) is equivalent to using `kind = "aot"` in the manifest. On the **JVM** target, `kind` is currently a no-op (the `.jar` is already self-launching via `java -jar`).

## 4. Expressions

### 4.1 Operator precedence

Lyric adopts the **Swift operator precedence table** as its base, with the following modifications:

- Bitwise operators are not symbolic — use `.and()`, `.or()`, `.xor()`, `.shl()`, `.shr()` methods on integer types. This sidesteps the C-family precedence trap with `&` and `==`.
  - `.shl(n: Int)` — logical left shift by `n` bits.  Equivalent to multiplication by `2^n`; high bits are discarded.
  - `.shr(n: Int)` — **arithmetic** right shift on signed integer types (`Byte`, `Int`, `Long`).  Sign bit is replicated into the vacated high bits, so negative inputs stay negative (`-1.shr(1) == -1`).  Unsigned types (`UInt`, `ULong`) get **logical** right shift (zero-extended).  This matches the .NET runtime's distinction between `>>` on `int` (arithmetic) and `int.UnsignedRightShift` / `>>>` introduced in .NET 7.  Protobuf zigzag encoders rely on this signed/unsigned split — see lyric-proto #361 for the RFC vector tests that pin the behaviour.
- **Numeric / character conversions are explicit** — Lyric performs no implicit numeric widening or narrowing.  The numeric and character primitives `Byte`, `Int`, `Long`, `Double`, and `Char` carry the conversion methods `.toByte()`, `.toInt()`, `.toLong()`, `.toChar()`, and `.toDouble()`, each yielding the named target type.  Widening (`Int.toLong()`, `Int.toDouble()`) is lossless; narrowing (`Long.toInt()`, `Double.toInt()`) truncates toward zero, and `.toByte()` reduces modulo 256 to the **unsigned** `0..255` range (`Byte` is unsigned).  These are the surface form for mixing widths — e.g. summing a `slice[Byte]` element into an `Int` accumulator is `acc + b.toInt()`, never `acc + b`.  (Conversions on the unsigned integers `UInt`/`ULong`/`Nat` and `.toFloat()` are reserved pending backend support for those representations; calling a conversion method on `String`/`Bool`/`Unit` is a `T0103` error.)
- Chained comparisons follow **Rust's rule**: `a < b < c` is a parse error, not `(a < b) < c`. Comparison operators do not associate.
- The ternary `?:` operator does not exist. Use `if expr then a else b`.
- The `?` operator (error propagation) has its own precedence level immediately above postfix.

Full precedence table (from highest to lowest):

| Level | Operators | Associativity |
|---|---|---|
| postfix | `f(x)`, `a[i]`, `.field`, `?` (propagation) | left |
| prefix | `-x`, `not x`, `&x` | right |
| range | `..`, `..=` | non-associative |
| multiplicative | `*`, `/`, `%` | left |
| additive | `+`, `-` | left |
| nil-coalescing | `??` | right |
| comparison | `==`, `!=`, `<`, `<=`, `>`, `>=` | non-associative (no chaining) |
| logical-and | `and` | left |
| logical-or | `or`, `xor` | left |
| assignment | `=`, `+=`, `-=`, `*=`, `/=`, `%=` | right |

Reference: [Swift Language Reference — Expressions](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/expressions/), with the deltas above.

### 4.2 Pattern matching

```
val description = match shape {
  case Circle(r) where r > 100.0 -> "large circle"
  case Circle(r) -> "circle of radius ${r}"
  case Rectangle(w, h) if w == h -> "square"
  case Rectangle(w, h) -> "rectangle"
  case _ -> "other"
}
```

Patterns:
- Literal patterns: `42`, `"hello"`, `true`
- Variable binding: `x`
- Wildcard: `_`
- Constructor patterns: `Circle(r)`, `Some(x)`
- Tuple patterns: `(a, b)`
- Record patterns: `Point { x, y }`, `Point { x = 0.0, y }` (destructure with literal match on `x`)
- Range patterns: `0 ..= 9`
- Const patterns: `@NAME` — compares the scrutinee against the value of a compile-time `val` or `const` named `NAME`. The `@` prefix disambiguates from a binding pattern (`case x ->` always binds a new variable; `case @X ->` compares against the existing constant `X`). The referenced name must resolve to a `val` initialized with a literal, or a `const` declaration. Diagnostic T0069 is raised when the val is not compile-time constant, T0068 when the type does not match the scrutinee, T0071 when the const is generic, and T0072 when the name is not a val or const.
- Guard clauses: `case ... where condition`

Exhaustiveness is enforced. The compiler tracks variant coverage and rejects incomplete matches without `case _`.

### 4.3 Control flow

`if`/`else` is an expression whose type is the **unified type of its branches**
— both arms must have compatible types (a mismatch is a compile error). A
branch that diverges (`return`/`throw`/`break`/`continue`/`panic`) has the bottom
type and does not constrain the other arm, so `if c { x } else { return d }` is
typed by its `then` branch. An `if` *without* an `else` produces no value on the
false path and so has type `Unit`.
```
val x = if cond then a else b
```

A brace-terminated `if` or `match` written in **statement position** (not as the
right-hand side of a binding or another expression) is a *complete statement*: a
binary operator after the closing `}` (whether on the same line or the next)
begins a **new** statement rather than continuing the block expression. So
```
if cond { return x }
-1                      // a separate statement — the fall-through value
```
is two statements, not `(if cond { return x }) - 1`. In value position the `if`
is an ordinary operand, so `val y = if c { a } else { b } + 1` parses as
`(if …) + 1` — wrap the block expression in parentheses if you need it as an
operator's left operand at statement position. (This mirrors Rust's
"expression-with-block" rule and resolves the `}`-then-leading-operator
ambiguity.)

`while` and `for` are statements:
```
while condition { ... }

for x in collection { ... }

for i in 0 ..< 10 { ... }
```

The `for` binding must be an **irrefutable** pattern — a name, `_`, or a tuple
of those (parentheses allowed). A refutable pattern (a constructor pattern such
as `Some(v)`, a record pattern, a literal, or a range) is a compile error
(**T0112**), because a `for` loop has no failure path for a non-matching
element. Destructure refutable shapes with a `match` inside the loop body
instead.

`do ... while` does not exist. Use `while true { ... if cond { break } }`.

Loop control: `break`, `continue`. Both may take a label for nested loops:
```
outer: for x in xs {
  for y in ys {
    if done { break outer }
  }
}
```

`defer { ... }` schedules a block to run when its enclosing scope exits, on
**every** path — normal fall-off, early `return`, `break`/`continue` out of the
scope, and exception unwind ("success or failure"). Use it for cleanup that must
always happen:
```
val src = makeCancelSource()
defer { disposeSource(src) }      // runs no matter how this scope ends
val result = work(src)
result
```
Multiple `defer`s in the same scope run in **reverse** declaration order (the
last `defer` runs first), mirroring nested cleanup. A `defer` block reads the
variables it references at scope-exit time, not at the point of declaration.

### 4.4 Bindings

```
val x = 42                  // immutable
var y: Long = 100           // mutable
let z: Int = expensive()    // lazy, evaluated on first use
```

`val` is the default; mutability requires explicit `var`. Lazy bindings (`let`) are thread-safe — the standard library uses .NET's `Lazy<T>` semantics.

Type annotations are optional when inference can resolve the type. Function parameter types and return types are mandatory; `pub` declaration types are mandatory.

**Immutability of `val` and `in` bindings is reference-level, not deep.**  A `val`
binding or an `in` function parameter prevents *rebinding* — you cannot write
`x = newValue` — but it does not make the *referenced object* immutable.  If `items`
is a `val` or `in List[T]`, `items.add(x)` is a valid call because `add` mutates
the heap-allocated list object, not the binding itself.  This is standard
reference-immutability: the pointer is frozen, the data is not.

This is a common source of confusion with `in List[T]` parameters: callers may
expect the list to be read-only, but the callee can still append, remove, or clear
it.  If you need a read-only view of a collection, accept `in slice[T]` (slices do
not expose mutation methods) or copy on entry.  For the full mode rules see §5.2.
Attempting to rebind any immutable binding — a `val`, `let`, or `in` parameter
(e.g. `param = otherList`) — is a compile error (**T0087**).

### 4.5 Error propagation

The `?` operator propagates errors:

```
async func handleTransfer(req: TransferRequest): HttpResponse {
  val from = AccountId.tryFrom(req.fromId)?
  val amount = Amount.make(req.amountCents)?
  val result = transfer(from, ..., amount)?
  return HttpResponse.ok(result)
}
```

`?` works on `Result[T, E]` and `Option[T]` (and `T?` nullable, which lowers to `Option`). For `Result`, `e?` evaluates `e`: on `Ok(v)` it yields `v` and execution continues; on `Err(x)` the enclosing function immediately returns `Err(x)`. For `Option`, `e?` yields `v` on `Some(v)` and returns `None` from the enclosing function on `None`. The signature must declare a compatible return type, or the compiler rejects the use with `F0020` (the enclosing function returns neither `Result` nor `Option`). See `docs/03-decision-log.md` D027 for the resolved nullable rule.

The `??` operator is null-coalescing:
```
val name = user.nickname ?? user.email
```

## 5. Functions and parameter modes

### 5.1 Function declaration

```
func add(x: Int, y: Int): Int = x + y

func balanceOf(account: Account): Cents
  ensures: result == account.balance
{
  return account.balance
}

async func loadUser(id: UserId): User? {
  // ...
}
```

Parameters carry one of three modes: `in`, `out`, or `inout`. Omitting the keyword defaults to `in`, the read-only mode used by ~all parameters; `out` and `inout` must be written explicitly when wanted.

A parameter may carry leading annotations, written before the parameter name:

```
@post("/users")
func handleCreateUser(@body req: in CreateUserRequest, authToken: String): Result[String, ApiError]
```

The language itself attaches no semantics to parameter annotations; they are
metadata consumed by libraries and source generators. For example, lyric-web
reads `@body` to choose which parameter receives the deserialised request body
(falling back to the last non-path, non-query parameter when no `@body` is
present).

### 5.2 Parameter modes

- `in`: parameter is read-only inside the function. **Default mode** when no keyword is given. The compiler may pass by value or by reference; the function cannot mutate.
- `out`: parameter must be assigned before the function returns. Used for output parameters; the caller passes an uninitialized binding. Equivalent to C# `out`. The type checker rejects an `out` parameter that is never assigned in the body (**T0086**); full all-paths definite-assignment (catching assignment on some but not all paths) is a planned refinement.
- `inout`: parameter is read/write. Caller passes a mutable binding; function may read and modify. Equivalent to C# `ref`.

At a call site, an argument bound to a **value-type** `out`/`inout` parameter must be a writable l-value — a `var` local, an `out`/`inout` binding, or a mutable field access (`obj.field`, where the field is reachable for assignment) (**T0085**). A literal, a call result, or an immutable (`val`/`let`/`in`) binding is rejected, because the callee writes a value back into the argument. Reference-type by-ref parameters (records, `String`, slices) are mutated in place through the reference, so this requirement does not apply to them.

```
func divmod(n: Int, d: Int, q: out Int, r: out Int) {
  q = n / d
  r = n % d
}

func incrementAll(xs: inout slice[Int]) {
  for i in 0 ..< xs.length {
    xs[i] = xs[i] + 1
  }
}
```

Mode rules:
- `out` parameters must be definitely assigned on every control-flow path before return.
- `inout` parameters must be passed mutable bindings; immutable values cannot be passed.
- Async functions cannot have `out` or `inout` parameters that are non-record value types crossing await points (the value would be aliased across awaits — see `docs/09-msil-emission.md` §11.4).
- `in` prohibits **rebinding** the parameter (the name cannot be assigned a new value inside the function body) but does not prevent mutation through a mutable container type. A parameter declared `in` may call mutating methods such as `list.add(x)` on a `List[T]` value — the reference itself is immutable, not the heap object it points to. Direct reassignment (`param = ...`) of an `in` parameter — like reassigning a `val`/`let` — is a compile error (**T0087**), enforced by the type checker for all packages (not only proof-required code). It fires only on direct assignment, not on mutating method calls. (The §5.2 draft originally numbered this rule `V0001`; that code is owned by the proof-import mode-checker rule, so the type-checker-enforced rule uses T0087.)

### 5.3 Return values

`Unit` is the default return type if omitted. A function with `Unit` return type may omit `return`.

Multiple return values use tuples:
```
func minMax(xs: in slice[Int]): (Int, Int) {
  // ...
}

val (lo, hi) = minMax(xs)
```

### 5.4 Closures and lambdas

```
val add = { x: Int, y: Int -> x + y }
val numbers = [1, 2, 3]
val doubled = numbers.map { x -> x * 2 }
```

Closures capture values by reference for `var` bindings, by value for `val` bindings (this matters across thread boundaries; capturing `var` across an `async` boundary requires explicit `mut` synchronization — see `docs/09-msil-emission.md` §11.5).

A lambda whose body diverges (every path panics, throws, or returns out of the enclosing function) types as `() -> Never`. Because `Never` is the bottom type, such a function value satisfies a function-typed parameter with **any** declared return type, provided the parameter lists match — `assertPanics("boom", { -> panic("x") })` passes a `() -> Never` lambda where `() -> Unit` is expected. The parameter types themselves are matched invariantly (the call ABI must agree).

## 6. Contracts

### 6.1 Contract clauses

Functions may declare:

```
func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}
```

- `requires`: precondition. Boolean expression evaluated on entry. Failure raises `PreconditionViolated` (a `Bug`).
- `ensures`: postcondition. Boolean expression evaluated on return. Has access to `result` (the return value) and `old(expr)` (value of `expr` at entry).
- `requires` and `ensures` clauses may be repeated for clarity:

```
func transfer(...): Result
  requires: amount > 0
  requires: from != to
  ensures: result.isOk implies fromBalance.decreased
{
  // ...
}
```

### 6.2 Type invariants

Records and opaque types may declare invariants:

```
opaque type Account {
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}
```

Invariants must hold:
- After every public function in the type's package returns
- At every observation by code outside the package
- On every parameter of the type passed into a function
- On every return value of the type

Internal mutations may temporarily violate the invariant; the invariant is checked when control returns to a public boundary.

### 6.3 Contract expression sublanguage

Contract expressions are pure: no side effects, no I/O, no mutation. They may use:
- Standard arithmetic and comparison operators
- Calls to functions explicitly marked `@pure`
- `forall` and `exists` over finite ranges or collections (decidable fragment for proof; in `@runtime_checked` modules these are approximated as `true` — a sound over-approximation that does not verify the quantified property at runtime)
- `old(expr)` in `ensures` clauses — captures the value of `expr` at function entry; the elaborator inserts a `let __old_N = expr` snapshot before any `requires` assertions
- `result` in `ensures` clauses
- `implies` (`a implies b` ≡ `not a or b`)

Contract expressions cannot:
- Call non-`@pure` functions
- Allocate
- Mutate state
- Throw

### 6.4 Module verification levels

Each package declares a verification level:

```
@runtime_checked
package Account
```

- `@runtime_checked` (default): contracts are runtime asserts. Enabled in debug, configurable in release.
- `@proof_required`: SMT solver must discharge every contract obligation at compile time. Modules at this level may only call other `@proof_required` modules, primitives, or modules behind explicit `@axiom` boundaries.
- `@proof_required(unsafe_blocks_allowed)`: as above, with `unsafe { ... }` escape hatches that the prover treats as opaque.

### 6.5 Axiom boundaries

Calling into unverified code (the .NET BCL, exposed external libraries) requires an axiom boundary:

```
@axiom("System.IO.File.ReadAllText reads the file content")
extern func readFile(path: in String): String
  ensures: result != null     // assumed, not proved
```

The contract on the extern declaration is treated as an axiom by the prover. Wrong axioms produce wrong proofs, so axiom boundaries are heavyweight by design — they're visible in code review and listed in the package's contract metadata.

## 7. Concurrency

### 7.1 Async functions

```
async func fetchUser(id: in UserId): User? {
  val response = await http.get("/users/${id}")
  return User.parseJson(response.body)
}
```

`async func` returns a value of type `Task[T]` (compiles to .NET `Task<T>` or `ValueTask<T>` per heuristic — see `docs/09-msil-emission.md` §14.2). `await` is a postfix operation in expression position.

**Restriction — `out`/`inout` parameters:** `out` and `inout` parameters create byref slots that are incompatible with async state-machine classes (the CLR prohibits byref field types on state-machine classes). If an `async func` declares an `out` or `inout` parameter, the emitter stores a copy of the value in the state-machine rather than the reference — the caller's variable is not updated. The compiler emits warning `A0001` to flag this condition; the recommended fix is to return a `Result` or a record instead.

### 7.2 Async generators

An `async func` whose body contains at least one `yield` expression is an *async generator*. Its return type must be a scalar element type `T`; the compiler infers the public signature as `IAsyncEnumerable[T]` (.NET) or `Iterable<T>` (JVM). The caller iterates with `for x in f(args) { … }`.

```
async func naturals(limit: in Int): Int {
  var i = 0
  while i < limit {
    yield i
    i = i + 1
  }
}

func main(): Unit {
  for n in naturals(5) {
    println(toString(n))  // prints 0 1 2 3 4
  }
}
```

`yield expr` is a statement-expression: it evaluates `expr`, queues the value, and continues. A `yield` inside a non-generator function or outside an `async func` is a compile error (T0094). The type of `expr` must match the function's declared element type (T0095); every `yield` in the same generator must produce a value of the same type.

`yield` binds its argument tightly — `yield a * 2` means `yield (a * 2)`, not `(yield a) * 2`. Note that `await` uses postfix precedence — `await a * 2` means `(await a) * 2`. The asymmetry is deliberate; `yield` is a statement-level construct and binds with expression precedence, while `await` acts on a single postfix operand.

The compiler selects one of two lowering strategies based on the body's content:

**Eager-producer** (body has `yield` but no `await`): the generator body runs to completion synchronously when the caller first calls `GetAsyncEnumerator`, buffering all yielded values in a `List<T>` that `MoveNextAsync` serves one at a time. Correct for generator comprehensions and producer pipelines.

*Constraints for eager-producer generators:* (a) The generator class is single-use per instance — calling `GetAsyncEnumerator` on the same instance concurrently (e.g. passing the same `IAsyncEnumerable<T>` to two nested `for` loops) is unsupported and produces undefined behaviour. The `for x in f(args)` desugaring creates a fresh instance on each call to `f`, so well-formed Lyric code is unaffected. (b) The eager-producer strategy buffers *all* yielded values before the first `MoveNextAsync` returns; generators with an unbounded yield sequence will consume unbounded memory and hang the process at the `for` site. Use `await` inside the body to force the async-iterator strategy when infinite or very-large sequences are needed.

**Async-iterator** (body has both `yield` and `await`): **not yet implemented** (tracked in issue #1490). The compiler synthesises a combined `IAsyncStateMachine` + `IAsyncEnumerable<T>` class per the design in D-progress-261 (§14.6.2 of `docs/09-msil-emission.md`), but the self-hosted MSIL backend does not yet lower this form. A function body containing both `yield` and `await` is currently a compile error. Use the eager-producer strategy (`yield` only) or a plain `async func` (`await` only) until this form lands.

*Note on `@hot` interaction:* if a generator function is also annotated `@hot`, `IsGenerator` takes priority and `@hot` is silently ignored — the synthesised class uses `AsyncTaskMethodBuilder`, not `AsyncValueTaskMethodBuilder`. Combining `@hot` with `yield` produces a `T0096` warning at compile time.

### 7.3 Cancellation

Every `async func` has an implicit `CancellationToken` parameter threaded by the compiler. It is accessible as `cancellation` inside the function and propagated to all child async calls automatically. Cancellation is cooperative: the function periodically checks the token at await points and on explicit `cancellation.checkOrThrow()` calls.

### 7.4 Structured scopes

```
async func loadDashboard(userId: in UserId): Dashboard {
  scope {
    val profile = spawn loadProfile(userId)
    val recent = spawn loadRecentActivity(userId)
    val notifications = spawn loadNotifications(userId)

    return Dashboard(
      profile = await profile,
      recent = await recent,
      notifications = await notifications
    )
  }
}
```

`scope { ... }` guarantees:
- All spawned tasks complete (or are cancelled) before the scope exits
- If any spawned task fails, all sibling tasks are cancelled
- The first failure is propagated; subsequent failures are aggregated (accessible via the exception's `aggregated` field)
- The scope cannot leak spawned tasks beyond its lexical extent

This is the structured concurrency pattern; raw "fire and forget" is not available.

### 7.5 Protected types

```
protected type BoundedQueue[T] {
  var items: array[100, T]
  var count: Nat range 0 ..= 100

  invariant: count <= 100

  entry put(item: in T)
    when: count < 100
  {
    items[count] = item
    count += 1
  }

  entry take(): T
    when: count > 0
  {
    count -= 1
    return items[count]
  }

  func peek(): T?
    when: count > 0
  {
    return if count > 0 then Some(items[count - 1]) else None
  }
}
```

Semantics:
- A `protected type` wraps state with structurally-enforced mutual exclusion. There is no way to access the state without going through an `entry` or `func`.
- `entry` operations are exclusive (one at a time), may have a `when:` barrier (caller blocks until barrier is true), and may mutate state.
- `func` operations are exclusive too — **[OPEN: should we allow concurrent reads? See 06-open-questions.md]**.
- Barriers are re-evaluated whenever any operation completes.
- The compiler emits a `SemaphoreSlim`-based mutual exclusion plus condition signaling for barriers (see `docs/09-msil-emission.md` §17.1–17.3).
- The invariant is checked after every entry/func returns control to the caller.

### 7.6 Raw locks

There are no raw locks, no `Monitor.Enter`, no `lock` statement. Code that genuinely needs them must use a `@axiom` boundary to call into .NET primitives. This is intentional friction.

## 8. Error handling

### 8.1 Two error mechanisms

Lyric distinguishes:

- **Recoverable errors**: returned as `Result[T, E]`. Callers must explicitly handle or propagate via `?`.
- **Bugs**: contract violations (precondition, postcondition, invariant), array bounds violations, integer overflows, unwrap on `Err`/`None`. Bugs always abort the enclosing task or protected entry; they are not normally caught.

There is no `raises:` clause on function signatures. Recoverable errors are encoded in the return type. Bugs are uniform across the language and propagate the same way regardless of source.

### 8.2 Bug propagation

A `Bug` raised in:
- A regular function: propagates up the stack until caught by `try { ... } catch Bug as b { ... }` or until it terminates the thread.
- An `async` task: propagates to the task's awaiter; if not awaited, the runtime logs and surfaces it via the structured scope.
- A protected entry: aborts the current entry call without committing state changes. The protected type's invariant is verified to still hold (if not, the program terminates — invariant violation in a protected type is unrecoverable).

`try`/`catch` exists for catching `Bug`s when absolutely needed (top-level handlers, test runners, robustness boundaries). Catching `Bug`s in normal application code is a smell; the compiler emits a warning.

In value position, `try { ... } catch ... { ... }` is an expression: every
handler must produce a type compatible with the `try` body's type, or the
program is rejected at compile time (**T0067**). Diverging handlers (a body
of type `Never` — e.g. a re-`throw` or `panic`) are exempt, as are
statement-position `try` blocks whose value is discarded (`Unit`).

### 8.3 Result and panics

```
val result: Result[Account, TransferError] = transfer(from, to, amount)
match result {
  case Ok(account) -> ...
  case Err(InsufficientFunds) -> ...
  case Err(...) -> ...
}

// Or propagate:
val account = transfer(from, to, amount)?

// Or assert (raises Bug on Err):
val account = transfer(from, to, amount).unwrap()
```

`unwrap()` on an `Err` raises a `Bug` (`UnwrapOnError`). Use it only when the call cannot fail by construction.

## 9. Modules and packages

### 9.1 Package declaration

A package corresponds to a directory. All `.l` files in the directory share the same package; the `package` declaration at the top of each file must match.

```
package Account
```

Sub-packages live in subdirectories: `account/` is package `Account`, `account/internal/` is package `Account.Internal`.

### 9.2 Imports

**Lyric package imports:**
```
import Money.{Amount, Cents}
import Time.Instant
import std.collections.{Map, Set}
import std.collections as Coll      // alias
```

Wildcard imports (`import Money.*`) are not permitted. Every imported name is explicit.

**External type imports:**
```
import extern System.Net.Http.{HttpClient, HttpRequestMessage as ReqMsg}
import extern java.lang.{Math as JMath}
import extern System.DateTime
```

`import extern` imports types from external (host runtime) packages. The FQN specifies the host namespace; imported names can optionally be listed within a selector group `{ ... }` or imported directly as a single FQN (e.g. `import extern System.DateTime`). Type binding and resolution are fully supported. External imports are scoped to the importing package and do not re-export by default.

### 9.3 Re-exports

```
pub use Money.Amount        // re-exports Amount as part of this package's contract
pub use extern Docker.DotNet.{DockerClient}  // re-exports external type (D116 Q47-004)
```

Re-exports surface a name from a dependency (Lyric or external) as if declared in the current package. Useful for facade packages. External re-exports make the external type part of the public API surface; consumers depend on the host runtime's availability.

## 10. Wire / Dependency Injection

### 10.1 Wire blocks

```
wire ProductionApp {
  @provided config: AppConfig
  @provided cancellationToken: CancellationToken

  singleton clock: Clock = SystemClock.make()
  singleton db: DatabasePool = DatabasePool.make(config.dbUrl, config.dbPoolSize)
  singleton metrics: MetricsRegistry = PrometheusRegistry.make(config.metricsPort)

  scoped[Request] dbConnection: DatabaseConnection = db.acquire()
  scoped[Request] requestId: RequestId = RequestId.generate()

  bind AccountRepository -> PostgresAccountRepository.make(dbConnection)
  bind IdempotencyStore -> RedisIdempotencyStore.make(config.redisUrl)
  bind Clock -> clock

  singleton transferService: TransferService =
      TransferService.make(AccountRepository, IdempotencyStore, Clock)

  expose transferService
  expose dbConnection
}
```

### 10.2 Resolution semantics

The compiler resolves the wire graph at compile time:

- Every `@provided` is a parameter to the generated bootstrap function.
- Every `singleton` is constructed once per wire instantiation and cached.
- Every `scoped[X]` is constructed once per scope of type `X`.
- Every `bind I -> impl` registers `impl` as the resolution of interface `I` in this wire.
- `expose` declares which values are accessible from outside.

The compiler enforces:
- All transitive dependencies are satisfied.
- No cycles (reports the cycle path on error).
- No lifetime violations: a `singleton` cannot depend on a `scoped[X]`. A wider scope cannot depend on a narrower one.
- All `bind` targets satisfy the declared interface.

Output: a generated module exposing `bootstrap(provided values...) -> WireInstance` and resolution functions for each `expose`d value.

### 10.3 Scope semantics

Built-in scopes: `[Request]`, `[Transaction]`, `[Session]`. User-defined scopes via:

```
scope_kind Tenant
```

Scopes are entered and exited via host integration. The HTTP framework integrates with `[Request]` scope automatically; database integrations with `[Transaction]`. Async-local propagation uses .NET `AsyncLocal<T>` for tracking the active scope across `await` boundaries.

### 10.4 Multiple wires

A program may declare multiple wires (test wires, production wires, integration wires). Each wire is independent; they may share interfaces but not instances.

## 11. FFI

### 11.1 Extern packages

```
@axiom
extern package System.Net.Http {
  exposed type HttpClient
  exposed type HttpResponse {
    pub statusCode: Int
    pub body: String
  }

  func makeClient(): HttpClient
  async func get(client: in HttpClient, url: in String): HttpResponse
}
```

`extern` declares types and functions implemented by the host runtime. The `@axiom` annotation is required and signals that contracts on these declarations are trusted, not verified.

### 11.2 Cross-boundary marshalling

Lyric → .NET: opaque types pass as opaque handles (a sealed wrapper type with no public surface). Exposed records pass as their generated .NET counterpart. Primitives map directly.

.NET → Lyric: types arriving from .NET enter as exposed records by default. Wrapping into opaque types requires explicit constructors that re-establish invariants.

The standard library ships hand-curated wrappers for common .NET surfaces. Direct `extern` declarations are reserved for cases not covered by the standard library.

### 11.3 `@externTarget` — direct BCL method binding

`@externTarget("CLR.Type.Method")` maps a Lyric function declared inside a
`lyric-stdlib/std/_kernel/` file directly to a specific BCL (or JVM) method, bypassing
the `extern package` wrapper layer.  It is reserved for the standard-library
kernel boundary; user code must not use it.

```
// Maps the Lyric function directly to System.Text.Json.JsonDocument.Parse.
@externTarget("System.Text.Json.JsonDocument.Parse")
pub func jsonParse(s: in String): JsonDocument
```

**Generic BCL methods.**  When the target BCL method is generic (e.g.
`System.Collections.Generic.List`1.Add`), the `@externTarget` string must refer
to a concrete, closed instantiation of the host type.  A Lyric type parameter in
the surrounding function declaration cannot be substituted into the
`@externTarget` string at compile time.  The correct approach is a separate
monomorphised declaration per concrete type:

```
// Correct: one binding per concrete type.
@externTarget("System.Collections.Generic.List`1[System.Int32].Add")
pub func intListAdd(xs: inout IntList, v: in Int): Unit

// Wrong: Lyric type parameter T cannot parameterise the target string.
// @externTarget("System.Collections.Generic.List`1.Add")
// pub func listAdd[T](xs: inout List[T], v: in T): Unit  // Q022-4: not supported
```

If you need a generic list-add wrapper, implement it in Lyric using a kernel-level
monomorphised helper and expose a generic Lyric function that delegates to the
concrete helper.

**Nullable BCL returns → `Option[T]` (D107).**  Many BCL methods return a
nullable reference (e.g. `System.Environment.GetEnvironmentVariable: string?`,
`System.Console.ReadLine: string?`, `System.IO.Path.GetDirectoryName: string?`).
Lyric has no `null` literal or nullable type, so a kernel `@externTarget` that
wraps such a method declares its return as `Option[T]` (with `T` a reference
type).  The emitter binds the underlying MemberRef to the BCL's real `T` and
coerces the result at the call boundary — a null reference becomes `None`, a
non-null reference becomes `Some(value)`:

```
// GetEnvironmentVariable returns string? in the BCL; the kernel exposes Option.
@externTarget("System.Environment.GetEnvironmentVariable")
pub func getEnvVar(key: in String): Option[String]
```

Callers above the kernel boundary match an ordinary `Option` (`case None` /
`case Some(v)`) — no `null` handling is ever required.  The convention applies
only when `T` is a reference type; value-type inners are not coerced.

> **Target status.**  Phase 1 implements this convention in the MSIL backend
> (`--target dotnet`).  JVM emitter parity (`--target jvm`) is tracked in #3932
> and lands with D107 Phase 2.

**Static vs. instance call detection.**  Both backends need to know
whether a `@externTarget` binding is a static or instance call.  The
explicit form is two paired annotations (#370):

```
// Static call — emits `call` / `invokestatic`.
@externTarget("System.Math.Abs")
@externStatic
pub func absInt(n: in Int): Int

// Instance call — emits `callvirt` / `invokevirtual` with the
// receiver as Lyric arg 0.
@externTarget("System.String.Trim")
@externInstance
pub func strTrim(s: in String): String
```

`@externStatic` and `@externInstance` are mutually exclusive; setting
both is a diagnostic (the resolver falls back to `@externStatic` so
the program still builds).  When neither is present, the .NET
self-hosted MSIL emitter defaults to static, which is the safer
choice for stdlib `@externTarget` declarations (most BCL externs are
static methods or constructors).  Instance externs MUST be annotated
explicitly — the resolver cannot disambiguate without the hint.

**JVM backend (legacy convention).**  On the JVM backend the emitter
also accepts a name-based heuristic for legacy stdlib code: if the
Lyric function name begins with a PascalCase prefix followed by an
underscore (e.g. `Integer_parseInt`, `Math_abs`) the emitter emits
`invokestatic`; otherwise `invokevirtual`.  New code on either
backend should use the explicit `@externStatic` / `@externInstance`
annotations — the name-based convention is retained only for
backwards compatibility with externs that pre-date #370:

```
// Static call — PascalCase prefix + underscore (legacy).
@externTarget("java.lang.Integer.parseInt")
pub func Integer_parseInt(s: in String): Int

// Instance call — no PascalCase prefix (first param is the receiver).
@externTarget("java.lang.String.length")
pub func stringLength(s: in String): Int
```

> **Warning — silent miscompile risk.**  The `PascalCase_` heuristic (known
> internally as `isStaticExternByName`) is applied at code-generation time with
> **no diagnostic** when the name does not match the actual dispatch kind.  A
> hand-written extern whose Lyric name starts with a PascalCase segment and
> underscore but targets an *instance* method will silently emit `invokestatic`,
> crashing at JVM link time or producing wrong results at runtime.  Conversely, an
> extern targeting a *static* method whose name does not follow the convention will
> emit `invokevirtual` and fail at runtime.  **Always annotate new externs with
> `@externStatic` or `@externInstance` explicitly** — do not rely on the naming
> convention.  A `kind` field on `@externTarget` is the planned long-term
> replacement for this heuristic; track progress in #370.

**Unresolvable extern types.**  On `--target dotnet` an `@externTarget`
whose CLR type cannot be resolved to a known reference assembly
(anything outside the `System.*` BCL surface and the `Lyric.*` internal
host) fails the build with a clear diagnostic naming the unresolvable
type, rather than silently mis-binding to `System.Runtime` and throwing
`MissingMethodException` at runtime.  Restricting `@externTarget`
targets to types that exist in a reference assembly the emitter can
resolve is the stdlib author's responsibility; the compiler simply
refuses to emit a binding it cannot verify.  On `--target jvm`, when the JDK
jmods directory is found, an unresolvable Java class name is also a compile-time
diagnostic; when the jmods directory is absent (no JDK found), the auto-FFI
falls back to the legacy object-typed binding and a `NoClassDefFoundError` at
class-load time is possible.

### 11.4 Auto-FFI and import extern

External types can be imported directly using the `import extern` syntax. This is the preferred mechanism for interacting with host runtime APIs (such as the .NET BCL or Java JDK) as it unifies package imports and external imports under one cohesive model.

```lyric
import extern System.{ Math as SystemMath }
import extern System.Text.{ StringBuilder }

func clamp(n: in Int): Int {
  SystemMath.Min(SystemMath.Max(n, 0), 100)   // resolves System.Math.Max/Min(int, int)
}

func makeMessage(name: in String): String {
  val sb = StringBuilder.new(64)              // constructor shorthand (.new)
  sb.Append("Hello, ")
  sb.Append(name)
  return sb.ToString()
}
```

Alternatively, `extern type Name = "CLR.Type"` can be used to bind a Lyric name to a host type within the package, though `import extern` is preferred.

On `--target dotnet` the self-hosted MSIL emitter resolves calls and overloads from real .NET reference-assembly **metadata** at compile time (it parses the reference pack's CLI metadata directly — see `docs/42-extern-metadata-resolution.md`), locating the type's owning assembly from a metadata-derived index and selecting the method whose parameter types match the argument types, then emitting the correctly-typed call and return.

Supported features:
- **Static methods**: primitive, `String`, or `object` parameters and returns. Includes widening numeric coercion (e.g. `Int`/`Long` argument binds a `(long)`/`(double)` overload), and `object` boxing.
- **Instance methods**: resolves and dispatches via `callvirt` (e.g., `Type.GetType("System.Int32").ToString()`).
- **Constructors**: via the `.new(args)` constructor shorthand, which emits `newobj` with the resolved constructor signature (e.g., `StringBuilder.new(64)` → `newobj System.Text.StringBuilder..ctor(int32)`). Value-type constructors fall back to requiring an explicit `@externTarget` wrapper.
- **Value-types and classes**: matched and emitted by their fully-qualified names.

Unresolved calls, narrowing coercions, or instance methods on a value-type receiver fall back to requiring an explicit `@externTarget` wrapper. All unresolved auto-FFI calls produce a compile-time diagnostic.

**JVM target.** The self-hosted JVM emitter resolves `import extern` and `extern type` method calls from real JDK **`.jmod` metadata** at compile time (epic #1622, shipped in the `Jvm.AutoFfi` / `Jvm.ZipReader` / `Jvm.ClassReader` / `Jvm.Deflate` stack under `lyric-compiler/jvm/`). It reads the `.class` entry straight out of `java.base.jmod` (a ZIP behind a 4-byte JMOD magic header) at compile time, parses the constant pool and method table, scores overloads, and emits the correctly-typed bytecode:

- **`invokestatic`** for static methods (e.g. `JMath.abs(-7)` → `invokestatic`).
- **`invokevirtual`** for instance methods on a JDK reference receiver (e.g. calling `.intValue()` on the `Integer` returned by `JInteger.valueOf(42)`).
- **`new` + `invokespecial <init>`** for constructors via the `.new(args)` shorthand (e.g. `JStringBuilder.new("hello")` → `new java/lang/StringBuilder; dup; ldc "hello"; invokespecial java/lang/StringBuilder.<init>(Ljava/lang/String;)V`).

The same overload-scoring rules as dotnet apply (exact match → numeric widening); an unresolved call when the JDK is present is a compile-time error. When `JAVA_HOME` is unset and no JDK is found on the standard search paths, the emitter silently falls back to the legacy object-typed binding (no JDK required at compile time for that mode, but resolution may fail at JVM link time).

**Maven / non-JDK classes.** To resolve methods on third-party library classes, set the `LYRIC_FFI_JARS` environment variable to a colon-separated (Unix) or semicolon-separated (Windows) list of JAR file paths. The emitter scans these JARs after the JDK jmods, using the standard JAR entry path (`"com/example/Foo.class"`, without the `"classes/"` JMOD prefix):

```
export LYRIC_FFI_JARS=$(mvn -q dependency:build-classpath \
  -DincludeTypes=jar -Dmdep.outputFile=/dev/stdout 2>/dev/null)
```

```lyric
import extern com.example.{ Foo as JFoo }

func useExternalClass(): Unit {
  JFoo.someStaticMethod(42)        // resolved from JAR at compile time
  val obj = JFoo.new("hello")      // constructor via .new(args) shorthand
  obj.someInstanceMethod()         // invokevirtual via instance auto-FFI
}
```

### 11.5 AOT compatibility

All Lyric code is AOT-compatible. The compiler targets either JIT or Native AOT depending on build configuration. No reflection, no runtime code generation, no `System.Reflection.Emit` usage in compiled output.

### 11.6 Native-target FFI: `extern func` and `NativePtr[T]`

The native backend (`--target native`, D-N-001..014) binds to C symbols
through a dedicated declaration form, parallel to (not reusing) the
BCL-specific `@externTarget` machinery:

```
extern func write(fd: Int, buf: NativePtr[Byte], n: Long): Long = "write"
extern func strlen(s: NativePtr[Byte]): Long = "strlen"
```

- The `= "symbol"` clause is **mandatory** (P0275) and names a bare C
  symbol (P0276 when not a string literal).  The native backend emits an
  LLVM `declare` for the symbol and calls it directly with the C calling
  convention; parameter and return types map per
  `native/plan/03-type-mapping.md` (`Int`→`i32`, `Long`→`i64`,
  `Float`→`double`, `Bool`→`i1`, `Byte`→`i8`, `String`→`%LyricString*`,
  `NativePtr[T]`→`T*`).
- `NativePtr[T]` is a raw, unmanaged pointer: no ARC header, never
  retained or released.  It may appear only in `extern func` signatures
  and inside `lyric-stdlib/std/_kernel_native/` packages, whose safe
  `pub func` wrappers are the supported surface.  (Mode-checker
  enforcement of this boundary — diagnostic `N0100`, plus the
  `@unsafe_ffi` opt-out and the `nativeAddrOf` builtin — is specified in
  `native/plan/05-ffi-design.md` and tracked as Phase N4 follow-up
  work; until it lands the boundary is enforced by review convention,
  as the `_kernel/` `@externTarget` boundary originally was.)
- On the managed targets an `extern func` item is inert: it
  type-checks like a body-less function and the MSIL/JVM backends emit
  nothing for it (`_kernel_native/` packages are only loaded by native
  builds).

Target-specific kernel selection follows the `_kernel_jvm/` precedent:
`_kernel_native/<module>.l` declares the **same** package as
`_kernel/<module>.l` (e.g. `Std.ConsoleHost`) and the native source
loader prefers it by basename, so the public `Std.*` surface is
identical on every target.  `@cfg(target = "dotnet" | "jvm" | "native")`
additionally gates individual items per target; the predicate resolves
against a `target.<name>` pseudo-feature the CLI injects (D-N-013) and
is exempt from the `F0013` declared-features check.

## 12. Standard library

The standard library is its own package set, versioned independently of the language. Modules:

- `std.core` — primitives, collections, options, results
- `std.io` — file system, network, console (interface-based for testability)
- `std.time` — `Instant`, `Duration`, `Clock` interface, ISO 8601 parsing
- `std.text` — string manipulation, regex (RE2 syntax), encoding
- `std.collections` — Map, Set, List, Queue, plus immutable/persistent variants
- `std.json` — RFC 8259 conformant, source-generated serializers
- `std.http` — HTTP client and server primitives (interface layer over .NET BCL)
- `std.testing` — test runner, property generators, snapshot testing

API surface and stability guarantees: governed by `@stable(since="1.0")` / `@experimental` annotations on each `pub` item (D040 / Q011). See `docs/10-stdlib-plan.md` §"Stability cut" for the module-by-module cut list.

### 12.1 String method-syntax operations

`String` supports a set of built-in method-syntax (UFCS) operations that lower
directly to host `String` instance methods (`System.String` on .NET,
`java.lang.String` on the JVM). These are distinct from the `Std.String`
free functions — notably `s.indexOf(x)` / `s.lastIndexOf(x)` follow the host
convention (return `Int`, `-1` when absent), whereas the `Std.String.indexOf`
free function returns `Option[Int]`.

| Form | Result | Notes |
|---|---|---|
| `s.length` | `Int` | code-unit count |
| `s[i]` | `Char` | code unit at index `i` |
| `s.substring(start)` | `String` | from `start` to end |
| `s.substring(start, count)` | `String` | `count` units from `start` |
| `s.trim()` | `String` | leading/trailing whitespace removed |
| `s.replace(old, new)` | `String` | all occurrences |
| `s.indexOf(sub)` | `Int` | first index, `-1` if absent |
| `s.lastIndexOf(sub)` | `Int` | last index, `-1` if absent |
| `s.contains(sub)` | `Bool` | |
| `s.startsWith(prefix)` | `Bool` | |
| `s.endsWith(suffix)` | `Bool` | |
| `s.toLower()` | `String` | culture-invariant fold (`String.ToLowerInvariant` on .NET) |
| `s.toUpper()` | `String` | culture-invariant fold (`String.ToUpperInvariant` on .NET) |

String `==` / `!=` compare by value (not reference identity). An empty-string
check is the `Std.String.isEmpty(s)` free function (`s.length == 0`), not a
method-syntax form.

## 13. Tooling

### 13.1 Compiler

`lyric build` — compiles a project to a framework-dependent `.dll` (the fast inner loop). After a successful build the compiler prints elapsed time: `built foo.dll in 342ms` for a single-package build, or `built foo.dll (3 package(s), 1204ms)` for a project build. The default output name and artifacts are **target-aware**: `--target dotnet` (the default) writes `<source-stem>.dll` alongside a `<source-stem>.runtimeconfig.json` for `dotnet exec`, while `--target jvm` writes a self-contained runnable `<source-stem>.jar` (run with `java -jar`) and emits **no** `runtimeconfig.json` (a .NET-only artifact). An explicit `-o <output>` is honoured verbatim for either target. `lyric build --release <source.l>` produces a **self-contained Native AOT binary** (no managed runtime required at the deployment target): the compiler builds the managed DLL, generates a host project that references it plus the stdlib bundle, and runs `dotnet publish -p:PublishAot=true`, surfacing ILC trim/AOT warnings. `--rid <rid>` overrides the host runtime identifier (default: auto-detected). The native binary is written to the source stem (no extension) unless `-o` overrides it.

`lyric build <source.l> --target native [-o <out>] [--triple <llvm-triple>] [--opt 0|1|2|3|s]` — compiles through the **LLVM native backend** (D-N-001..014) to a self-contained POSIX executable: the self-hosted front/middle end lowers the user package plus the reachable slice of its stdlib import closure to LLVM textual IR, then drives `clang` to optimise and link against the `lyric_rt.a` runtime (ARC intrinsics, strings, collections, POSIX helpers), `libm`, and `libpthread`. The default output is the source stem with **no extension**. `--triple` cross-compiles (defaults to the host triple per `clang -print-effective-triple`); `--opt` sets the clang optimisation level (default `2`). When `clang` is not installed the diagnostic (`N0001`) names the missing tool and leaves the emitted `.ll` next to the requested output so it can be compiled manually; `lyric_rt.a` resolves from `$LYRIC_RT_PATH`, the installed `lib/` layout, or the dev tree's `lyric-rt/build/` (`N0003` when absent). Supported surface (Phases N1–N4, D-progress-540 and D-progress-545..552): Linux x86-64/AArch64 and macOS AArch64; scalars and Strings; records (methods, defaults, mutable fields), unions, enums, distinct types (range-checked), tuples, and pattern matching; generic records/unions/functions via call-site monomorphization; closures with by-value ARC captures; `NativeWeak[T]` with `upgrade(): Option[T]`. Memory is ARC-managed per `native/plan/04-arc-design.md` and the emitted protocol is leak-checked under AddressSanitizer in CI. The raw FFI surface is mode-checker-gated (`N0100`): `NativePtr[T]` type expressions, `nativeAddrOf(x)` (address of a `var` local; the pointer must not be returned or stored in a heap type), and `nativeNullPtr()` are admitted only inside functions annotated `@unsafe_ffi` and in `_kernel_native/` package files, with `extern func` parameter/return positions exempt as the audited boundary. An `extern func` parameter may be declared with a function type whose last parameter is `NativePtr[Byte]` (the userdata slot); a Lyric closure passed there is wrapped in a compiler-synthesised C-ABI trampoline, and the same closure value passed in a `NativePtr[Byte]` argument position lowers to the closure pointer itself, so callback-driven C APIs (`pthread_create`-style) work end-to-end. `List[T]`/`Map[K, V]` lower to the lyric-rt kernels (Map keys must be String or a scalar type), with `for` loops over lists, indexing, and the `Std.Collections` accessors (`newList`/`newMap` need their element types from a binding annotation or explicit type arguments; `mapGet` is the Option-returning map read). Not yet lowered (reachable code using them fails the build with a construct-naming diagnostic): interfaces, protected types, `slice[T]` and list literals, `Set[T]`, module-level `val`, and `async func` (`N0099`); manifest (multi-package) native builds are not yet supported.

`--release` is supported for both **single-file** and **project-mode** (multi-package `lyric.toml`) programs on the **.NET** target. In project mode the entry package — the one whose source declares a zero-argument `func main()` — is auto-detected across all `[project.packages]` entries; exactly one package must declare `func main()` (zero or multiple entries are a hard error). Local path dependencies declared in `[dependencies]` are automatically collected as AOT linker references. The JVM target (GraalVM `native-image`, designed behind the same `ReleaseTarget` seam) is not yet implemented and fails loud rather than silently producing a managed artifact (#1975).

`lyric build --release-from-dll <dll> [-o <out>] [--rid <rid>] [--target dotnet|jvm] [--extra-refs-dir <dir>]` — links a pre-built managed DLL to a native binary via ILC + clang, bypassing all Lyric source compilation. The DLL must already exist; a non-existent path is a hard error (exit 1). The output path defaults to the DLL's stem (`.dll` suffix stripped, 4 characters) in the same directory, or is overridden by `-o`. `--extra-refs-dir <dir>` passes every `*.dll` file found in `<dir>` (except the primary DLL itself) as an ILC managed reference, in sorted order for reproducible output; the directory is enumerated non-recursively. `--extra-refs-dir` is only valid alongside `--release-from-dll`; specifying it alone is a hard error (exit 1). `--rid` overrides the target runtime identifier (default: auto-detected from the host). Exit codes: 0 on success; 1 on any error (missing DLL, ILC failure, linker failure, bad flags).

`lyric run [<source.l>] [--target dotnet|jvm]` — compiles and immediately executes, mirroring `lyric build` then running the produced artifact. `--target dotnet` (the default) builds the `.dll` and runs it via `dotnet exec`; `--target jvm` builds the self-contained `.jar` and runs it via `java -jar`. On `--target dotnet`, arguments after `--` are forwarded verbatim to the program and the program's exit code becomes `lyric run`'s exit code. On `--target jvm` arguments are forwarded to a `main(args: slice[String])` entry point (the synthesised JVM `main(String[])` wrapper passes the argv array through), and an `Int`-returning `main` becomes the process exit code via `java.lang.System.exit`. With no source file, `lyric run` discovers the nearest `lyric.toml` and runs the project's entry artifact; `--target` applies to the project build. For a project whose `[build] kind = "exe"`, `lyric run` executes the native apphost launcher directly rather than via `dotnet exec`; if no launcher is present (no apphost template could be located, or it was removed) it prints a warning and falls back to `dotnet exec` rather than failing. Intermediate artifacts are written under `.lyric-run/`.

**Project-aware defaults.** Running `lyric` with no command builds the current
project: it discovers the nearest `lyric.toml` by walking up from the working
directory and runs `lyric build` against it. All eight dev-loop commands —
`build`, `run`, `fmt`, `lint`, `prove`, `doc`, `test`, and `bench` — do the
same discovery when given no source file or `--manifest`, so they work from
any subdirectory of a project. Each command also accepts `--manifest <lyric.toml>`
to override discovery with an explicit path. Outside a project (no `lyric.toml`
in the directory tree) bare `lyric` prints help and exits non-zero.
`lyric --help` (also `-h`, `help`) prints the grouped command list and exits 0;
an unrecognised command prints a "did you mean …?" suggestion when a close
match exists.

**Scaffolding.** `lyric init [<dir>] [--name <Name>] [--lib] [--force]` scaffolds
a new package in `<dir>` (default the current directory, created if absent): a
`lyric.toml` with `[package]`, `[project]`, and an empty `[dependencies]` table;
`src/main.l` (a `func main(): Int` hello-world) or `src/lib.l` with `--lib`; and
a `.gitignore`. The package name is derived from the directory basename — with a
lowercase leading letter capitalised to the `UpperCamelCase` convention — unless
`--name` overrides it; a candidate that is not a valid identifier is rejected
with a message suggesting `--name`. An existing `lyric.toml` is not overwritten
without `--force`; a pre-existing `.gitignore` is left untouched.

**Auto-restore on build.** A project-mode `lyric build` automatically resolves
dependencies (the equivalent of `lyric restore`) when the manifest declares any
`[dependencies]` and `lyric.lock` is missing or out of sync with the declared
set (a dependency absent from the lock, or a registry dependency whose locked
version differs). A clean checkout — or a just-edited dependency set — therefore
builds without a manual `lyric restore`. Pass `--no-restore` to skip this and
build against the lock as-is. Auto-restore tracks the `[dependencies]` table
only; changes to `[nuget]`/`[maven]` entries are not detected, so run
`lyric restore` explicitly after editing those.

**Version override.** `lyric build --package-version <ver>` overrides the `version` field from `lyric.toml` for the version string embedded in the `Lyric.Contract.*` metadata resources inside the built DLL. When absent, the version from `lyric.toml` is used. This flag is intended for automated publish pipelines that must stamp the git release tag version into built artifacts rather than the version stored in `lyric.toml`.

**Watch mode.** `lyric run --watch <source.l>` and `lyric build [--watch]` run the
action once, then watch the relevant source files and re-run on every change
until interrupted (Ctrl-C). `run --watch` watches the source file; project
`build --watch` watches the manifest and every `[project.packages]` source;
single-file `build --watch` watches the source. Change detection fingerprints
each file's contents (no reliance on filesystem timestamps); the poll interval
is fixed. The watch loop runs in the CLI process (always the .NET host).

### 13.2 Test runner

`lyric test [<source.l>]` compiles a `@test_module` file, synthesises a runnable program from its `test "title" { … }` items, and reports results in TAP-shaped form (`1..N`, `ok N - title` / `not ok N - title`, summary counts). Exit codes: `0` (every selected test passed), `1` (at least one failure), `2` (compilation error), `64` (usage error).

**Project mode.** When invoked with no source file, `lyric test` discovers the nearest `lyric.toml` and runs every `[project.tests]` entry in sequence. Pass `--manifest <lyric.toml>` to override discovery. The command exits non-zero if any test entry fails.

**`[project.tests]` fallback.** When the manifest has a `[project]` section but no `[project.tests]` entries, `lyric test` scans all source files listed in `[project.packages]` for the `@test_module` annotation and runs each found file as a standalone single-file test. This allows projects that co-locate test modules with their source packages to run tests without explicit `[project.tests]` entries in `lyric.toml`.

`--filter <substring>` runs only tests whose title contains `<substring>`; non-matching tests are reported as `# skip` lines. `--list` prints titles only without compiling. `--fail-fast` stops after the first test file that has any failing test and prints an early summary; in project mode this means remaining test entries are not run. `property` declarations parse but skip at runtime in v1 (`# skip` line); `fixture name[: T] = expr` declarations are rewritten to module-level `val` declarations in the synthesised source (D-progress-474). v2 adds cross-package non-`pub` access (§3.2), property execution (`--properties`), and doctest extraction. See `docs/24-test-runner-plan.md` for the v1 design and v2 scope.

### 13.3 Verifier

`lyric prove [<source.l>]` runs the SMT-backed verifier on `@proof_required` modules. Reports unverified obligations with counterexamples.

**Project mode.** When invoked with no source file, `lyric prove` discovers the nearest `lyric.toml` and proves contracts in every `[project.packages]` source file. Pass `--manifest <lyric.toml>` to override discovery. The flags `--json` and `--explain --goal N` require an explicit source file.

**NaN and ±Infinity in proof goals (`V0013`):** SMT-LIB Real has no representation for non-finite IEEE 754 values. When a proof goal contains a NaN or ±Infinity float literal, the emitter substitutes `0.0` in the generated SMT-LIB and emits warning `V0013`. The verification result may be incorrect; review such goals manually.

**Contracts on async/generator functions (`V0032`):** The verifier's WP/SP calculus has no model for the suspend/resume control flow of an `async func` or a `yield`-bearing generator — an `await`/`yield` expression has no Term translation and would be coerced to an uninterpreted opaque symbol, so a `requires:`/`ensures:` clause on such a function would be "discharged" against an unmodelled body (unsound). A `@proof_required` async or generator function that carries any contract clause is therefore rejected at VC-generation time with error `V0032` and produces no goals. A non-contract async function is unaffected. Move the contract to a synchronous core, or mark the package `@runtime_checked`. Effect-aware VC generation that models async/generator bodies is future work.

### 13.4 Documentation

`lyric doc [<source.l>]` generates Markdown documentation from doc comments and contract metadata. Includes signatures and contracts.

**Project mode.** When invoked with no source file, `lyric doc` discovers the nearest `lyric.toml` and generates documentation for every `[project.packages]` source file, writing one Markdown file per source file into a `docs/` output directory relative to the manifest. Pass `--manifest <lyric.toml>` to override discovery. Pass `-o <dir>` to override the output directory.

### 13.5 Public API diff

`lyric public-api-diff <ref>` compares the current `pub` surface against a previous git ref and reports breaking changes. Used in CI to enforce SemVer discipline.

### 13.6 LSP

The language server conforms to the Microsoft Language Server Protocol (latest stable). No Lyric-specific LSP protocol extensions in v1 — the server uses only standard LSP message types.

**Diagnostic type (LSP consumers):** The internal `Diagnostic` record exposed via the compiler API carries three optional fields that map directly to LSP diagnostic capabilities. These are compiler API fields, not protocol-level extensions:

| Field | Type | LSP mapping |
|---|---|---|
| `Help` | `string option` | Rendered as a `DiagnosticRelatedInformation` entry with the current file URI and a "help" label |
| `Related` | `(Span × string) list` | Rendered as additional `DiagnosticRelatedInformation` entries pointing to related source positions |
| `Fix` | `TextEdit option` | Surfaced as a `CodeAction` of kind `quickfix` in the code-action response |

`TextEdit` carries a `Span` (the source range to replace) and a `NewText` string (the replacement). Builder combinators `withHelp`, `withRelated`, and `withFix` are available on `Diagnostic` for constructing extended diagnostics.

### 13.7 Formatter

`lyric fmt` formats source code per a fixed style. No configuration; the format is the format. Run on save.

The bootstrap formatter works directly from the parsed AST; it does not require a CST. Consequences:

- **Non-doc comments (`//`) are not preserved** — the lexer discards them (§1.3). Doc comments (`///` and `//!`) survive because they are part of the AST.
- The output is idempotent: formatting a file that is already formatted is a no-op.

**Canonical style rules:**
- 2-space indentation.
- Opening brace `{` is inline when there are no contract or where clauses; on its own line when they are present.
- One blank line between top-level items.
- Contract clauses (`requires:`, `ensures:`, `invariant:`) each on their own line, indented 2 spaces under the function signature.
- Trailing newline; no trailing whitespace per line.

**Project mode.** `lyric fmt` with no source file discovers the nearest `lyric.toml` and operates over every `[project.packages]` source. Pass `--manifest <lyric.toml>` to override discovery. Behaviour depends on flags: the default is a **dry-run** (lists files that would change without writing them); `--write` applies changes in place; `--check` is the silent CI gate.

**Multi-file mode.** `lyric fmt <file1.l> <file2.l> …` accepts multiple positional source arguments and applies the same formatting logic to each file. Combined with `--write`, this is equivalent to running `lyric fmt --write` on each file individually.

**Stdin mode.** `lyric fmt --stdin` reads the entire source from standard input, formats it, and writes the result to standard output. Intended for editor integrations that pipe the current buffer through the formatter. Combines with `--check` to check without writing.

**Flags:**

| Flag | Scope | Effect |
|------|-------|--------|
| _(default, single/multi-file)_ | File(s) | Print formatted source to stdout |
| _(default, project mode)_ | Project | Dry-run: print which files would change; exit 1 if any; does **not** write |
| `--write` | File(s) or project | Overwrite file(s) in place; print each reformatted path |
| `--check` | File(s) or project | Exit 1 if any file would change; prints the unformatted paths |
| `--diff` | File(s) or project | Print a unified diff of what would change without writing; works in dry-run mode, single-file mode, and combined with `--write` (shows diff then applies changes). Exits 1 if any file would change (same as `--check`), useful as a CI gate that also shows what changed. |
| `--stdin` | — | Read from stdin, write formatted output to stdout (editor integration) |

### 13.8 Linter

`lyric lint [<source.l>]` checks source code for style and quality issues. It works entirely from the parsed AST — no type-checker context is needed — so it is fast and runs on files that do not yet compile.

**Project mode.** When invoked with no source file, `lyric lint` discovers the nearest `lyric.toml` and lints every `[project.packages]` source file, prefixing each diagnostic with its source path. At the end of the run, `lyric lint` prints a summary line: either `"lint: N error(s), M warning(s) in K file(s)"` or `"lint: K file(s) clean"`. Pass `--manifest <lyric.toml>` to override discovery.

**Diagnostic codes:**

| Code | Severity | Rule |
|------|----------|------|
| `L001` | error | Type names (`record`, `union`, `enum`, `interface`, opaque, `protected`, distinct type, type alias) must be `PascalCase`. Constants must be `PascalCase` or `UPPER_SNAKE_CASE`. |
| `L002` | error | Function names (`func` items, `entry` declarations inside `protected` blocks) must be `camelCase`. |
| `L003` | warning | `pub` items should have a doc comment (`///`). |
| `L004` | warning | Doc comments must not contain `TODO` or `FIXME`. |
| `L005` | warning | `pub func` with a block body should declare at least one `requires:` or `ensures:` contract. Expression-body stubs are excluded. |

**Flags:**

| Flag | Effect |
|------|--------|
| _(default)_ | Print diagnostics; exit 0 if only warnings |
| `--error-on-warning` | Treat warnings as errors; exit 1 |

**Exit codes:** 0 = clean (or warnings-only without `--error-on-warning`); 1 = at least one error (or warning with the flag).

**Output format:** `<code> <severity> [<line>:<col>]: <message>`, matching the compiler's own diagnostic shape.

### 13.9 Benchmark runner

`lyric bench [<source.l>] [--target dotnet|jvm]` compiles a `@bench_module` file, synthesises a timing harness around each `@bench`-annotated function, and reports wall-clock statistics to stdout. `--target dotnet` (default) runs via `dotnet exec`. `--target jvm` dispatch is wired but currently blocked: the timing harness imports `Std.Time`, which does not yet compile on the JVM backend (#3302), so `lyric bench --target jvm` is not yet usable (#680 remains open).

**Project mode.** When invoked with no source file, `lyric bench` discovers the nearest `lyric.toml` and runs benchmarks for every `[project.packages]` source file that contains a `@bench_module` annotation. Pass `--manifest <lyric.toml>` to override discovery. `--target` applies to all files in the project.

**Annotations:**

- **`@bench_module`** — file-level; marks the file as a benchmark suite. Required; without it `lyric bench` exits with `B0900`.
- **`@bench`** — function-level; marks a `func name(): Unit` function (zero parameters, `Unit` return) as a benchmark entry point. The synthesiser calls it un-timed during warmup and timed during the measurement phase. Any function with this annotation is included regardless of visibility.

**Output format:** one header line followed by one result line per benchmark:

```
benchmark  runs=N  warmup=M

funcName  min=Xms  max=Xms  mean=Xms
```

**Flags:**

| Flag | Default | Effect |
|------|---------|--------|
| `--runs N` | `10` | Number of timed iterations per benchmark |
| `--warmup N` | `3` | Un-timed iterations before the timed region (JIT, cache warm-up) |
| `--filter s` | *(all)* | Only run benchmarks whose function name contains `s` |

**Exit codes:** `0` = benchmark ran and results printed; `2` = compilation error; `64` = usage error or constraint violation.

**Constraint violations (`B`-series):**

| Code | Condition |
|------|-----------|
| `B0900` | File is missing `@bench_module` |
| `B0901` | `@bench_module` file declares `func main()` |
| `B0902` | No `@bench` functions found (or `--filter` matched none) |

A `@bench` function whose signature does not match `func name(): Unit` passes through the synthesiser as-is; the mismatch is reported by the type checker with a standard `T`-series diagnostic.

### 13.10 Type checker (check only)

`lyric check [<source.l>…] [--target dotnet|jvm] [--manifest <lyric.toml>]` type-checks source files (or the discovered project) without producing a usable output artifact. Output is written to `.lyric-check/` beside the source file (or project manifest). Only diagnostics with `DiagError` severity cause exit 1; the artifact is intentionally discarded.

**Use cases:** pre-commit type validation, IDE on-save checks, faster feedback in CI when the output binary is not needed.

**Project mode.** When invoked with no source file, `lyric check` discovers the nearest `lyric.toml` and type-checks all `[project.packages]` entries (calls `buildProject` with output directed to `.lyric-check/`). `--no-restore` is implied in project check mode to avoid slow lock checks on each save; run `lyric restore` explicitly when dependencies change.

**Exit codes:** 0 = no type errors; 1 = type errors or build failure.

### 13.11 Clean

`lyric clean [<dir>] [--manifest <lyric.toml>]` removes the build artifact directories produced by the dev-loop commands from the project root (or the directory specified by the positional argument):

| Directory | Produced by |
|-----------|-------------|
| `bin/` | `lyric build` (project mode) |
| `.lyric-run/` | `lyric run` |
| `.lyric-test/` | `lyric test` |
| `.lyric-bench/` | `lyric bench` |
| `.lyric-check/` | `lyric check` |
| `.lyric-release/` | `lyric build --release` |

**Exit codes:** 0 = nothing to remove or all directories removed successfully; 1 = at least one removal failed.

### 13.12 Package manager

`lyric.toml` is the project manifest. Dependencies use SemVer 2.0.0. Registry: NuGet piggyback (D-progress-030); see `docs/21-nuget-linking.md`.

`lyric restore [--manifest <lyric.toml>] [--locked]` resolves and locks all dependencies declared in `lyric.toml`, writing `lyric.lock`. `--locked` verifies the existing lock rather than rewriting it (for reproducible CI builds).

`lyric update [--manifest <lyric.toml>]` re-resolves all dependencies from scratch: deletes the existing `lyric.lock` (workspace-root-aware), then runs a full restore to produce a fresh lock with the latest compatible versions. For git dependencies, this fetches the latest revision of the specified branch/tag.

`lyric upgrade [--nuget | --dotnet-tool] [--github] [--version <version>] [--dir <dir>] [--dry-run]` self-upgrades the `lyric` CLI tool itself:
- **Auto-detection**: If no upgrade channel is specified, auto-detects how `lyric` is running. If it runs as a `.NET Global Tool` (path contains `.store`, `dotnet-tools`, or `.dotnet`), it uses the NuGet channel; otherwise, it downloads and executes the zero-dependency POSIX installation script (`install.sh`) from GitHub Releases.
- **Forced Channels**: `--nuget` / `--dotnet-tool` forces upgrading via `.NET Global Tool` (`dotnet tool update -g lyric`). `--github` forces upgrading via the raw GitHub Releases installer script.
- **Options**: `--version <version>` upgrades to a specific target semver version. `--dir <dir>` specifies the target installation directory when upgrading via GitHub Releases. `--dry-run` performs a dry-run and prints the commands that would be executed without making any modifications.

`lyric deps [--manifest <lyric.toml>]` prints the resolved dependency list from `lyric.lock` (one line per package: `<name> [<version>]  [<source>]`). Exits 1 if no lock file exists; run `lyric restore` first.


`lyric add <name>[@<version>] [--path <dir>] [--git <url> [--tag|--rev|--branch <ref>]] [--nuget] [--manifest <lyric.toml>] [--no-restore]` adds or updates a dependency in the discovered manifest and then restores (unless `--no-restore`):

- Bare `<name>` or `<name>@<version>` writes a registry entry to `[dependencies]` (`name = "<version>"`; a missing version is written as `"*"`).
- `--path <dir>` writes `name = { path = "<dir>" }`; `--git <url>` with an optional `--tag`/`--rev`/`--branch` writes the git inline-table form; `--nuget` writes to the `[nuget]` table instead.
- The edit is idempotent — re-adding a dependency updates its entry in place rather than duplicating it — and is rejected before write if the result would not parse. The table is created if absent. `--path`, `--git`, and `--nuget`/`@version` are mutually exclusive where they conflict.

`lyric remove <name> [--nuget] [--manifest <lyric.toml>] [--no-restore]` removes a dependency from the discovered manifest and then restores (unless `--no-restore`):

- Without `--nuget`, removes the entry from `[dependencies]`.
- With `--nuget`, removes the entry from `[nuget]` instead.
- The command is rejected if `<name>` is not present in the target table. `lyric remove` is the mirror of `lyric add`.

`lyric publish [--manifest <lyric.toml>] [--registry <url>] [--api-key <key>] [--skip-duplicate] [--package-version <ver>]` packs the current project as a NuGet package and pushes it to the configured registry:

- `--registry <url>` overrides the push target URL (default: `https://api.nuget.org/v3/index.json`).
- `--api-key <key>` supplies the NuGet push token or GitHub PAT.
- `--skip-duplicate` silently succeeds if a package with the same name and version already exists on the registry.
- `--package-version <ver>` overrides the `version` field from `lyric.toml` for the emitted NuGet `<Version>` tag, the `.nupkg` filename, and all cross-library workspace dependency `<PackageReference>` versions. In automated publish pipelines, use this alongside `lyric build --package-version <ver>` (a separate preceding step) so the `Lyric.Contract.*` metadata resource embedded in the DLL and the NuGet package version both carry the same release tag version.

---

## 14. Aspects

An `aspect` block is a module-scope item that declares cross-cutting behaviour applied to a matched set of functions at compile time. The compiler weaves the advice into the matched functions; no call-site changes are required.

### 14.1 Aspect declaration

```ebnf
aspect <Name> {
  matches: <predicate> [ and <predicate> ]* [ except name in { <name> [, ...] } ]

  [ wraps: <AspectName> [, ...] ]
  [ inside: <AspectName> [, ...] ]

  [ requires: <expr> ]
  [ ensures: <expr> ]

  around(args) -> ret {
    <body>
  }
}
```

An aspect must define at least one of: an `around` advice body, a `requires:` clause, or an `ensures:` clause. An aspect with none of the above is a compile error (A0009).

**`matches:`** selects which functions the aspect applies to. Multiple predicates are joined by `and` (all must hold). The available predicates are:

| Predicate | Selects functions where… |
|-----------|--------------------------|
| `name like "<glob>"` | Short name matches the glob (`*`, `?`, `[abc]`, `[a-z]`) |
| `annotated: @Name` | Carries the named annotation (matched on short name) |
| `visibility: pub \| priv \| internal` | Has the stated access level |
| `signature: returns "<glob>"` | Return type string matches the glob |

`except name in { fn1, fn2 }` excludes specific short names after all predicates pass.

Matching aspects are package-private: they weave over functions in the same package only. A `pub aspect` without a `matches:` clause is an exportable template (deferred; see §14.7).

### 14.2 The `around` advice body

```lyric
around(args) -> ret {
  // pre-advice
  proceed(args)
  // post-advice
}
```

`args` is a placeholder for the matched function's original arguments, forwarded to `proceed(args)`. `proceed(args)` calls the matched function and returns its return value. `ret` is the binding name for the return value; its type equals the matched target's return type. The body's last expression is the return value (implicit for `Unit`).

`proceed(args)` may be called zero times (skip/replace semantics), once (standard wrapper), or multiple times (retry, loop). It may appear anywhere in the body — top-level, inside `if`/`match`, inside `while`/`for` loops, inside `try` blocks.

### 14.3 Composition order

When multiple aspects match the same function, they are composed: each aspect's `proceed(args)` enters the next aspect's advice, and the innermost advice calls the original function.

Default order is lexical declaration order (first-declared is outermost). Override with:

- **`wraps: OtherAspect`** — this aspect is placed outside `OtherAspect` (runs first).
- **`inside: OtherAspect`** — this aspect is placed inside `OtherAspect` (runs after).

Multiple names may appear in a single `wraps:` or `inside:` clause, comma-separated. The compiler resolves ordering at build time; cycles are a compile error (A0008).

### 14.4 Contract augmentation

Aspects may carry `requires:` and `ensures:` clauses. These are composed additively with the matched function's own contract: all `requires:` clauses (function + every matching aspect) must hold before the call; all `ensures:` clauses must hold after. Aspects cannot weaken or remove a function's own contracts.

An aspect clause may reference the matched function's parameters through `args.<field>` (e.g. `requires: args.apiKey != ""`). At weave time each `args.<field>` reference is rewritten to the matched function's same-named parameter; this works in every aspect mode (local, C-mode, and B′-mode) because composed clauses always land on the per-match wrapper, whose parameters are the matched function's own. A referenced field with no matching parameter surfaces as a weave-time diagnostic (A0042 for C-mode; A0047 for row-constrained B′-mode).

In `@runtime_checked` packages, augmented clauses are runtime assertions. In `@proof_required` packages, they are additional SMT obligations.

### 14.5 Per-function opt-out

```lyric
@no_aspect                   // exclude from every matching aspect
@no_aspect("AspectName")     // exclude from one named aspect only
```

The aspect name in `@no_aspect("Name")` is a string literal matching the aspect's declared identifier. Multiple calls with different names exclude from multiple specific aspects.

### 14.6 Compiler errors

| Code | Meaning |
|------|---------|
| A0007 | Two aspects' `matches:` overlap on a target with no explicit ordering constraint |
| A0008 | Cycle in `wraps:`/`inside:` ordering graph |
| A0009 | Aspect defines neither `around` advice nor any contract clause |
| A0013 | `wraps:`/`inside:` references an aspect not declared in the package |
| A0042 | `@inline_template` aspect body references `args.<field>` that does not match any parameter of the matched function |
| A0043 | `call.<field>` references an ambient field the weaver does not recognise (recognised: `shortName`, `qualifiedName`, `modulePath`, `sourceLocation`, `annotations`, `aspect`) |
| A0044 | `config.<field>` references a `config { }` field declared without a literal default; env-var resolution per `docs/26 §8` is a follow-up — add a default or remove the reference |

A0007, A0008, A0009, and A0013 are specified but not yet emitted by the current compiler. Aspects without an `around` body are silently skipped by the weaver; unresolved `wraps:`/`inside:` names are silently ignored. These checks are planned for a follow-up milestone.

A0042 and A0043 are emitted by the self-hosted weaver at weave time
(`lyric-compiler/lyric/weaver/weaver.l`). The L006 lint warning
(`@inline_template has no effect`) was removed when weave-time
`args.<field>` rewriting landed — A0042 supersedes its purpose.
Diagnostic codes A0027 through A0041 are reserved for in-flight
aspect work and not yet emitted; the jump from A0026 to A0042
preserves the allocated A0040 (`call is not in scope inside
requires:`) and A0041 (template-imports diagnostic referenced in
`docs/27-aspect-libraries.md` §6.2.1).

### 14.7 Bootstrap limitations (current milestone)

The following are specified but not yet fully woven:

- The `call` ambient value's `call.caller` field (caller-site
  location) needs caller-site capture that is not implemented;
  references surface as A0043 weave-time diagnostics. The
  compile-time-known fields (`shortName`, `qualifiedName`,
  `modulePath`, `sourceLocation`, `annotations`, `aspect`) are
  wired and rewritten by the weaver as `__lyric_call_<name>`
  locals. Concrete shapes: `shortName`, `qualifiedName`,
  `modulePath`, `aspect` are `String`; `sourceLocation` is
  `String` of the form `"<packagePath>:<line>"` (or
  `"<unknown>:<line>"` when the package path is empty);
  `annotations` is `slice[String]` carrying the matched
  function's annotation short-names. The runtime field
  `call.elapsed` (`Option[Int]`, milliseconds) is wired (#1298 /
  D100): the weaver captures `Std.Time.monotonicNanos()` around
  each `proceed(args)` call and auto-injects `import Std.Time`
  (deduplicated) into the woven file; the value is `Some(ms)`
  after `proceed` returns and `None` before / when the body never
  calls `proceed`.
- `pub aspect` templates and consumer-side instantiation
  (`aspect X from Pkg.Y`) — parsed by the compiler but the weaver
  does not act on them.

`config {}` blocks and `@inline_template` `args.<field>` rewriting
are now fully woven by the self-hosted weaver (todo/06 #683 / #681).

---

## Index of TBD items

This document originally marked twelve points as requiring Phase 0
work. Their resolution status is now:

| # | Topic | §  | Status |
|---|---|----|--------|
| 1 | Record-vs-class lowering heuristic | 2.4 | Resolved — `09-msil-emission.md` §5 |
| 2 | Opaque type metadata sealing | 2.8 | Resolved — `09-msil-emission.md` §7.2 |
| 3 | Projection cycle handling syntax | 2.9 | Resolved — `03-decision-log.md` D026 |
| 4 | Exhaustive list of generic constraint markers | 2.11 | Resolved — `03-decision-log.md` D034 |
| 5 | Async + `out`/`inout` parameter interaction | 5.2 | Resolved — `09-msil-emission.md` §11.4 |
| 6 | `?` in non-error-returning functions | 4.5 | Resolved — `03-decision-log.md` D027 |
| 7 | `var` capture across async boundaries | 5.4 | Resolved — `09-msil-emission.md` §11.5 |
| 8 | `func` exclusivity in protected types | 7.4 | Resolved — `09-msil-emission.md` §17.4 |
| 9 | Protected type lowering | 7.4 | Resolved — `09-msil-emission.md` §17.1–17.3 |
| 10 | Task vs ValueTask selection | 7.1 | Resolved — `09-msil-emission.md` §14.2 |
| 11 | Standard library API surface | 12 | Partially resolved — Std.Time / Json / Http / Math / Random / Testing / Iter / Collections shipped (D-progress-027..072); v1.0-frozen surface is future work |
| 12 | Package registry | 13.8 | Resolved — NuGet piggyback (D-progress-030) + embedded `Lyric.Contract` resource (D-progress-031) + `lyric.toml` + `lyric publish` / `lyric restore` (D-progress-077) |

No Phase 0 design questions remain open.  Q012 resolved during
the Tier-3 package-ecosystem work; Q011 ships incrementally and
freezes when the v1.0 surface is declared.
