# Appendix B: Quick Reference

## B.1 Lexical

### Comments

| Syntax | Meaning |
|---|---|
| `// ...` | Line comment; discarded |
| `/* ... */` | Block comment; nestable |
| `/// ...` | Doc comment for the following item (Markdown; extracted by `lyric doc`) |
| `//! ...` | Doc comment for the enclosing module (place at top of file) |

### Numeric literals

```lyric
42            // decimal
0xFF          // hex
0o755         // octal (C-style 0755 is a lexer error)
0b1010        // binary
1_000_000     // underscore separators
100u32        // integer type suffix: u8 u16 u32 u64 i8 i16 i32 i64
3.14          // float
2.5e10        // float with exponent
3.14f32       // float type suffix: f32 f64
```

### String literals

```lyric
"hello"                    // regular
"name is ${name}"          // interpolated; escape with \${
r"C:\path\to\file"         // raw — no escapes, no interpolation
r#"contains "quotes""#     // raw with hash delimiters
"""
multi-line
string
"""                        // triple-quoted; supports interpolation
'a'   '\n'   '\u{1F600}'   // character literals (Unicode scalar)
```

### Naming conventions (formatter-enforced)

| Convention | Used for |
|---|---|
| `lowerCamelCase` | values, functions, parameters |
| `UpperCamelCase` | types, interfaces, packages |
| `SCREAMING_SNAKE` | compile-time constants |

---

## B.2 Types

### Primitive types

| Type | Size | Range / notes |
|---|---|---|
| `Bool` | 1 bit (logical) | `true`, `false` |
| `Byte` | 8-bit unsigned | `0 ..= 255` |
| `Int` | 32-bit signed | `-2_147_483_648 ..= 2_147_483_647` |
| `Long` | 64-bit signed | full Int64 range |
| `UInt` | 32-bit unsigned | `0 ..= 4_294_967_295` |
| `ULong` | 64-bit unsigned | `0 ..= 2^64 - 1` |
| `Nat` | 64-bit non-negative | `0 ..= 2^63 - 1` |
| `Float` | 32-bit IEEE 754 | |
| `Double` | 64-bit IEEE 754 | |
| `Char` | Unicode scalar | per Unicode 15+ |
| `String` | immutable UTF-8 | unbounded |
| `Unit` | unit type | single value `()` |
| `Never` | bottom type | uninhabited; assignable to any type |

Integer overflow panics in debug builds; wraps in release for unconstrained types. Range-subtypes always panic on overflow regardless of build mode.

### Type declarations

```lyric
// Range subtype — distinct nominal type, value constrained to a ..= b
type Age   = Int  range 0 ..= 150 derives Add, Sub, Compare
type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare, Hash

// Distinct type — nominally different from its underlying type
type UserId  = Long derives Compare, Hash   // no arithmetic on IDs

// Transparent alias — structurally identical; no nominal barrier
alias Distance = Long

// Record
record Point { x: Double; y: Double }
pub record Customer {
  pub id:    CustomerId
  pub email: Email
  internalNotes: String    // package-private field
}

// Sum type (union)
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case None                                    // payload-less case
}

// Payload-free enum (no integer coercion)
enum Color { case Red; case Green; case Blue }

// Container types
val fixed:   array[16, Byte]     // fixed-size; length is part of the type
val dynamic: slice[Int]          // dynamic length

// Tuple
val pair: (Int, String) = (1, "hello")

// Nullable shorthand (equivalent to Option[T])
val name: String? = None

// Standard generic unions (no import needed)
Result[T, E]    // case Ok(value: T)  | case Err(error: E)
Option[T]       // case Some(value: T)| case None
```

### Available `derives` markers

`Add` `Sub` `Mul` `Div` `Mod` `Compare` `Hash` `Equals` `Default`

`Copyable` is structural (asserts CLR value-type lowering); not valid in `derives`.

---

## B.3 Declarations

### Bindings

```lyric
val x = 42                   // immutable; type inferred
val x: Long = 42             // immutable with annotation
var y: Long = 100            // mutable
let z = expensive()          // lazy; evaluated on first use, then cached (Lazy<T> semantics)
```

### Functions

```lyric
// Expression-bodied (single expression)
func add(x: Int, y: Int): Int = x + y

// Block-bodied
func greet(name: in String): String {
  return "Hello, ${name}!"
}

// Async
async func loadUser(id: in UserId): User? { ... }

// Public
pub func openAccount(owner: in CustomerId): AccountId { ... }

// Generic (preferred bracket form)
func identity[T](x: T): T = x
func unwrapOr[T, E](r: Result[T, E], default: T): T = ...

// Generic with where clause
func sum[T](xs: slice[T]): T where T: Add + Default { ... }
```

### Annotations on functions / items

```lyric
@pure                        // may be called from contracts; no side effects
@stable(since="1.0")         // SemVer-covered; compiler enforces no downgrade calls
@experimental                // may change without a major bump
```

### Opaque types

```lyric
opaque type AccountId        // existence declared; body elsewhere in the package

opaque type Account {
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}

opaque type User @projectable {
  id:           UserId
  email:        Email
  createdAt:    Instant
  passwordHash: PasswordHash @hidden    // excluded from generated view
  invariant:    email.isVerified or createdAt > now() - days(7)
}
// Generates: exposed record UserView { ... }
//            User.toView(self): UserView
//            UserView.tryInto(self): Result[User, ContractViolation]
```

### Exposed records

```lyric
exposed record TransferRequest @derive(Json) {
  fromId:      Guid
  toId:        Guid
  amountCents: Long
}
// Flat, reflection-visible; no invariant clause; intended for DTOs / wire shapes.
// @derive(Json|Sql|Proto) invokes compile-time source generators.
```

### Interfaces and implementations

```lyric
interface Repository[T, Id] {
  async func findById(id: in Id): T?
  async func save(entity: in T): Unit
}

@stubbable               // generates a stub builder for tests
interface Clock {
  func now(): Instant
}

impl Repository[User, UserId] for PostgresUserRepository {
  async func findById(id: in UserId): User? { ... }
  async func save(entity: in User): Unit    { ... }
}
```

### Protected types (Ada-style shared mutable state)

```lyric
protected type BoundedQueue[T] {
  var items: array[100, T]
  var count: Nat range 0 ..= 100

  invariant: count <= 100

  entry put(item: in T)
    when: count < 100
  { items[count] = item; count += 1 }

  entry take(): T
    when: count > 0
  { count -= 1; return items[count] }

  func peek(): T?     // exclusive; no concurrent reads in v0.1
  { return if count > 0 then Some(items[count - 1]) else None }
}
```

`entry` operations are exclusive and may have a `when:` barrier (caller blocks until condition is true). The invariant is checked after every `entry`/`func` returns.

### Wire blocks (compile-time DI graph)

```lyric
wire ProductionApp {
  @provided config: AppConfig
  @provided cancellationToken: CancellationToken

  singleton clock: Clock = SystemClock.make()
  singleton db:    DatabasePool = DatabasePool.make(config.dbUrl, config.dbPoolSize)

  scoped[Request] dbConnection: DatabaseConnection = db.acquire()

  bind AccountRepository -> PostgresAccountRepository.make(dbConnection)
  bind Clock             -> clock

  singleton transferService: TransferService =
      TransferService.make(AccountRepository, Clock)

  expose transferService
}
// Generates: bootstrap(config, cancellationToken) -> WireInstance
```

---

## B.4 Expressions and operators

### Operator precedence (highest to lowest)

| Level | Operators | Associativity |
|---|---|---|
| postfix | `f(x)` `a[i]` `.field` `?` (propagation) | left |
| prefix | `-x` `not x` `&x` | right |
| range | `..` `..=` `..<` | non-associative |
| multiplicative | `*` `/` `%` | left |
| additive | `+` `-` | left |
| nil-coalescing | `??` | right |
| comparison | `==` `!=` `<` `<=` `>` `>=` | non-associative (no chaining) |
| logical-and | `and` | left |
| logical-or | `or` `xor` | left |
| assignment | `=` `+=` `-=` `*=` `/=` `%=` | right |

Bitwise ops are methods: `.and()` `.or()` `.xor()` `.shl()` `.shr()`. No `?:` ternary; use `if … then … else …`.

### Pattern matching

```lyric
val result = match shape {
  case Circle(r) where r > 100.0 -> "large circle"
  case Circle(r)                 -> "radius ${r}"
  case Rectangle(w, h) if w == h -> "square"
  case Rectangle(w, h)           -> "rectangle"
  case _                         -> "other"
}
```

Pattern kinds:

| Pattern | Syntax |
|---|---|
| Wildcard | `_` |
| Literal | `42` `"hello"` `true` |
| Binding | `x` |
| Constructor | `Circle(r)` `Some(v)` `Ok(x)` |
| Record destructure | `Point { x, y }` `Point { x = 0.0, y }` |
| Tuple | `(a, b)` |
| Range | `0 ..= 9` |
| Alternative | `A \| B` |
| Guard | `case … where condition` or `case … if condition` |
| Type test (reserved) | `x is T` |

Match must be exhaustive; add `case _ ->` to opt out of exhaustiveness.

### Control flow

```lyric
// if is an expression
val x = if cond then a else b

// block form (else optional)
if cond { ... } else { ... }

// loops (statements)
while condition { ... }
for x in collection { ... }
for i in 0 ..< 10 { ... }     // half-open range

// labelled break / continue
outer: for x in xs {
  for y in ys {
    if done { break outer }
    if skip { continue outer }
  }
}
```

No `do … while`; use `while true { ... if cond { break } }`.

### Special expressions

```lyric
x?                     // error propagation: return Err(e) / None on failure
x ?? fallback          // nil-coalescing: fallback if x is None
{ x: Int -> x * 2 }   // closure / lambda
await expr             // suspend until task completes (inside async func)
spawn expr             // launch task within enclosing scope
scope { ... }          // structured-concurrency boundary (see §B.3)
defer { ... }          // run on scope exit regardless of success/failure
old(expr)              // pre-state value of expr (inside ensures clauses only)
unsafe { ... }         // escape hatch; prover treats body as opaque
```

---

## B.5 Parameter modes

| Mode | Keyword | Meaning |
|---|---|---|
| read-only | `in` (default; may be omitted) | Caller's value is not modified; compiler may pass by value or reference |
| write-only | `out` | Must be assigned exactly once on every path before return; caller passes uninitialized binding |
| read-write | `inout` | Caller passes a mutable binding; function may read and modify |

```lyric
func divmod(n: Int, d: Int, q: out Int, r: out Int) {
  q = n / d
  r = n % d
}

func incrementAll(xs: inout slice[Int]) {
  for i in 0 ..< xs.length { xs[i] = xs[i] + 1 }
}
```

`out`/`inout` parameters lower to CLR byref. Async functions cannot have `out`/`inout` parameters that cross await points.

---

## B.6 Contracts

```lyric
func transfer(from: in AccountId, to: in AccountId, amount: in Cents): Result[Unit, TransferError]
  requires: amount > 0
  requires: from != to
  ensures:  result.isOk implies old(fromBalance) - amount == fromBalance
{
  ...
}

opaque type Account {
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}
```

Contract expression rules: pure only — no side effects, no I/O, no mutation. May use `@pure`-marked functions, `forall`/`exists` over finite ranges, `old(expr)`, `result`, and `implies`.

### Verification levels (package-level annotations)

```lyric
@runtime_checked          // default; contracts are runtime asserts
package Account

@proof_required           // SMT solver must discharge every obligation at compile time
package Transfer

@proof_required(unsafe_blocks_allowed)   // as above, with unsafe { } escape hatches
package Transfer
```

### Axiom boundaries

```lyric
@axiom("System.IO.File.ReadAllText reads file content")
extern func readFile(path: in String): String
  ensures: result != ""    // assumed by the prover, not proved
```

### Pre-state snapshots in ensures

```lyric
ensures: old(account.balance) - amount == account.balance
//        ^^^— value of account.balance at function entry
```

---

## B.7 Module system

### Package and imports

```lyric
package Account                              // file declaration; must match directory name

import Money.{Amount, Cents}                 // named imports
import Time.Instant                          // single name
import Std.Collections as Coll              // alias
pub use Money.Amount                         // re-export (facade pattern)
```

Wildcard imports (`import Foo.*`) are not permitted.

### Test modules

```lyric
@test_module
package Account                              // may access non-pub names of its package

test "description" { ... }
property "description" forall (n: Int) where n > 0 { ... }
fixture myData: MyType = MyType.make()
```

### `lyric.toml` fields

```toml
[project]
name    = "myapp"
version = "1.0.0"

[dependencies]
Money = "^2.1"

[dev-dependencies]
TestHelpers = "^1.0"
```

---

## B.8 Annotations

| Annotation | Placement | Meaning |
|---|---|---|
| `@axiom` | package, `extern func` | Contracts are trusted, not verified; required on `extern package` |
| `@axiom("description")` | `extern func` | Axiom with audit-visible rationale string |
| `@derive(Json\|Sql\|Proto)` | `exposed record` | Emit compile-time serializer for the named target |
| `@experimental` | `pub` item | May change without SemVer major bump |
| `@global_clock_unsafe` | function | Suppresses the proof-system warning for non-`@stubbable` clock access |
| `@hidden` | field in `@projectable` opaque type | Excluded from generated view type |
| `@projectable` | `opaque type` | Generate a sibling `exposed record XView` and projection functions |
| `@projectable(json, sql)` | `opaque type` | Restrict generated views to named targets |
| `@projectionBoundary(asId)` | field | Break a projection cycle; emit the field as an opaque handle |
| `@proof_required` | package | All contracts must be SMT-discharged at compile time |
| `@proof_required(unsafe_blocks_allowed)` | package | As above, with `unsafe { }` permitted |
| `@provided` | wire member | Parameter to the generated bootstrap function |
| `@pure` | function | No side effects; callable from contracts and `@proof_required` code |
| `@runtime_checked` | package | Contracts are runtime asserts (default) |
| `@stable(since="X.Y")` | `pub` item | API is frozen from version X.Y; SemVer-major to remove |
| `@stubbable` | interface | Generate a test-stub builder for the interface |
| `@test_module` | package | May contain `test`/`property`/`fixture` items; can access package internals |
| `@valueType` | record or opaque type | Force CLR value-type lowering (struct) |

---

## B.9 Standard library modules

| Module | Provides | Key names |
|---|---|---|
| `Std.Core` | `Result`, `Option`, built-in ops | `Ok`, `Err`, `Some`, `None`, `println`, `panic`, `assert`, `expect`, `toString`, `default` |
| `Std.String` | String manipulation | `trim`, `split`, `join`, `contains`, `startsWith`, `toUpperCase`, `substring` |
| `Std.Parse` | Numeric parsing | `tryParseInt`, `tryParseLong`, `tryParseDouble`, `tryParseBool` |
| `Std.Errors` | Standard error types | `ParseError`, `IOError`, `HttpError` |
| `Std.File` | File system | `readText`, `writeText`, `fileExists`, `createDir` |
| `Std.Collections` | Generic growable containers | `List[T]` (`add`, `count`, `get`), `Map[K,V]` (`[]`, `containsKey`, `remove`) |
| `Std.Math` | Numeric utilities | `abs`, `min`, `max`, `sqrt`, `pow`, `floor`, `ceil` |
| `Std.Random` | Pseudo-random values | `nextInt`, `nextDouble`, `nextBool` |
| `Std.Time` | Instants and durations | `Instant`, `Duration`, `Clock` interface, `now`, ISO-8601 parsing |
| `Std.Json` | RFC 8259 JSON | `serialize`, `deserialize`, `JsonValue` |
| `Std.Http` | HTTP client/server primitives | `get`, `post`, `HttpRequest`, `HttpResponse`, `statusCode` |
| `Std.Testing` | Test assertions | `expect`, `expectEq`, `expectErr`, `fail` |
| `Std.Testing.Snapshot` | Snapshot testing | `snapshot(label, actual)`, `snapshotMatch(label, actual)` |
| `Std.Testing.Property` | Property-based testing | `forAllIntRange`, `forAllBool`, `forAllDouble`, `forAllIntPair` |
| `Std.Iter` | Lazy iteration | `map`, `filter`, `fold`, `take`, `skip`, `collect` |

Codegen builtins (no import needed): `println`, `panic`, `expect`, `assert`, `toString(x)`, `format1`/`format2`/`format3`/`format4`, `default()`.

---

## B.10 CLI commands

```sh
# Build
lyric build <file.l>                   # compile to .dll + .runtimeconfig.json
lyric build --release <file.l>         # release build (contracts elided for @runtime_checked)
lyric build --aot <file.l>             # Native AOT; no .NET runtime at deployment
lyric build --manifest lyric.toml      # build from project manifest

# Run
lyric run <file.l>                     # compile and immediately execute
lyric run <file.l> -- arg1 arg2        # pass arguments to the program

# Test
lyric test                             # run test blocks in @test_module packages
lyric test --properties                # include property-based tests (slower; CI-only by default)
lyric test --doctests                  # include code examples from doc comments
lyric test --update-snapshots          # accept current output as the new snapshot baseline

# Format
lyric fmt <file.l>                     # print formatted source to stdout (no configuration)
lyric fmt --write <file.l>             # overwrite file in place
lyric fmt --check <file.l>             # exit 1 if not formatted; print nothing (CI gate)
# Note: non-doc (//) comments are not preserved — only /// and //! survive

# Lint
lyric lint <file.l>                    # report style/quality diagnostics (AST-only; fast)
lyric lint --error-on-warning <file.l> # treat warnings as errors (CI gate)
# Codes: L001 PascalCase types, L002 camelCase funcs, L003 missing pub doc,
#        L004 TODO/FIXME in doc, L005 pub func without contracts

# Documentation
lyric doc <file.l>                     # generate HTML/JSON docs from doc comments + contracts

# Verification
lyric prove <file.l>                   # run SMT verifier on @proof_required modules
lyric prove --allow-unverified <file.l> # downgrade V0007 (unknown) from error to warning
lyric prove --explain --goal N <file.l> # show the VC IR for goal N
lyric prove --json <file.l>            # machine-readable output

# Package management
lyric restore                          # download dependencies declared in lyric.toml
lyric publish                          # publish package to registry (NuGet piggyback)

# Tooling
lyric public-api-diff <old.dll> <new.dll>  # diff pub surfaces; exits 0 (compatible) or 2 (breaking)
```

---

## B.11 Error codes

### Linter (L-series)

| Code | Severity | Meaning |
|---|---|---|
| `L001` | error | Type name must be `PascalCase`; constants must be `PascalCase` or `UPPER_SNAKE_CASE` |
| `L002` | error | Function name (including `entry` in `protected` blocks) must be `camelCase` |
| `L003` | warning | `pub` item has no doc comment (`///`) |
| `L004` | warning | Doc comment contains `TODO` or `FIXME` |
| `L005` | warning | `pub func` with a block body has no `requires:`/`ensures:` contracts |

### Type checker (T-series)

| Code | Meaning |
|---|---|
| `T0001` | Package-level error (e.g. duplicate declaration) |
| `T0010` | Unknown type name |
| `T0012` | Primitive type does not take type arguments |
| `T0013` | Name is not a type |
| `T0020` | Unknown name (undefined variable or function) |
| `T0030` | Arithmetic on a non-numeric type |
| `T0031` | Arithmetic operands have mismatched types |
| `T0032` | Equality operands have mismatched types |
| `T0033` | Comparison operands must be matching ordered types |
| `T0034` | Logical operator applied to non-Bool operand |
| `T0035` | `??` operand type mismatch |
| `T0036` | Unary minus on non-numeric type |
| `T0037` | `not` applied to non-Bool operand |
| `T0041` | List literal elements have mismatched types |
| `T0042` | Wrong number of arguments to function call |
| `T0043` | Argument type does not match parameter type |
| `T0044` | Called value is not a function |
| `T0050` | Unknown type parameter in where clause |
| `T0051` | Unknown constraint marker in where clause |
| `T0060` | `val` binding type annotation does not match initialiser |
| `T0061` | `var` binding type annotation does not match initialiser |
| `T0062` | `let` binding type annotation does not match initialiser |
| `T0063` | Assignment type does not match target type |
| `T0064` | `return` without value in non-Unit function |
| `T0065` | Returned type does not match declared return type |
| `T0066` | `while` condition is not Bool |
| `T0070` | Function body type does not match declared return type |
| `T0080` | `old(…)` used outside an `ensures` clause |
| `T0085` | `out`/`inout` argument must be a mutable l-value |
| `T0086` | `out` parameter not assigned on all paths before return |
| `T0090` | Range bounds are inverted or produce an empty range |
| `T0091` | `range` applied to a non-numeric underlying type |
| `T0093` | Range bound expression cannot be evaluated at compile time |

### Emitter (E-series)

| Code | Meaning |
|---|---|
| `E0001` | No `main` function found (entry point missing) |
| `E0003` | Unsupported expression or statement in code generation |
| `E0004` | Unresolved name at code generation time |
| `E0012` | Unsupported type in code generation |
| `E0030` | `extern package` refers to a BCL type not in the stdlib shim |
| `E0085` | Unsupported FFI dispatch pattern |
| `E0201` | Type mismatch (reported at the call site; e.g. wrong argument type) |
| `E0301` | Non-exhaustive match — lists the missing case name |
| `E0900` | Internal emitter error (unexpected AST shape) |
| `E0901` | Internal emitter error (unexpected type shape) |

### Stability (S-series)

| Code | Meaning |
|---|---|
| `S0001` | Non-experimental `pub` function calls an `@experimental` callee |
| `S0002` | Item annotated with both `@stable` and `@experimental` |

### Verifier (V-series)

| Code | Severity | Meaning |
|---|---|---|
| `V0001` | error | `@proof_required` package imports a `@runtime_checked` package |
| `V0002` | error | `@proof_required` function calls a non-`@pure` / non-`@proof_required` callee |
| `V0003` | error | `unsafe { }` block exits without an explicit `assert` |
| `V0004` | error | `@axiom` annotation on a function that has a non-empty body |
| `V0005` | error | `@proof_required` loop has no `invariant:` clause |
| `V0006` | error | Quantifier domain is not in the decidable fragment |
| `V0007` | error (warning with `--allow-unverified`) | Solver returned `unknown` — budget exhausted |
| `V0008` | error | Proof failed — counterexample available (`name : sort = value` bindings) |
| `V0009` | error | `assume` used in `@proof_required` code outside `unsafe { }` |
