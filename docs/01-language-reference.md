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
interface   invariant    is           let          match
mut         not          old          opaque       or
out         package      property     protected    pub
record      requires     result       return       scope
scoped      self         singleton    spawn        test
then        throw        true         try          type
union       use          val          var          when
where       while        wire         with         xor
```

Annotation-style keywords (always preceded by `@`):

```
@axiom         @derive          @experimental          @global_clock_unsafe
@hidden        @projectable     @proof_required        @provided
@runtime_checked  @stable       @stubbable             @test_module
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

**Character literals**: `'a'`, `'\n'`, `'\u{1F600}'`. Single Unicode scalar value.

**Boolean literals**: `true`, `false`.

### 1.5 Comments

```
// line comment
/* block comment, may /* nest */ arbitrarily */
/// doc comment for following item (markdown)
//! doc comment for enclosing module (markdown)
```

Doc comments are part of the contract metadata and surface in `lyric doc`. Doctest code blocks are extracted and run by the test harness.

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
| `Char` | Unicode scalar | per Unicode 15+ |
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

Range-violating values cause a runtime check failure on construction (`tryFrom` returns `Result`; `from` panics). Inside a `@proof_required` module, the prover discharges the range obligation statically; runtime checks are elided when proof succeeds.

Range syntax:
- `a ..= b` — closed range, both endpoints included
- `a .. b` — half-open, `b` excluded
- `..= b` — `MIN ..= b`
- `a ..` — `a ..= MAX`

### 2.3 Distinct types

Type aliases vs. distinct types:

```
alias Distance = Long          // structurally identical to Long
type UserId = Long             // distinct nominal type
type OrderId = Long            // also distinct from UserId
```

`UserId + OrderId` is a compile error. `UserId.toLong()` and `Long.toUserId(x)` (where the latter exists only if explicitly declared) are the conversion paths. Distinct types from underlying primitives may declare which arithmetic operations are inherited:

```
type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare
type UserId = Long derives Compare, Hash    // no arithmetic on user IDs
```

Available derives: `Add`, `Sub`, `Mul`, `Div`, `Mod`, `Compare`, `Hash`, `Equals`, `Default`. Numeric distinct types with `Add`/`Sub` permit operations only with values of the *same* type. `derives Default` is rejected when the underlying primitive's default value falls outside the declared range. The closed marker set is fixed by D034; see `docs/03-decision-log.md`.

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

Records are value types (compile to .NET `readonly struct` for primitives, `record class` otherwise — selection rule **[TBD]** based on size heuristics). Records have structural equality by default. Construction:

```
val p = Point(x = 1.0, y = 2.0)
val p2 = p.copy(x = 3.0)        // non-destructive update
```

All fields must be named at construction. Positional construction is rejected by the parser.

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

Pattern matching is exhaustive. The compiler refuses to compile a `match` that doesn't cover all cases or include a wildcard:

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

Enums are unions with no payload. Values are distinct from integers; explicit conversion is required to interoperate with numeric APIs.

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
- Clients cannot read fields, construct values directly, or pattern-match on representation.
- Reflection cannot inspect the type's fields. The compiler emits the type with sealed metadata: no public properties, no exposed constructor, fields marked invisible to .NET reflection (uses `[CompilerGenerated]` + sealed attribute scheme — exact mechanism **[TBD]**).
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

Cycles in the projection graph require explicit `@projectionBoundary` markers — **[TBD]** exact syntax.

### 2.10 Exposed records

```
exposed record TransferRequest @derive(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
}
```

`exposed` types are flat, host-visible, and may be inspected by reflection. They compile to plain .NET `record class` types. They cannot have invariants beyond what the type system enforces structurally (no `invariant:` clause). They are intended for wire-level shapes — DTOs, log payloads, config records.

`@derive(Json)`, `@derive(Sql)`, `@derive(Proto)` invoke source generators that emit serializers at compile time. No runtime serialization library is needed.

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

Constraints may be user-defined interfaces or built-in trait-like markers. The closed set of built-in markers is `Equals`, `Compare`, `Hash`, `Default`, `Copyable`, `Add`, `Sub`, `Mul`, `Div`, `Mod` (see decision log D034). All but `Copyable` are also valid in `derives` clauses; `Copyable` is structural — it asserts the type lowers to a CLR value type.

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

Interfaces support default methods. Interfaces may be stable or `@stubbable` (generates a stub builder for tests; see §10).

Multiple inheritance of interfaces is permitted; diamond conflicts are resolved by requiring explicit override.

## 3. Visibility

### 3.1 The `pub` keyword

By default, all declarations are package-private (visible only within the same package). The `pub` keyword exposes a declaration as part of the package's contract:

```
pub type AccountId = Long range 0 ..= MAX_ACCOUNT_ID
pub func openAccount(owner: in CustomerId): AccountId

func internalHelper(x: in Int): Int     // package-private
```

For records:

```
pub record Customer {
  pub id: CustomerId          // visible field
  pub email: Email
  internalNotes: String       // package-private field
}
```

A `pub` record may have non-`pub` fields, but constructing the record from outside the package requires every field to be `pub`. Outside callers use a constructor function the package provides.

For opaque types, `pub opaque type T` exposes the type's existence but not its representation. The fields inside `opaque type T { ... }` are always invisible to clients, regardless of `pub` markers.

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

## 4. Expressions

### 4.1 Operator precedence

Lyric adopts the **Swift operator precedence table** as its base, with the following modifications:

- Bitwise operators are not symbolic — use `.and()`, `.or()`, `.xor()`, `.shl()`, `.shr()` methods on integer types. This sidesteps the C-family precedence trap with `&` and `==`.
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
- Guard clauses: `case ... where condition`

Exhaustiveness is enforced. The compiler tracks variant coverage and rejects incomplete matches without `case _`.

### 4.3 Control flow

`if`/`else` is an expression:
```
val x = if cond then a else b
```

`while` and `for` are statements:
```
while condition { ... }

for x in collection { ... }

for i in 0 ..< 10 { ... }
```

`do ... while` does not exist. Use `while true { ... if cond { break } }`.

Loop control: `break`, `continue`. Both may take a label for nested loops:
```
outer: for x in xs {
  for y in ys {
    if done { break outer }
  }
}
```

### 4.4 Bindings

```
val x = 42                  // immutable
var y: Long = 100           // mutable
let z: Int = expensive()    // lazy, evaluated on first use
```

`val` is the default; mutability requires explicit `var`. Lazy bindings (`let`) are thread-safe — the standard library uses .NET's `Lazy<T>` semantics.

Type annotations are optional when inference can resolve the type. Function parameter types and return types are mandatory; `pub` declaration types are mandatory.

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

`?` works on `Result[T, E]` and `T?` (nullable). For `Result`, it returns `Err(e)` from the enclosing function on `Err`. For nullable, it returns `None` (or panics if the enclosing function does not return a nullable — **[TBD]** exact rule). The signature must declare a compatible return type, or the compiler rejects the use.

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

### 5.2 Parameter modes

- `in`: parameter is read-only inside the function. **Default mode** when no keyword is given. The compiler may pass by value or by reference; the function cannot mutate.
- `out`: parameter must be assigned exactly once before the function returns. Used for output parameters; the caller passes an uninitialized binding. Equivalent to C# `out`.
- `inout`: parameter is read/write. Caller passes a mutable binding; function may read and modify. Equivalent to C# `ref`.

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
- Async functions cannot have `out` or `inout` parameters that are non-record value types crossing await points (the value would be aliased across awaits — **[TBD]** exact rule, may need refinement based on implementation).

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

Closures capture values by reference for `var` bindings, by value for `val` bindings (this matters across thread boundaries; capturing `var` across an `async` boundary requires explicit `mut` synchronization — **[TBD]** exact mechanism).

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
- `forall` and `exists` over finite ranges or collections (decidable fragment for proof; runtime checks just iterate)
- `old(expr)` in `ensures` clauses
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

`async func` returns a value of type `Task[T]` (compiles to .NET `Task<T>` or `ValueTask<T>` per heuristic — **[TBD]**). `await` is a postfix operation in expression position.

### 7.2 Cancellation

Every `async func` has an implicit `CancellationToken` parameter threaded by the compiler. It is accessible as `cancellation` inside the function and propagated to all child async calls automatically. Cancellation is cooperative: the function periodically checks the token at await points and on explicit `cancellation.checkOrThrow()` calls.

### 7.3 Structured scopes

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

### 7.4 Protected types

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
- The compiler emits a `SemaphoreSlim`-based mutual exclusion plus condition signaling for barriers (exact lowering **[TBD]**).
- The invariant is checked after every entry/func returns control to the caller.

### 7.5 Raw locks

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

```
import Money.{Amount, Cents}
import Time.Instant
import std.collections.{Map, Set}
import std.collections as Coll      // alias
```

Wildcard imports (`import Money.*`) are not permitted. Every imported name is explicit.

### 9.3 Re-exports

```
pub use Money.Amount        // re-exports Amount as part of this package's contract
```

Re-exports surface a name from a dependency as if declared in the current package. Useful for facade packages.

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

### 11.3 AOT compatibility

All Lyric code is AOT-compatible. The compiler targets either JIT or Native AOT depending on build configuration. No reflection, no runtime code generation, no `System.Reflection.Emit` usage in compiled output.

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

## 13. Tooling

### 13.1 Compiler

`lyric build` — compiles a project. `lyric build --release` for release mode. `lyric build --aot` for Native AOT.

### 13.2 Test runner

`lyric test` runs `test` and `property` declarations in `@test_module` packages. `lyric test --properties` includes auto-generated contract property tests (slower; CI-only by default).

### 13.3 Verifier

`lyric prove` runs the SMT-backed verifier on `@proof_required` modules. Reports unverified obligations with counterexamples.

### 13.4 Documentation

`lyric doc` generates HTML/JSON documentation from doc comments and contract metadata. Includes signatures, contracts, examples (extracted from doctests), and dependency graphs.

### 13.5 Public API diff

`lyric public-api-diff <ref>` compares the current `pub` surface against a previous git ref and reports breaking changes. Used in CI to enforce SemVer discipline.

### 13.6 LSP

The language server conforms to the Microsoft Language Server Protocol (latest stable). No Lyric-specific extensions in v1.

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

**Flags:**

| Flag | Effect |
|------|--------|
| _(default)_ | Print formatted source to stdout |
| `--write` | Overwrite the file in place |
| `--check` | Exit 1 if the file would change; print nothing (CI use) |

### 13.8 Linter

`lyric lint` checks source code for style and quality issues. It works entirely from the parsed AST — no type-checker context is needed — so it is fast and runs on files that do not yet compile.

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

**Exit codes:** 0 = clean (or warnings-only without `--error-on-warning`); 1 = at least one error (or warning with the flag); 2 = usage/IO error.

**Output format:** `<code> <severity> [<line>:<col>]: <message>`, matching the compiler's own diagnostic shape.

### 13.9 Package manager

`lyric.toml` is the project manifest. Dependencies use SemVer 2.0.0. Registry: **[TBD]**.

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
