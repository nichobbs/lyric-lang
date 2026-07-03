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
'a'   '\n'   '\u{20AC}'    // character literals (BMP scalar, U+0000–U+FFFF)
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
  var count: Int           // mutable field (mutability enforcement: T6+)
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

`Add` `Sub` `Mul` `Div` `Mod` `Compare` `Ord` `Hash` `Equals` `Default`

`Ord` synthesises `compare(self, other): Int` (negative/zero/positive); valid on records, unions, enums, and distinct types. `Copyable` is structural (asserts CLR value-type lowering); not valid in `derives`.

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
exposed record TransferRequest @generate(Json) {
  fromId:      Guid
  toId:        Guid
  amountCents: Long
}
// Flat, reflection-visible; no invariant clause; intended for DTOs / wire shapes.
// @generate(Json|Sql|Proto) invokes built-in source generators; @generate(Pkg.Name) invokes custom ones.
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

### Config blocks (runtime env-var-backed config)

```lyric
// Declared at module scope; package-private; not a type.
config Server {
  host:    String                   = "0.0.0.0"
  port:    Int range 1 ..= 65535   = 8080
  @sensitive
  secret:  String                             // required — no default; exits with G0001 if unset
}

// Access: BlockName.fieldName (static qualifier)
func main(): Unit {
  println("binding " + Server.host + ":" + Server.port.toString())
}
```

Env var derivation: `LYRIC_CONFIG_<PKG_UPPER>_<BLOCK_UPPER>_<FIELD_UPPER>` (`.` → `_`).  
Custom name: `port: Int = 8080 via "APP_PORT"`.  
Field types: `Bool`, `Int`, `Long`, `Float`, `Double`, `String`, range subtypes, simple enums, `[T]` (comma-separated).  
Exit code 78 (`EX_CONFIG`) on startup failure.  See chapter 21.

### Aspects

```lyric
// Matching aspect (package-private; weaves over functions in the same package)
aspect Logging {
  matches: name like "handle*"

  around(args) -> ret {
    Std.Log.info("→ entering")
    proceed(args)
    Std.Log.info("← done")
  }
}

// With contract augmentation
aspect Positive {
  matches: name like "add*"
  requires: true   // composed additively with the function's own requires:

  around(args) -> ret {
    proceed(args)
  }
}

// Explicit composition order: Auth runs before Logging
aspect Auth {
  matches: name like "handle*"
  wraps: Logging

  around(args) -> ret {
    if not AuthStore.verify() { return Result.err(AuthError.unauthorized()) }
    proceed(args)
  }
}
```

Predicates in `matches:` are joined by `and` (all must hold):  
`name like "<glob>"` — short name glob (`*`, `?`, `[abc]`, `[a-z]`).  
`annotated: @Name` — carries the named annotation.  
`visibility: pub | priv | internal` — declared access level.  
`signature: returns "<glob>"` — return type string matches glob (e.g. `"Int"`, `"Result[*,*]"`).  
`except name in { fn1, fn2 }` — exclude specific names.  
Ordering: `wraps: OtherAspect` (this aspect is outer), `inside: OtherAspect` (this aspect is inner). Default: lexical declaration order.  
Opt-out: `@no_aspect` (all aspects) / `@no_aspect("Name")` (named aspect, string literal).  See chapter 22.

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

Numeric / character conversions are explicit methods (no implicit widening): `.toByte()` `.toInt()` `.toLong()` `.toChar()` `.toDouble()` on `Byte`/`Int`/`Long`/`Double`/`Char`. Widening is lossless; narrowing truncates toward zero; `.toByte()` reduces modulo 256 (`Byte` is unsigned 0..255). Mix widths via `acc + b.toInt()`, never `acc + b`. (Unsigned `UInt`/`ULong`/`Nat` and `.toFloat()` reserved pending backend support; `.toX()` on `String`/`Bool`/`Unit` is a `T0103` error.)

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
| Const reference | `@NAME` (compares against the value of `val`/`const NAME`) |
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
yield expr             // emit element from async generator (turns async func into IAsyncEnumerable<T>)
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

### Error-handling helpers (Std.Core)

```lyric
import Std.Core

// Map success value of a Result
mapResult(r, { v -> v * 2 })           // Result[Int, E]

// Map error value of a Result (e.g. at package boundaries)
mapResultErr(r, { e -> MyError(e) })   // Result[T, MyError]

// Chain a fallible operation on the Ok value
andThenResult(r, { v -> doMore(v) })   // Result[U, E]

// Unwrap with a default on Err
unwrapResultOr(r, 0)                    // T

// Unwrap; panic if Err (use only when Err is impossible by construction)
unwrapResult(r)                         // T

// Option equivalents
mapOption(opt, { v -> v * 2 })         // Option[Int]
unwrapOr(opt, "default")               // T
unwrapOption(opt)                      // T (panics if None)
isSome(opt)                            // Bool
isNone(opt)                            // Bool
isOk(r)                                // Bool
isErr(r)                               // Bool
```

### Direct BCL/JDK calls — `extern type` (auto-FFI; see chapter 13 §13.9)

**`--target dotnet`** — signature read from .NET reference-assembly metadata:

```lyric
extern type Math = "System.Math"          // bind a Lyric name to a CLR type
extern type Ts   = "System.TimeSpan"
extern type Typ  = "System.Type"

Math.Max(2, 5)                            // static overload, resolved from metadata -> 5
Ts.Compare(Ts.FromMinutes(5.0),           // value-type params & returns
           Ts.FromMinutes(3.0))           //   -> 1
Typ.GetType("System.Int32").ToString()    // class return + instance dispatch (callvirt)
                                          //   -> "System.Int32"

extern type SBld = "System.Text.StringBuilder"
SBld.new()                                // constructor shorthand (docs/48) -> empty StringBuilder
SBld.new(64).Length                       // constructor + property access -> 0
```

**`--target jvm`** — signature read from JDK `.jmod` metadata (epic #1622):

```lyric
extern type JMath          = "java.lang.Math"
extern type JInteger       = "java.lang.Integer"
extern type JStringBuilder = "java.lang.StringBuilder"

JMath.max(3, 7)                  // invokestatic Math.max(II)I -> 7
JMath.floor(3.7)                 // invokestatic Math.floor(D)D -> 3.0
JInteger.valueOf(42).intValue()  // invokestatic + invokevirtual -> 42
JStringBuilder.new("hi")         // new + invokespecial <init> -> StringBuilder("hi")
JStringBuilder.new("hi").length() // constructor + instance method -> 2
```

For third-party classes, set `LYRIC_FFI_JARS` to a colon-separated JAR classpath; the emitter scans those JARs after the JDK jmods.

No `@axiom` block needed: the signature is read from the assembly/jmod/JAR at compile time. No overload match is a compile-time error (never silently mis-bound).

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

import Money.{Amount, Cents}                 // named imports from Lyric packages
import Time.Instant                          // single name
import Std.Collections as Coll              // alias
pub use Money.Amount                         // re-export (facade pattern)

import extern System.Net.Http.{HttpClient}   // named imports from external (host) packages
pub use extern Docker.DotNet.{DockerClient}  // re-export external type
```

Wildcard imports (`import Foo.*`) are not permitted. External type imports (those with `extern` keyword) require a selector group `{ ... }` and are scoped to the importing package.

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
[package]
name    = "myapp"
version = "1.0.0"
authors = ["alice <alice@example.com>"]
license = "MIT"

[dependencies]
Money = "^2.1"                          # registry/NuGet channel
Lyric.Web = { path = "../lyric-web" }  # local-path dep (pre-built DLL in <dep>/bin/)

# NuGet interop — resolved by `lyric restore`, shims generated in _extern/
[nuget]
"Newtonsoft.Json" = "13.0.3"

[nuget.options]
allow_native = false               # allow packages with native binaries
target       = "net10.0"           # target framework moniker (default: net10.0)

# Native (--target native / LLVM backend) build defaults — see chapter 20 / lang-ref §3.6
[native]
triple     = "x86_64-unknown-linux-gnu"  # default: auto-detect host; overridden by --triple
opt_level  = "2"                          # clang -O level 0|1|2|3|s; overridden by --opt
extra_libs = ["ssl", "crypto"]            # extra clang -l<name> link flags (manifest-only)

# Optional — opt in for project-as-DLL bundling (M5.1 stage 2c.2):
[project]
name           = "myapp"
output         = "single"          # | "per-package"
output_assembly = "myapp.dll"

[project.packages]
"myapp.Core" = "src/core"
"myapp.Web"  = "src/web"
```

---

## B.8 Annotations

| Annotation | Placement | Meaning |
|---|---|---|
| `@axiom` | package, `extern func` | Contracts are trusted, not verified; required on `extern package` |
| `@axiom("description")` | `extern func` | Axiom with audit-visible rationale string |
| `@bench` | `func` | Marks a zero-argument `Unit`-returning function as a benchmark entry point |
| `@bench_module` | package | Marks the file as a benchmark suite; required by `lyric bench` |
| `@body` | handler parameter | Marks the parameter that receives the deserialized HTTP request body |
| `@cfg(feature = "X")` | any item | Erase item when feature `X` is not active; see chapter 20 §20.7 |
| `@cfg(any(feature = "X", feature = "Y"))` | any item | Erase unless at least one listed feature is active |
| `@delete` / `@get` / `@patch` / `@post` / `@put` | handler function | HTTP method annotation (lyric-web code-first) |
| `@generate(Json\|Sql\|Proto)` | `exposed record`, `record`, `union`, `interface` | Invoke built-in source generator for the named target |
| `@generate(Pkg.Name)` | `exposed record`, `record`, `union`, `interface` | Invoke custom source generator from package `Pkg` |
| `@experimental` | `pub` item | May change without SemVer major bump |
| `@inline_template` | `pub aspect` | C-mode template: weaver rewrites `args.<field>` to bare `<field>` paths against the matched function's parameters; mismatches surface as A0042 diagnostics. Without this annotation a `pub aspect` template is B′-mode by default (shared shape-keyed specialisation, no dedicated annotation); `args.<field>` in a B′-mode template body is a hard error (A0046) unless the `around` advice declares the field(s) in a `where TArgs has { field: Type, ... }` row clause (chapter 22 §22.7), in which case a matched function missing the field is A0047 instead |
| `@global_clock_unsafe` | function | Suppresses the proof-system warning for non-`@stubbable` clock access |
| `@hidden` | field in `@projectable` opaque type | Excluded from generated view type |
| `@projectable` | `opaque type` | Generate a sibling `exposed record XView` and projection functions |
| `@projectable(json, sql)` | `opaque type` | Restrict generated views to named targets |
| `@projectionBoundary(asId)` | field | Break a projection cycle; emit the field as an opaque handle |
| `@proof_required` | package | All contracts must be SMT-discharged at compile time |
| `@proof_required(unsafe_blocks_allowed)` | package | As above, with `unsafe { }` permitted |
| `@no_aspect` | function | Opt out of all aspects in the package |
| `@no_aspect("Name")` | function | Opt out of a specific named aspect (name is a string literal) |
| `@provided` | wire member | Parameter to the generated bootstrap function |
| `@pure` | function | No side effects; callable from contracts and `@proof_required` code |
| `@runtime_checked` | package | Contracts are runtime asserts (default) |
| `@sensitive` | `config` field | Mark field value as secret; redacted in diagnostics and `lyric explain` output |
| `@stable(since="X.Y")` | `pub` item | API is frozen from version X.Y; SemVer-major to remove |
| `@stubbable` | interface | Generate a test-stub builder for the interface |
| `@tag("group")` | handler function | OpenAPI tag for grouping in Swagger UI (lyric-web) |
| `@test_module` | package | May contain `test`/`property`/`fixture` items; can access package internals |
| `@valueType` | record or opaque type | Force CLR value-type lowering (struct) |

---

## B.9 Standard library modules

| Module | Provides | Key names |
|---|---|---|
| `Std.Core` | `Result`, `Option`, built-in ops | `Ok`, `Err`, `Some`, `None`, `println`, `panic`, `assert`, `expect`, `toString`, `default`, `mapResult`, `mapResultErr`, `mapOption`, `andThenResult`, `unwrapResultOr`, `unwrapErrOr`, `unwrapResult`, `unwrapOption`, `unwrapOr`, `isOk`, `isErr`, `isSome`, `isNone` |
| `Std.Core.Proof` | Proof-required witness functions | `identity`, `fst`, `snd`, `minInt`, `maxInt` (all `@pure @experimental`) |
| `Std.String` | String manipulation | `trim`, `split`, `join`, `contains`, `startsWith`, `toUpperCase`, `substring` |
| `Std.Parse` | Numeric parsing | `tryParseInt`, `tryParseLong`, `tryParseDouble`, `tryParseBool` |
| `Std.Errors` | Standard error types | `ParseError`, `IOError`, `HttpError` |
| `Std.File` | File system | `readText`, `writeText`, `fileExists`, `createDir` |
| `Std.Collections` | Generic growable containers | `List[T]` (`add`, `count`, `get`), `Map[K,V]` (`[]`, `containsKey`, `remove`) |
| `Std.Set` | Hash set | `Set[T]`, `setContains`, `setAdd`, `setRemove`, `setSize`, `setFromSlice`, `setUnion`, `setIntersection`, `setDifference` |
| `Std.Sort` | Stable sort | `sort[T](xs, cmp)`, `sortInts`, `sortLongs`, `sortStrings` |
| `Std.Math` | Numeric utilities | `abs`, `min`, `max`, `sqrt`, `pow`, `floor`, `ceil` |
| `Std.Random` | Pseudo-random values | `nextInt`, `nextDouble`, `nextBool` |
| `Std.SecureRandom` | Cryptographically-strong randomness | `secureNextInt`, `secureNextIntRange`, `secureGetBytes` |
| `Std.Hash` | Cryptographic hashing | `sha256OfBytes`, `sha512OfBytes`, `sha512OfFile` |
| `Std.Char` | Unicode character utilities | `isLetter`, `isDigit`, `isWhiteSpace`, `isUpperCase`, `isLowerCase`, `toUpperCase`, `toLowerCase`, `toInt`, `fromInt`, `digitValue`, `hexDigitValue` |
| `Std.Format` | Number and string formatting | `toHexString`, `toHexStringUpper`, `formatFixed`, `zeroPad`, `hexPad`, `padLeft`, `padRight` |
| `Std.Encoding` | Byte-level encoding | `encodeBase64`, `tryDecodeBase64`, `encodeHex`, `tryDecodeHex`, `encodeUtf8`, `tryDecodeUtf8` |
| `Std.Uuid` | UUID generation and parsing | `Uuid`, `newUuid`, `nilUuid`, `uuidToString`, `parseUuidOpt` |
| `Std.Stream` | I/O stream interfaces | `ByteReader`, `ByteWriter`, `TextReader`, `TextWriter`, `Closable` |
| `Std.Time` | Instants and durations | `Instant`, `Duration`, `Clock` interface, `now`, ISO-8601 parsing |
| `Std.Json` | RFC 8259 JSON | `serialize`, `deserialize`, `JsonValue` |
| `Std.Http` | HTTP client/server primitives | `get`, `post`, `HttpRequest`, `HttpResponse`, `statusCode` |
| `Std.Testing` | Test assertions | `assertTrue`, `assertEqual`, `assertEqualInt`, `assertPanics`, `assertPanicsWith` |
| `Std.Testing.Snapshot` | Snapshot testing | `snapshot(label, actual)`, `snapshotMatch(label, actual)` |
| `Std.Testing.Property` | Property-based testing | `forAllIntRange`, `forAllBool`, `forAllDouble`, `forAllIntPair` |
| `Std.Testing.Mocking` | Stub call-count tracking | `StubCounter`, `makeStubCounter`, `stubCounterGet`, `stubCounterIncrement`, `stubCounterReset` |
| `Std.Iter` | Lazy iteration | `map`, `filter`, `fold`, `take`, `skip`, `collect` |
| `Std.App` | Application entry and config | `run(main: func Unit): Int`, `withConfig`, `Config` (opaque), `Config.path`, `Config.rawText` |
| `Std.Console` | Console I/O | `print`, `println`, `error`, `readLine` |
| `Std.Directory` | Directory operations | `exists`, `create`, `createRecursive`, `enumerate`, `enumerateFiles`, `enumerateDirectories`, `delete`, `deleteRecursive` |
| `Std.Environment` | Process environment | `getVar`, `getVarOrDefault`, `args`, `exitCode` |
| `Std.Log` | Structured logging | `LogLevel` enum, `Logger` interface, `LogField`, `log`, `debug`, `info`, `warn`, `error`, `field` |
| `Std.Path` | Pure path manipulation | `join`, `extension`, `basename`, `dirname`, `isAbsolute`, `isRelative` |

**External libraries** (separate packages; add to `[dependencies]` in `lyric.toml`):

> **Stability framing (Tier 5 — #367).** Per-library stability is now
> declared in each library's module doc-comment:
>
> - **`@stable(since="0.1")`** — `lyric-auth`, `lyric-mq`, `lyric-aws-secrets`.
>   Public API covered by the SemVer guarantee.  Tested.
> - **`@experimental` + WARNING banner** — `lyric-session`, `lyric-storage`.
>   Surface compiles and has tests, but the production backend (Redis,
>   S3/Azure Blob) has not been driven against a live provider in CI.
> - **`@experimental`** — every other `lyric-*` package in the table below.
>   Public API may change without a SemVer major bump until v1.0; test
>   coverage is uneven; cross-target (.NET / JVM) parity is incomplete.
>   Use in production with awareness of these gaps.  (`lyric-health`'s
>   former kernel-dispatcher gap is closed: checks are registered as
>   function references and `runChecks` invokes them directly — D099.)
>
> See [issue #367](https://github.com/nichobbs/lyric-lang/issues/367) for
> the remediation plan that drives every entry toward `@stable` ahead of
> v1.0.

| Package | Provides | Key names |
|---|---|---|
| `Std.Logging` *(lyric-logging)* | Named loggers, six levels, structured fields, JSON/text output | `Logger`, `LogLevel`, `LogField`, `getLogger`, `info`, `warn`, `error`, `field` |
| `Std.Logging.Aspects` *(lyric-logging)* | Aspect templates for logging | `CallLogging`, `SlowCallAlert`, `ErrorResultLogging` |
| `OTel` *(lyric-otel)* | OpenTelemetry tracing, metrics, logging | `Tracing`, `Metrics`, `Logging` (pub aspects), `startSpan`, `endSpan` |
| `Web` *(lyric-web)* | HTTP routing, ApiError, server entry point | `Router`, `ApiError`, `Route`, `create`, `addGet`, `addPost`, `start` |
| `Web.OpenApi` *(lyric-web)* | OpenAPI 3.1 type vocabulary and builder | `Spec`, `Schema`, `Operation`, `PathItem`, `newSpec`, `addPath` |
| `Web.Aspects` *(lyric-web)* | Auth and rate-limit aspect templates | `RequiresAuth`, `RateLimit` |
| `Cache` *(lyric-cache)* | In-memory/disk TTL cache | `CacheBucket`, `inProcess`, `get`, `set`, `delete` |
| `Db` *(lyric-db)* | Typed SQL query helpers | `DbConnection`, `DbParam`, `execute`, `query`, `queryOne`, `withTransaction` |
| `Health` *(lyric-health)* | Health-check endpoints | `HealthRegistry`, `HealthResult`, `ok`, `degraded`, `unhealthy` |
| `Jobs` *(lyric-jobs)* | Background job scheduling | `JobHandler`, `JobScheduler`, `InProcessJobScheduler`, `enqueue`, `schedule`, `cancel`, `status`, `results` |
| `Mail` *(lyric-mail)* | Email sending | `MailSender`, `EmailMessage`, `sendSimple`, `sendHtml`, `connectSmtp` |
| `Mq` *(lyric-mq)* | Message queuing | `MessageQueue`, `QueueConsumer`, `publish`, `publishBatch`, `subscribe` |
| `Search` *(lyric-search)* | Search engine client | `SearchClient`, `SearchResult`, `IndexResult`, `search`, `index` |
| `Session` *(lyric-session)* | Distributed session management | `SessionStore`, `SessionData`, `newSession`, `loadSession`, `get`, `set` |
| `Validation` *(lyric-validation)* | Input validation | `ValidationError`, `required`, `minLength`, `email`, `url`, `all`, `toResult` |
| `Ws` *(lyric-ws)* | WebSocket server | `WsHandler`, `WsRegistry`, `WsMessage`, `send`, `broadcast` |
| `Flags` *(lyric-feature-flags)* | Runtime feature toggles | `FlagStore`, `getBool`, `getString`, `getInt`, `enable`, `disable` |
| `I18n` *(lyric-i18n)* | Internationalisation | `TranslationStore`, `Locale`, `translate`, `translateWith`, `makeLocale` |
| `Testing` *(lyric-testing)* | Test mocks and assertions | `TestContext`, `assertOk`, `assertErr`, `assertEq`, `MockMailSender` |

Codegen builtins (no import needed): `println`, `panic`, `expect`, `assert`, `toString(x)`, `format1`/`format2`/`format3`/`format4`/`format5`/`format6`, `default()`.

String method-syntax (UFCS) ops lower to host `String` methods, no import needed: `s.length`, `s[i]`, `s.substring(start[, count])`, `s.trim()`, `s.replace(old, new)`, `s.indexOf(sub)` / `s.lastIndexOf(sub)` (return `Int`, `-1` if absent — distinct from the `Option[Int]`-returning `Std.String` free functions), `s.contains/startsWith/endsWith(sub)` (`Bool`), `s.toLower()` / `s.toUpper()`. String `==`/`!=` compare by value. See language reference §12.1.

### Service libraries (early-preview; separate packages, not in stdlib)

| Library | Package(s) | Purpose | Chapter |
|---|---|---|---|
| `lyric-logging` | `Std.Logging`, `Std.Logging.Aspects` | Named loggers, six levels, JSON/text output, aspect templates | 22 |
| `lyric-web` | `Web`, `Web.OpenApi`, `Web.Aspects` | HTTP server (code-first + spec-first), `ApiError`, aspect templates | 23 |
| `lyric-cache` | `Cache`, `Cache.Aspects` | In-memory/disk TTL cache, `CacheBucket` interface, `CachedResult`/`RateLimited` aspect templates. Eviction is FIFO by insertion order (oldest entry removed first when `maxEntries` is exceeded). | 24 |
| `lyric-db` | `Db`, `Db.Aspects` | Typed SQL over `System.Data`/JDBC, `DbConnection`, parameterised queries, transactions, aspect templates | 25 |
| `lyric-health` | `Health` | Liveness/readiness health-check endpoints; composite `HealthRegistry` | 26 |
| `lyric-jobs` | `Jobs` | Background job scheduling; Hangfire/Quartz.NET backends; `JobHandler`/`JobScheduler`; `Retryable`/`Timed` aspects | — |
| `lyric-mail` | `Mail`, `Mail.Aspects` | Email sending over SMTP/SES/SendGrid; `MailSender` interface; `EmailMessage`/`Attachment` types | — |
| `lyric-mq` | `Mq`, `Mq.Aspects` | Message queuing over RabbitMQ/ASB/SQS/Kafka; `Idempotent`/`DeadLetter` aspect templates | — |
| `lyric-otel` | `OTel`, `OTel.Otlp` | OpenTelemetry tracing, metrics, and OTLP export | 19 |
| `lyric-search` | `Search` | Elasticsearch/Meilisearch integration; `SearchClient`; typed result model | — |
| `lyric-session` | `Session` | Distributed session management; Redis-backed and in-process stores; UUID session IDs | — |
| `lyric-storage` | `Storage`, `Storage.Aspects` | Object storage (S3/Azure Blob/local); `StorageBucket`; `AuditAccess`/`ValidateKey` aspects. **Note:** `presignedUrl` requires `expiresInSeconds <= 604800` (7 days); larger values violate the contract at runtime. | — |
| `lyric-testing` | `Testing` | Mock implementations (`MockMailSender`, `MockStorageBucket`, `MockSessionStore`, `MockFlagStore`, …); `TestContext`; assertion helpers | — |
| `lyric-validation` | `Validation` | Composable input validators returning `[ValidationError]`; string/numeric combinators; `toResult` helper | — |
| `lyric-ws` | `Ws`, `Ws.Aspects` | WebSocket server (ASP.NET Core/.NET, Undertow/JVM); `WsHandler`/`WsRegistry`; `WsAuth`/`WsRateLimit` aspects. **Note:** `createRegistry()` returns `Err(WS_AUTH_MISCONFIGURED)` when `WsAuthConfig.enabled = true` and `WsAuthConfig.jwtSecret` is empty — set `LYRIC_CONFIG_WS_AUTH_JWTSECRET` or disable auth. | — |
| `lyric-feature-flags` | `Flags`, `Flags.Aspects` | Runtime feature toggles; in-process/remote stores; `FlagGated` aspect. **Note:** `connectRemote()` returns `Err(INSECURE_URL)` when an API key is configured and `Remote.url` is not `https://` — use a TLS endpoint to prevent credential leakage. | — |
| `lyric-i18n` | `I18n` | BCP 47 locale parsing; `TranslationStore`; `{placeholder}` substitution; JSON/file-backed loading | — |
| `lyric-proto` | `Proto` | Pure-Lyric Protocol Buffer (proto3) wire-format encoder/decoder | — |
| `lyric-grpc` | `Grpc` | General-purpose gRPC client; raw `slice[Byte]` payloads; compose with lyric-proto | — |
| `lyric-resilience` | `Resilience` | `Retry` and `CircuitBreaker` aspect templates; `backoffDelay` helper. **Note:** `Retry` config now includes `maxDelayMs` (default 30000 ms) and `jitterFraction` (default 0.1), which add jitter to retry delays by default — existing code using `Retry` will see jittered backoff. | — |

---

## B.10 CLI commands

```sh
# Scaffold a new project
lyric init demo                        # app package in ./demo (lyric.toml + src/main.l + .gitignore)
lyric init                             # scaffold in the current directory
lyric init mylib --lib                 # library skeleton (src/lib.l)
lyric init demo --name Demo --force    # override the package name; overwrite an existing lyric.toml

# Project-aware defaults
lyric                                  # build the current project (discovers nearest lyric.toml)
lyric version                          # print package name and version from nearest lyric.toml and exit 0
lyric --help                           # grouped command list (also -h / help); exits 0
                                       # build / restore / run / fmt / lint / prove / doc / test /
                                       # bench all discover the nearest lyric.toml by walking up
                                       # from the cwd when no source file is given; each also
                                       # accepts --manifest <lyric.toml> to override discovery

# Build
lyric build <file.l>                   # compile to .dll + .runtimeconfig.json
                                       # prints elapsed time on success: "built foo.dll in 342ms"
                                       # project mode: "built foo.dll (3 package(s), 1204ms)"
lyric build --force <file.l>           # rebuild unconditionally (bypass incremental check)
lyric build --release <file.l>         # single-file: self-contained Native AOT binary (no runtime needed)
lyric build --release                  # project-mode: entry package auto-detected (func main())
lyric build --release --manifest lyric.toml  # explicit project manifest
lyric build --release <file.l> --rid <rid>   # override host runtime identifier
lyric build --release <file.l> -o <bin>      # native binary output path
                                       # (.NET target only; JVM GraalVM native-image: #1975)
lyric build --release-from-dll <dll>   # link a pre-built managed DLL to a native binary via
                                       # ILC + clang, skipping source compilation entirely.
                                       # defaults to <dll-stem> next to the DLL; use -o to override.
lyric build --release-from-dll <dll> --extra-refs-dir <dir>
                                       # add every *.dll in <dir> (except the primary DLL)
                                       # as ILC managed references — used by bootstrap.sh for
                                       # stage-2 builds.
lyric build --target dotnet <file.l>   # target .NET (default): writes foo.dll + foo.runtimeconfig.json
lyric build --target jvm <file.l>      # writes a runnable foo.jar (NO runtimeconfig.json) via the
                                       # self-hosted JVM emitter (`Main-Class` derived from the source
                                       # `package` declaration; runs under `java -jar foo.jar`)
lyric build --target native <file.l>   # writes a self-contained POSIX executable (no extension)
                                       # via the LLVM backend + clang; --triple cross-compiles,
                                       # --opt 0|1|2|3|s sets the clang -O level (default 2).
                                       # triple/opt default from the manifest [native] table
                                       # (CLI flags override); [native].extra_libs adds -l<name>.
                                       # ARC-managed (no GC; cycles need NativeWeak[T]). Surface:
                                       # scalars/strings, records, unions, enums, distinct types,
                                       # tuples, match, generics (monomorphized), closures,
                                       # non-generic interfaces (impl I for Record, vtable
                                       # dispatch), NativeWeak[T], slice[T], List/Map +
                                       # for/indexing (map keys String or scalar); raw FFI
                                       # (NativePtr[T], nativeAddrOf, nativeNullPtr,
                                       # closure-as-C-callback trampolines) only in @unsafe_ffi
                                       # functions / _kernel_native packages (N0100).
                                       # Not yet lowered (build fails naming the construct):
                                       # interface default/generic methods, protected types,
                                       # list literals, module-level val, async, manifest builds
lyric build -o <dir> <file.l>          # write output files to <dir>
lyric build --manifest lyric.toml      # build from project manifest
                                       # (with [project] output = "single", bundles every
                                       # [project.packages] entry into one DLL with one
                                       # Lyric.Contract.<Pkg> resource per package)
                                       # auto-restores [dependencies] when lyric.lock is missing/stale
                                       # ([nuget]/[maven] edits aren't detected — run `lyric restore`)
lyric build --no-restore               # build against the lock as-is (skip auto-restore)
lyric build --package-version <ver>   # override the version string embedded in Lyric.Contract.*
                                       # metadata resources (instead of the version in lyric.toml);
                                       # used by publish pipelines to stamp the git release version

# Build kind (manifest [build] kind, .NET target; default "lib")
#   kind = "lib"     -> managed foo.dll + foo.runtimeconfig.json (run via `dotnet exec`)
#   kind = "exe"     -> the above PLUS a native apphost launcher `foo` (`foo.exe` on
#                       Windows); run directly with `./foo` (still needs .NET installed).
#                       `lyric run` execs the launcher instead of `dotnet exec`; if the
#                       launcher is missing it warns and falls back to `dotnet exec`.
#   kind = "bundle"  -> self-contained (runtime bundled) — planned, build errors for now
#   kind = "aot"     -> native AOT, no runtime — Linux (`x64`/`arm64`) and macOS; clang/ld64 required;
#                       equivalent to `lyric build --release`; Windows tracked in #1975

# Build features (compile-time gating; see chapter 20 §20.7)
lyric build --features X,Y <file.l>    # additive over manifest's [features] default
lyric build --no-default-features      # suppress the default = […] set
lyric build --all-features             # transitive closure of every declared feature
                                       # (all of the above flags also work on
                                       #  lyric run / test / prove / publish)

# Run
lyric run <file.l>                     # compile and immediately execute
lyric run <file.l> -- arg1 arg2        # pass arguments to the program
lyric run <file.l> --watch             # rebuild & re-run on source changes (Ctrl-C to stop)
lyric run                              # project mode: build + run the project's main entry point
lyric run -- arg1 arg2                 # project mode: pass arguments to the program
lyric run --watch                      # project mode: rebuild & re-run on source changes
lyric run --target jvm                 # build JVM target and run with java -jar
lyric run --target native              # build the LLVM native target and run the binary directly
                                       #   (single-file or project; entry main() output is correct.
                                       #    Note: forwarding `-- args` to a slice[String] main and
                                       #    propagating the Int return as the JVM exit code are pending
                                       #    JVM codegen work — see issue #3303.)
lyric build --watch                    # project/single build: rebuild on source changes

# Test
lyric test <file.l>                    # run test blocks in a @test_module file
                                       # (TAP-shaped output; exit 1 on any failure)
lyric test <file.l> --filter <substr>  # only run tests whose title contains <substr>
lyric test <file.l> --list             # print test titles only; do not compile or run
lyric test <file.l> --fail-fast        # stop after the first file with failing tests;
                                       # print an early summary and exit 1
lyric test <file.l> --target jvm       # compile with JVM backend and run with java -jar
lyric test                             # project mode: run every [project.tests] entry;
                                       # falls back to scanning [project.packages] for
                                       # @test_module files when [project.tests] is empty
lyric test --fail-fast                 # project mode: stop after first failing test entry
lyric test --manifest <lyric.toml>     # project mode: override manifest discovery
                                       # (v2: --doctests, --update-snapshots, property execution)
lyric test --features a,b              # project mode: activate manifest [features]
                                       # (same grammar/precedence as lyric build)
lyric test --no-default-features       # suppress the manifest's default feature set
lyric test --all-features              # activate every declared feature
                                       # e.g. run a suite against the jvm-gated kernel:
                                       #   lyric test --manifest m.toml --target jvm \
                                       #     --no-default-features --features jvm

# Format
lyric fmt <file.l>                     # print formatted source to stdout (no configuration)
lyric fmt <file1.l> <file2.l> ...      # format multiple files (multi-file variadic)
lyric fmt --write <file.l>             # overwrite file in place
lyric fmt --check <file.l>             # exit 1 if not formatted; prints filename (CI gate)
lyric fmt --diff <file.l>              # print unified diff of what would change; exit 1 if any diff (CI gate)
lyric fmt --stdin                      # read from stdin, write formatted output to stdout
                                       # (editor integration: pipe source through fmt)
lyric fmt                              # project mode (dry-run): list files that would change
lyric fmt --write                      # project mode: rewrite all files in place
lyric fmt --check                      # project mode: exit 1 if any unformatted; prints paths (CI gate)
lyric fmt --diff                       # project mode: print unified diffs; exit 1 if any file would change
lyric fmt --diff --write               # show diff then apply changes in place
# Default: walks the red/green CST and preserves all comments
# (//, /* */, ///, //!) plus intentional blank lines (max one per spot).

# Lint
lyric lint <file.l>                    # report style/quality diagnostics (AST-only; fast)
lyric lint --error-on-warning <file.l> # treat warnings as errors (CI gate)
lyric lint                             # project mode: lint every [project.packages] source file;
                                       # prints summary: "N error(s), M warning(s) in K file(s)"
                                       # or "K file(s) clean"
lyric lint --manifest <lyric.toml>     # project mode: override manifest discovery
# Codes: L001 PascalCase types, L002 camelCase funcs, L003 missing pub doc,
#        L004 TODO/FIXME in doc, L005 pub func without contracts
# Exit codes: 0 = clean, 1 = errors (or warnings with --error-on-warning)

# Documentation
lyric doc <file.l>                     # generate Markdown docs from doc comments + contracts
lyric doc                              # project mode: generate docs/ for all project source files
lyric doc --manifest <lyric.toml>      # project mode: override manifest discovery
lyric doc -o <dir>                     # write docs to <dir> (default: docs/ beside manifest)

# Verification
lyric prove <file.l>                   # run SMT verifier on @proof_required modules
lyric prove --allow-unverified <file.l> # downgrade V0007 (unknown) from error to warning
lyric prove --explain --goal N <file.l> # show the VC IR for goal N
lyric prove --json <file.l>            # machine-readable output
lyric prove --proof-dir <dir> <file.l> # write SMT files to <dir> (default: target/proofs/)
lyric prove --verbose <file.l>         # print each goal's SMT query and solver response
lyric prove                            # project mode: prove every [project.packages] source file
lyric prove --manifest <lyric.toml>    # project mode: override manifest discovery
                                       # (--json and --explain --goal N require explicit source file)

# Benchmarking  (see chapter 28)
lyric bench <file.l>                   # compile and run @bench_module timing harness
lyric bench <file.l> --target jvm      # benchmark on JVM target (java -jar); see note below
lyric bench <file.l> --runs <N>        # number of timed iterations (default: 10)
lyric bench <file.l> --warmup <N>      # un-timed warmup iterations (default: 3)
lyric bench <file.l> --filter <substr> # only run benchmarks whose name contains <substr>
lyric bench                            # project mode: run all @bench_module files in project
lyric bench --target jvm               # project mode: JVM target; see note below
lyric bench --manifest <lyric.toml>    # project mode: override manifest discovery
# Output: "name  min=Xms  max=Xms  mean=Xms" per @bench function
# Requirements: file must carry @bench_module; @bench functions must be pub func f(): Unit
# Note: --target jvm is wired but currently blocked on JVM Std.Time support
#       (the timing harness uses now()/since()/totalMillis()); see issue #3302.
#       --target dotnet is fully supported.

# Code generation
lyric openapi <spec.json>              # generate a typed Std.Rest client from an OpenAPI 3.x JSON spec
lyric openapi <spec.json> -o <out.l>  # write generated source to a specific path
lyric openapi <spec.json> --client-name <Name>   # override the generated client type name
lyric openapi <spec.json> --package <Pkg.Name>   # override the generated package declaration

# Type checking (without output artifact)
lyric check <file.l>                   # type-check without producing a usable bin/ artifact
lyric check <file1.l> <file2.l> ...    # type-check multiple files
lyric check --target jvm <file.l>      # type-check against the JVM target
lyric check                            # project mode: type-check all [project.packages]
lyric check --manifest <lyric.toml>    # project mode: override manifest discovery
# Output is written to .lyric-check/; exit 0 = clean, 1 = type errors

# Clean (remove build artifacts)
lyric clean                            # remove bin/, .lyric-run/, .lyric-test/, .lyric-bench/,
                                       # .lyric-check/, .lyric-release/ from the project root
lyric clean --manifest <lyric.toml>    # clean the project at the given manifest's directory
lyric clean <dir>                      # clean a specific directory

# Package management
lyric restore                          # download all dependencies declared in lyric.toml
lyric restore --locked                 # restore strictly from lyric.lock (fail if lock is stale)
lyric update                           # re-resolve all deps to latest compatible versions
                                       # and rewrite lyric.lock (deletes the old lock first)
lyric upgrade                           # self-upgrade the lyric CLI tool (auto-detects channel)
lyric upgrade --nuget                   # force self-upgrade via NuGet global tool update
lyric upgrade --github                  # force self-upgrade via raw GitHub Releases installer script
lyric upgrade --version 0.4.6           # upgrade to a specific semver version
lyric upgrade --dir ./bin               # specify target installation directory (GitHub Releases only)
lyric upgrade --dry-run                 # dry-run and print planned execution commands
lyric deps                             # print the resolved dependency tree from lyric.lock

lyric add Foo@1.2.0                    # add/update a [dependencies] registry entry, then restore
lyric add Lib --path ../lib            # add a path dependency
lyric add Bar --git <url> --tag v1     # add a git dependency (or --rev/--branch)
lyric add Pkg@1.0 --nuget              # add to the [nuget] table instead
lyric add Foo@1.2.0 --no-restore       # edit the manifest without restoring
lyric remove Foo                       # remove a [dependencies] entry, then restore
lyric remove Pkg --nuget               # remove a [nuget] entry instead
lyric remove Foo --no-restore          # remove from manifest without restoring
lyric publish                          # publish package to the configured registry
lyric publish --registry <url>         # publish to a specific registry feed URL
lyric publish --api-key <key>          # supply an API key (NuGet push token / GitHub PAT)
lyric publish --skip-duplicate         # silently succeed if this version already exists on the registry
lyric publish --package-version <ver>  # override the NuGet <Version>, .nupkg filename, and
                                       # cross-library <PackageReference> versions; also stamps
                                       # Lyric.Contract.* metadata resources embedded in the DLL;
                                       # used by publish pipelines to stamp the git release version
lyric search <query>                   # search the registry for matching packages

# Interactive REPL
lyric repl                             # start interactive read-eval-print loop
lyric repl --verbose                   # REPL with diagnostic output on each evaluation

# Tooling
lyric --sdk-info                       # print SDK root, stdlib DLL path, and version information
lyric public-api-diff <old.dll> <new.dll>  # diff pub surfaces; exits 0 (compatible) or 2 (breaking)
```

### CLI environment variables

| Variable | Default | Effect |
|---|---|---|
| `LYRIC_BIN` | `lyric` | Path to the `lyric` (or `dotnet`) executable used by the self-hosted CLI when it needs to shell back to itself (e.g. for `emitProject` multi-package builds, `--target jvm`, or `LYRIC_FORCE_SUBPROCESS=1`).  Set automatically by the F# `Program.fs` when it is the entry point; when running the AOT trampoline binary (`bootstrap/src/Lyric.Cli.Aot/`), the caller must export this themselves — the AOT entry point is a pure trampoline (#1082) and does NOT auto-discover the F# bootstrap binary. |
| `LYRIC_CLI_DLL` | unset | When the CLI is running as a `dotnet exec <dll>` invocation rather than an AppHost-native binary, the DLL path.  `Program.fs` populates from `Assembly.GetEntryAssembly`; the AOT trampoline does NOT (#1082).  Required (and must be exported by the caller) when invoking the AOT binary for any command that hits the subprocess fallback. |
| `LYRIC_FORCE_SUBPROCESS` | `0` | When set to `1`, every `lyric build` runs through the subprocess shellout to `lyric --internal-build` even for `--target dotnet`.  Default is the in-process MSIL emit path that lands `Msil.Bridge.compileToMsil` directly without spawning a subprocess.  Used by the bootstrap reproducibility pipeline to compare in-process vs subprocess output during the Track A migration (`docs/41 §860`). |
| `LYRIC_STD_PATH` | unset | Override the stdlib source root (`lyric-stdlib/std/`) used by the F# emitter's package-import resolver.  Mainly useful when running stage-1 / stage-2 bootstrap builds out of a non-standard layout. |
| `LYRIC_STDLIB_BIN` | unset | Override which **compiled** stdlib assemblies a build links against (the `Lyric.Stdlib.*.dll` runtime DLLs co-located beside the output by `lyric build`/`run`/`test`).  When set it takes precedence over all auto-discovery (app-base dir, `lib/`, walked-up `.bootstrap/stage1`).  Accepts either a **directory** containing the split per-package DLLs, or a path to a **specific `.dll`** (its containing directory is used) — so you can build several stdlib variants and link a chosen one explicitly.  Unlike auto-discovery, it does not require the bundled `Lyric.Stdlib.dll` to be present (a per-package self-build emits only the split assemblies). |

---

## B.11 Error codes

### Lexer (L0xxx-series)

Errors and warnings emitted during lexical analysis of source files.

| Code | Severity | Meaning |
|---|---|---|
| `L0015` | error | Unrecognised numeric suffix (e.g. `100xyz`); use a valid type suffix (`u8`, `i32`, `f32`, etc.) or remove the suffix |
| `L0016` | error | Based literal has no valid digit body (e.g. bare `0x`, `0b___` with only underscores) |

### Linter (L-series)

Style and quality rules checked by `lyric lint`.  These are single-digit codes (no leading zeros) distinct from the four-digit lexer codes above.

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
| `T0014` | Unknown qualified type name (last segment not in scope) |
| `T0015` | Integer literal out of range for an inline range-refined type |
| `T0016` | Non-exhaustive `match` (uncovered union/enum case, `Bool`, or scalar without `_`) |
| `T0017` | Type alias is part of a cycle and does not resolve to a type |
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
| `T0067` | `if`/`match` guard or condition type error; value-position `try` handler type incompatible with the `try` body |
| `T0070` | Function body type does not match declared return type |
| `T0080` | `old(…)` used outside an `ensures` clause |
| `T0085` | `out`/`inout` argument (value-type) must be a mutable l-value |
| `T0086` | `out` parameter is never assigned before the function returns |
| `T0087` | Reassigning an immutable binding (`val`/`let` or an `in` parameter) |
| `T0090` | Range bounds are inverted or produce an empty range |
| `T0091` | `range` applied to a non-numeric underlying type |
| `T0093` | Range bound expression cannot be evaluated at compile time |
| `T0097` | Package-private symbol referenced from another package (mark it `pub` or `internal`) |
| `T0098` | `impl` is missing an abstract interface method |
| `T0099` | `impl` method parameter arity does not match the interface declaration |
| `T0100` | Opaque type constructed outside its declaring package |
| `T0101` | Constructor names a field the type does not have |
| `T0102` | Pattern-matching an opaque type's representation outside its declaring package |
| `T0109` | Value expression used where a type argument is required |
| `T0110` | Generic constructor's type parameter(s) cannot be inferred from the arguments (add explicit type arguments) |
| `T0111` | Unknown constraint name in a `where` clause (warning) |
| `T0112` | Refutable pattern in a `for` loop binding (only names, `_`, parentheses, and tuples of those) |

### Type checker warnings (W-series)

| Code | Severity | Meaning |
|---|---|---|
| `W0006` | warning | A `pub` function exposes an **imported nested** host extern type (a CLR FQN containing `+`, e.g. `System.Text.Json.JsonElement+ArrayEnumerator`) in its signature. Nested types are host implementation details meant to stay behind the `_kernel/` FFI boundary. A kernel file that declares the extern type locally is exempt. Fix: wrap the host type in an opaque Lyric type (as `Std.Json` does with `JsonArrayCursor` / `JsonObjectCursor`) instead of exposing it directly. Top-level domain extern types are not flagged. |

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

### Emitter warnings (A-series)

Warnings emitted by the MSIL emitter for constructs that compile but may not behave as expected.

| Code | Severity | Meaning |
|---|---|---|
| `A0001` | warning | `async func` declares an `out` or `inout` parameter; the async state machine stores a value copy, not the byref — the caller's variable is not updated. Return a `Result` or record instead. |

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
| `V0010` | error | Conflicting verification-level annotations on the same package |
| `V0011` | error | Unknown verification-level modifier |
| `V0012` | error | (mode checker) `await` inside a `try`/`catch`/`finally` block in an async function — a CLR IL constraint (not the verifier-side async rejection, which is `V0032`) |
| `V0013` | warning | Proof goal contains NaN or ±Infinity float literal; substituted with `0.0` in SMT-LIB output — verification result may be incorrect |
| `V0032` | error | Contract clause (`requires:`/`ensures:`) on an `async func` or `yield`-bearing generator — the WP/SP calculus cannot model suspend/resume, so the verifier rejects the function rather than checking it against an unmodelled body. Move the contract to a synchronous core, or mark the package `@runtime_checked` |

### Bench (B-series)

| Code | Meaning |
|---|---|
| `B0900` | File passed to `lyric bench` is missing the `@bench_module` annotation |
| `B0901` | `@bench_module` package declares a `func main()` — not allowed |
| `B0902` | No `@bench`-annotated functions found (or `--filter` matched none) |
