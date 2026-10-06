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
18446744073709551615u64  // a u64 literal spans the full unsigned range
-2147483648i32           // a signed suffix spans its range; the minimum is a unary minus
200u8                    // u8 is the Byte suffix; i8/i16/i32 are Int, i64 is Long
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
| `Float` | 32-bit IEEE 754 | an unsuffixed literal is a `Float` where one is required |
| `Double` | 64-bit IEEE 754 | |
| `Char` | BMP scalar (one UTF-16 code unit) | U+0000..U+FFFF excl. surrogates U+D800..U+DFFF |
| `String` | immutable UTF-8 | unbounded |
| `Unit` | unit type | single value `()` |
| `Never` | bottom type | uninhabited; assignable to any type |

Integer overflow (`+ - *` on `Byte`/`Int`/`Long`/`UInt`/`ULong`, unary `-` on `Int`/`Long`) panics in debug builds and wraps in release builds (D163); `.wrappingAdd/Sub/Mul(y)` and `.wrappingNeg()` wrap in every build. Range-subtypes always panic on an out-of-range result.

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
  var count: Int           // mutable field (a write to a non-`var` field via a `var` local or `self` is V0015)
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
var fixed:   array[16, Byte]     // fixed-size, a value, zero filled; length is part of the type
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

`Ord` synthesises `compare(self, other): Int` (negative/zero/positive); valid on records, unions, enums, and distinct types. The same nine names are the closed set usable as `where`-clause constraints (docs/03 D034, narrowed by D-progress-807 — a speced `Copyable` marker was never implemented and is not part of the usable set).

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
A protected type may be generic (`BoundedQueue[T]`): construction infers the type arguments like a record's (`Cell(value = 1)` is a `Cell[Int]`). Supported on `--target dotnet`, `--target jvm` and `--target native`.

### Config blocks (runtime env-var-backed config)

```lyric
// Declared at module scope; package-private; not a type.
config Server {
  host:    String                   = "0.0.0.0"
  port:    Int range 1 ..= 65535   = 8080       // out-of-range env value exits 78 (G0004)
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

```lyric
// Config template (docs/58, D121): a library-declared schema + record twin.
pub config StaticFiles {
  root:         String = "./public"
  cacheSeconds: Int    = 3600
}

// Instantiation: an ordinary env-backed block under the LOCAL name.
config Assets from Web.StaticFiles {
  root: String = "./wwwroot"       // override; other fields keep template defaults
}
```

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
// Call: ProductionApp.bootstrap(cfg, token); ProductionApp.transferService()
```

```lyric
// Wire template + include + contributes[T] (docs/58, D121)
pub wire ServerModule {                       // template: never bootstrapped itself
  @provided config: AppConfig
  contributes[Middleware] cors    = Web.corsMiddleware()
  contributes[Middleware] logging = Web.loggingMiddleware()
  singleton router: Web.Router = Web.create(middlewares: Middleware)
  expose router
  overridable cors                            // consumer may replace / remove cors
}

wire ProductionApp {
  @provided config: AppConfig
  include Web.ServerModule {                  // splice; `as Alias` isolates an instance
    cors = MyApp.customCors()                 // replace (gated by overridable)
  }
  contributes[Middleware] auth = MyApp.jwtMiddleware(config.jwtSecret)
    inside: logging                           // ordering: same wraps:/inside: vocabulary
    wraps:  cors                              //   as aspects; outermost-first list order
  expose router
}
// The bare collection name (Middleware) resolves as an ordered List[Middleware].
// Include-body adjustments: `@provided name: value`, `name = expr`,
// `Name { field = value }` (config-instance override), `remove name`,
// `reorder name wraps:/inside: other`.  `sealed contributes[T]` closes a
// collection against external add/remove/reorder.
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

Bitwise ops are methods: `.and()` `.or()` `.xor()` `.shl()` `.shr()`. `&` is not one of them — it's a prefix-only operator (reserved for a not-yet-implemented function-reference form) and any use of it, including the plausible-looking `x & y`, is a compile error (`T0141`). No `?:` ternary; use `if … then … else …`.

Numeric / character conversions are explicit methods, except lossless widening: `.toByte()` `.toInt()` `.toLong()` `.toChar()` `.toFloat()` `.toDouble()` on `Byte`/`Int`/`Long`/`Float`/`Double`/`Char`; `.toFloat()` rounds to the nearest 32-bit `Float`. Widening is lossless; narrowing truncates toward zero; `.toByte()` reduces modulo 256 (`Byte` is unsigned 0..255); `.toChar()` is checked — it fails unless the value is a BMP scalar (0..65535, not a surrogate 55296..57343), and `Std.Char.tryFromInt` is the non-panicking form. `.toNat()` (`--target dotnet`) is the other checked conversion — available on `Byte`/`Int`/`Long`/`Char`/`Double` receivers, it fails with `toNat: value must be non-negative` on a negative value or NaN. Mix widths via `acc + b.toInt()`, never `acc + b`. For a checked narrowing, `Std.Math.longToInt(n)` (bare or qualified) fails its `requires:` precondition when `n` is outside `Int`; `n.toInt()` wraps instead. Lossless widening along `Byte < Int < Long`, `Byte < UInt < ULong` and `Float < Double` is implicit wherever a value initialises, is assigned, passed or returned, or is a list/slice literal element, a tuple element or a constructor argument of a generic instance where the expected type fixes its slot (`val a: Option[ULong] = Some(u)`, `val b: (ULong, Int) = (u, 1)`; an existing `Option[UInt]` value is never converted, `T0060`); the unsigned chain zero-extends, and `.toUInt()` on a `Byte`/`UInt` receiver and `.toULong()` on a `Byte`/`UInt`/`ULong` receiver spell it out. (Conversions between the signed and unsigned chains are not yet implemented, and apart from `.toUInt()`/`.toULong()` none of `UInt`/`ULong`/`Nat` support conversion methods as a *receiver* — both targets compare, divide and stringify every `UInt`/`ULong` value unsigned, whatever its shape (a field, an element, a call result; #7812), so this is a remaining method-surface gap rather than a missing backend representation or unsigned-aware codegen. `.toX()` on `String`/`Bool`/`Unit` is a `T0103` error.)

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
| Literal | `42` `"hello"` `true` (an integer literal takes a `Byte`/`UInt`/`ULong` scrutinee's type) |
| Binding | `x` |
| Constructor | `Circle(r)` `Some(v)` `Ok(x)` |
| Record destructure | `Point { x, y }` `Point { x = 0.0, y }` |
| Tuple | `(a, b)` |
| Range | `0 ..= 9` (unsigned ordering on a `Byte`/`UInt`/`ULong` scrutinee) |
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
(a, b) -> a + b        // bare parenthesised lambda (call-argument position only, no braces)
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

import Money                                 // whole package: every name bare
import Money.{Amount, Cents}                 // only the listed names bare
import Std.Collections as Coll              // alias: names written Coll.x
pub use Money.Amount                         // re-export (facade pattern)

import extern System.Net.Http.{HttpClient}   // named imports from external (host) packages
pub use extern Docker.DotNet.{DockerClient}  // re-export external type
```

Wildcard imports (`import Foo.*`) are not permitted. A bare name must come from the current package, the `Option`/`Result` prelude, a whole import (or a package it imports), or a selective import's list; otherwise it is T0020 with an import hint. External type imports (those with `extern` keyword) require a selector group `{ ... }` and are scoped to the importing package.

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
"myapp.TestFixtures" = { path = "src/test_fixtures", test_only = true }
                                    # importable by [project.tests]/lyric test,
                                    # excluded from the production bundle (#6579)

# Enforced package layering (lang-ref §9.4, D149)
[layers]
preset = "ui"                        # optional; the only preset

[layers.packages]
"myapp.Core"      = "domain"
"myapp.*.Logic"   = "logic"          # * = one segment, final ** = one or more

[layers.rules]                       # custom layers or preset replacements
core = { may_import = ["core", "pure"], may_not_import = ["Acme.**"], async = false }
```

Layer diagnostics: Y0001 forbidden import, Y0002 unclassified import, Y0003
`@io` call, Y0004 `async func`, Y0005 `@layer` disagrees with the manifest,
Y0006 unknown layer/preset, Y0007 mutable module-level state, Y0008 protected
`entry` call, Y0009 malformed annotation or `[layers.packages]` entry.

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
| `@cfg(all(...))`, `@cfg(not(...))` | any item | Erase unless every operand holds / its operand does not; operands are `feature = "X"`, `target = "X"` or nested compositions |
| `@delete` / `@get` / `@patch` / `@post` / `@put` | handler function | HTTP method annotation (lyric-web code-first) |
| `@generate(Json\|Sql\|Proto)` | `exposed record`, `record`, `union`, `interface` | Invoke built-in source generator for the named target |
| `@generate(Pkg.Name)` | `exposed record`, `record`, `union`, `interface` | Invoke custom source generator from package `Pkg` |
| `@experimental` | `pub` item | May change without SemVer major bump |
| `@io` | package | The package performs I/O (layer class, lang-ref §9.4) |
| `@io` | function in a `@pure` package | The function performs I/O; packages that may not do I/O may not call it (Y0003) |
| `@layer("name")` | package | Places the package in a `[layers]` layer; must agree with the manifest (Y0005) |
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
| `@pure` | package | The package does no I/O and holds no shared mutable state (layer class, lang-ref §9.4) |
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
| `Std.Core.Proof` | Proof-required witness functions | `identity`, `pickFirst`, `pickSecond`, `trueLit`, `falseLit`, `tag`, `assertEq`, `wrappedIdentity` (all `@pure @stable(since="1.0")`) |
| `Std.String` | String manipulation | `trim`, `split`, `join`, `contains`, `startsWith`, `toUpper`, `substring`, `indexOfFrom`, `StringBuilder` (`new`/`append`/`appendChar`/`toString`) |
| `Std.Parse` | Numeric parsing | `tryParseInt`, `tryParseLong`, `tryParseDouble`, `tryParseBool` |
| `Std.Errors` | Standard error types | `ParseError`, `IOError`, `HttpError` |
| `Std.File` | File system | `readText`, `writeText`, `readBytes`, `writeBytes` (`slice[Byte]`), `fileExists`, `createDir` |
| `Std.Collections` | Generic growable containers | `List[T]` (`add(item)`, `add(index, item)` inserts, `[]`, `count`), `Map[K,V]` (`[]`, `containsKey`, `remove`) |
| `Std.Set` | Hash set | `Set[T]`, `setContains`, `setAdd`, `setRemove`, `setSize`, `setFromSlice`, `setUnion`, `setIntersection`, `setDifference` |
| `Std.Sort` | Stable sort | `sort[T](xs, cmp)`, `sortInts`, `sortLongs`, `sortStrings`, `isAscendingInts`, `isAscendingLongs`, `isAscendingStrings` |
| `Std.Math` | Numeric utilities | `absDouble`, `minPairDouble`, `maxPairDouble`, `sqrt`, `pow`, `floor`, `ceiling` |
| `Std.Random` | Pseudo-random values | `nextInt`, `nextDouble`, `nextBool` |
| `Std.SecureRandom` | Cryptographically-strong randomness | `secureNextInt`, `secureNextIntRange`, `secureGetBytes` |
| `Std.Hash` | Cryptographic hashing and MACs | `sha256OfBytes`, `sha256Digest`, `sha512OfBytes`, `sha512OfFile`, `hmacSha256`, `constantTimeEquals` |
| `Std.Char` | Unicode character utilities | `isLetter`, `isDigit`, `isWhiteSpace`, `isUpper`, `isLower`, `toUpper`, `toLower`, `toInt`, `fromInt` (BMP scalar values only), `tryFromInt`, `digitValue`, `hexDigitValue` |
| `Std.Format` | Number and string formatting | `toHexString`, `toHexStringUpper`, `formatFixed`, `zeroPad`, `hexPad`, `padLeft`, `padRight` |
| `Std.Encoding` | Byte-level encoding | `encodeBase64`, `tryDecodeBase64`, `encodeHex`, `tryDecodeHex`, `encodeUtf8`, `tryDecodeUtf8` |
| `Std.Ffi` | C memory and C strings for `@library` bindings (all `@unsafe_ffi`, D161) | `allocate`, `release`, `toCString`, `tryFromCString` |
| `Std.Bench` | Benchmark measurements | `allocatedBytes` (heap bytes the current thread has allocated) |
| `Std.Uuid` | UUID generation and parsing | `Uuid`, `newUuid`, `nilUuid`, `uuidToString`, `parseUuidOpt` |
| `Std.Stream` | I/O stream interfaces | `ByteReader`, `ByteWriter`, `TextReader`, `TextWriter`, `Closable` |
| `Std.Time` | Instants and durations | `Instant`, `Duration`, `now`, `toIsoString`, ISO-8601 parsing, `tryFromEpochMillis`/`tryFromEpochSeconds` |
| `Std.Json` | RFC 8259 JSON | `JsonDoc`, `JsonElement`, `parseJson`, `tryParseJson`, `tryGetProperty`, `getString`, `getInt32` (the `get*` getters require `isJson*`; use `tryGet*` for untrusted data) |
| `Std.JsonValue` | Strict RFC 8259 JSON value model, dotnet and JVM (native: #7856) | `JsonValue` (`JNull`, `JBool`, `JInt`, `JFloat`, `JString`, `JArray`, `JObject`), `JsonField`, `parseValue`, `parseValueWithDepthLimit`, `writeValue`, `writeValueIndented`, `getField`, `getString`, `getInt`, `asArray`, `JsonParseError` |
| `Std.Http` | HTTP client/server primitives | `get`, `post`, `HttpRequest`, `HttpResponse`, `statusCode`, `HttpClientBuilder`, `withHttpVersion`, `HttpVersion`, `negotiatedVersion`, `withCaCertificate`, `withExclusiveCaCertificate`, `withClientIdentity`, `withMinTlsVersion`, `withInsecureSkipVerify`, `tlsConfigSupported`, `resolveInsecureVerifyPolicy` |
| `Std.Tls` | PEM certificate/private-key loading | `Certificate`, `Identity`, `TlsVersion`, `TlsServerConfig`, `Certificate.fromPemFile`/`fromPem`, `Identity.fromPemFiles`/`fromPem` |
| `Std.HttpServer` | Low-level HTTP(S) server (`lyric-web` builds on this); on `--target dotnet` a pure-Lyric sans-IO engine over `System.Net.Sockets`/`SslStream` (the `HttpListener` server was retired, docs/61 §6). Over TLS it advertises `h2` then `http/1.1` via ALPN and serves **HTTP/2** end-to-end through `Std.HttpEngine.H2Conn` when the client offers it, falling back to HTTP/1.1 otherwise — same handlers, no code change (docs/61 §6.4). On `--target native` (N9.3, #6104) the same sans-IO engine runs thread-per-connection over real `pthread_create`d OS threads (native `spawn`/`scope` is not yet real concurrency); HTTP/1.1 only — a negotiated-`h2` TLS connection is closed rather than mis-parsed (N9.5 tracks native h2) — with no `startListener{,Tls}WithLimits`/backpressure cap yet | `startListener`, `startListenerTls` (real TLS + h2 on `--target dotnet`, real TLS on `--target jvm`, real TLS (no h2) on `--target native`; dotnet/native return `InvalidConfig` for a `requireClientCert`-without-`clientCa` mTLS misconfig, docs/61 §6.3), `startListenerWithLimits`/`startListenerTlsWithLimits` (dotnet only — raise the engine's request-size caps, e.g. the default 10 MiB body limit; the JVM server applies the same fixed 10 MiB cap, answering `413`), `nextContext`, `respondText`/`respondJson`/`respondBytesWithHeaders`, `takeConnection` (dotnet and native only: hand an HTTP/1.1 connection to another protocol after an `Upgrade` request, as `Web.addWebSocket` does; the JDK server exposes no raw connection, so on `--target jvm` a WebSocket upgrade goes through Undertow in `lyric-ws` instead), `beginChunkedResponse`/`streamWriteChunk`/`endChunkedResponse` (every target); dotnet/native handshake off the accept loop with `LYRIC_HTTPS_HANDSHAKE_TIMEOUT_MS` / `LYRIC_HTTP_IDLE_TIMEOUT_MS` timeouts (`resolveTlsHandshakeTimeoutMs`/`resolveConnectionIdleTimeoutMs`) |
| `Std.HttpEngine` | Sans-IO HTTP/1.1 parser, serializer, connection FSM | `EngineLimits` (incl. `maxBodyBytes`), `Connection`, `HttpEvent`, `feed`, `newConnection`, `shouldClose`, `serializeResponseHead`, `serializeChunk` |
| `Std.HttpEngine.Hpack` | Pure-Lyric HPACK (RFC 7541) header codec for HTTP/2 | `HpackEncoder`, `HpackDecoder`, `newEncoder`, `newDecoder`, `encodeHeaderList`, `decodeHeaderBlock`, `decodeHeaderBlockLimited` (bounds the decoded list; `HeaderListTooLarge`), `encoderSetMaxTableSize`, `DynamicTable`, `HpackError` |
| `Std.HttpEngine.H2Frame` | Pure-Lyric HTTP/2 (RFC 9113) frame codec + sans-IO frame decoder | `parseFrame`, `serializeFrame`, `parseFrameHeader`, `serializeFrameHeader`, `FrameDecoder`, `feedFrames`, `connectionPreface`, `isConnectionPreface`, `FrameError`, `H2ErrorCode`, `SettingsId` |
| `Std.HttpEngine.H2Conn` | Pure-Lyric sans-IO HTTP/2 (RFC 9113) server connection/stream state machine + flow control | `newServerConnection`, `serverInitialFrame`, `feed`, `H2Connection`, `H2Event`, `H2Settings`, `H2StreamState`, `streamState`, `sendData`, `encodeResponseHeaders`, `grantConnectionWindow`, `grantStreamWindow`, `sendGoAway`, `isFailed` |
| `Std.Testing` | Test assertions | `assertTrue`, `assertEqual`, `assertEqualInt`, `assertPanics`, `assertPanicsWith` |
| `Std.Testing.Snapshot` | Snapshot testing | `snapshot(label, actual)`, `snapshotMatch(label, actual)` |
| `Std.Testing.Property` | Property-based testing | `forAllInt`, `forAllBool`, `forAllDouble`, `forAllIntPair` |
| `Std.Testing.Mocking` | Stub call-count tracking | `StubCounter`, `makeStubCounter`, `stubCounterGet`, `stubCounterIncrement`, `stubCounterReset` |
| `Std.Iter` | Lazy iteration | `map`, `filter`, `fold`, `take`, `drop`, `find` |
| `Std.App` | Application entry and config | `run(main: func Unit): Int`, `withConfig`, `Config` (opaque), `Config.path`, `Config.rawText` |
| `Std.Console` | Console I/O | `print`, `println`, `error`, `readLine`, `readAll`, `openStdinReader`, `readStdin`, `readStdinWithin`, `writeStdoutBytes` |
| `Std.Directory` | Directory operations | `exists`, `create`, `createRecursive`, `enumerate`, `enumerateFiles`, `enumerateDirectories`, `delete`, `deleteRecursive` |
| `Std.Environment` | Process environment | `getVar`, `getVarOrDefault`, `args`, `exitCode`, `isWindows` |
| `Std.Log` | Structured logging | `LogLevel` enum, `Logger` interface, `LogField`, `log`, `debug`, `info`, `warn`, `error`, `field` |
| `Std.Path` | Pure path manipulation | `join`, `extension`, `basename`, `dirname`, `isAbsolute`, `isRelative` |
| `Std.BuildInfo` | Build metadata (docs/60) | `BuildInfo` record; the compiler synthesizes `buildInfo(): BuildInfo` into any file that imports it |
| `Std.Task` | Async task primitives, cancellation tokens, structured concurrency (`Scope`) | `Task`, `CancellationToken`, `makeCancelSource`, `delay`, `delayWithCancel`, `makeScope`, `scopeSpawn` (starts the closure at once: thread pool on dotnet, virtual thread on the JVM), `awaitAll` (joins what the scope started), `scopePendingCount` (children still tracked: a scope drops finished children when it next spawns), `runWithin[T](timeoutMs, f): Option[T]` — run an arbitrary `() -> T` closure with a real preemptive bound on both `--target dotnet` (`Task.Wait`) and `--target jvm` (`Thread.join`), `None` on timeout, panics from `f` propagate |

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
| `Web` *(lyric-web)* | HTTP routing, static files, middleware, background workers, ApiError, server entry point | `Router`, `Request`, `Response`, `Handler`, `Middleware`, `Worker`, `ApiError`, `StaticFiles`, `create`, `addGet`, `addPost`, `addWorker`, `withStaticFiles`, `withMiddleware`, `withSpec`, `addWebSocket` (serve a `Ws.createEndpoint` socket on the router's port), `dispatch`, `start` |
| `Web.OpenApi` *(lyric-web)* | OpenAPI 3.1 type vocabulary, builder, and JSON serializer | `Spec`, `Schema`, `Operation`, `PathItem`, `newSpec`, `addPath`, `specToJson` |
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
| `Ws` *(lyric-ws)* | WebSocket server | `WsHandler`, `WsRegistry`, `WsMessage`, `startServer`, `createEndpoint` (listener-less, for `Web.addWebSocket`), `send`, `broadcast` |
| `Flags` *(lyric-feature-flags)* | Runtime feature toggles | `FlagStore`, `isEnabled`, `getBool`, `getString`, `getInt`, `Registry.checkFlag` |
| `I18n` *(lyric-i18n)* | Internationalisation | `TranslationStore`, `Locale`, `translate`, `translateWith`, `makeLocale` |
| `Testing` *(lyric-testing)* | Test mocks and assertions | `TestContext`, `assertOk`, `assertErr`, `assertEq`, `MockMailSender` |

Codegen builtins (no import needed): `println`, `panic`, `expect`, `assert`, `toString(x)`, `format1`/`format2`/`format3`/`format4` (`{n}` placeholders, `{{`/`}}` literal braces, the same result on every target), `default()`. `println(x)` prints exactly what `toString(x)` returns (any type on dotnet and JVM; a `String` or scalar on native). `toString` of a `Double`, and on dotnet of an extern formattable struct such as `System.Decimal` or `System.Single`, uses the invariant culture, so its decimal point is `.` under any process culture.

String method-syntax (UFCS) ops lower to host `String` methods, no import needed: `s.length`, `s[i]` (a `Char`; fails when the unit at `i` is a UTF-16 surrogate half), `s.codeUnitAt(i)` (the raw code unit as `Int`), `s.substring(start[, count])`, `s.trim()` / `s.trimStart()` / `s.trimEnd()`, `s.replace(old, new)`, `s.indexOf(sub)` / `s.lastIndexOf(sub)` (with `import Std.String` in scope — plain or aliased, the import form is never a semantic switch — these return `Option[Int]` on both targets, UFCS sugar for the `Std.String` free functions; without the import they return `Int`, `-1` if absent; `Std.String.indexOfRaw`/`lastIndexOfRaw` are the explicit sentinel-int spellings), `s.contains/startsWith/endsWith(sub)` (`Bool`), `s.toLower()` / `s.toUpper()`, `s.isNormalized()` / `s.normalize()` (Unicode NFC normalization check/conversion, dotnet and JVM — `Std.String.isNormalized`/`normalize`). Search and prefix/suffix tests are ordinal and case conversion is locale-neutral on every target (#7260, #7261). String `==`/`!=` compare by value. Every method above (`.indexOf`/`.lastIndexOf` included) type-checks with a real signature — wrong argument count/type is a compile-time `T0042`/`T0043` error — instead of the `TyError` leniency that used to swallow downstream type errors (#7335). **`--target native`** implements `s.length`, `s.toString()`, and `s.substring(...)` (pre-existing), plus — since #6588 — `s.trim()`, `s.indexOf(sub)` (respecting the same `import Std.String` → `Option[Int]` gate as the other two targets, #6752), and `s.contains/startsWith/endsWith(sub)`; since #6755 — `s.lastIndexOf(sub)` (same import gate as `s.indexOf`); since #6240 — `s.trimStart()`, `s.trimEnd()`, and `s.replace(old, new)` (an empty `old` is a no-op on native, unlike either managed target's own quirk — see language reference §12.1); since #6779 — `s.toLower()` / `s.toUpper()`, both a genuine Unicode simple case fold generated from the full Unicode Character Database (`scripts/gen_unicode_case_tables.py`), not the narrower five-script table #6588 originally shipped for `.toLower()`; and — since #6237 — `s[i]` (a byte offset that decodes the full Unicode scalar value via UTF-8 iteration, not a raw byte — for ASCII text, byte offset and codepoint index coincide, matching the other two targets element-for-element) and `String + Char` concatenation / `Char.toString()`. Every `String` scalar method above is now implemented on `--target native` **except `s.isNormalized()`/`s.normalize()`** (#7304): native has no Unicode normalization tables yet, so both fail with an explicit compile-time panic naming the method rather than compiling silently. See language reference §12.1.

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
| `lyric-feature-flags` | `Flags`, `Flags.Aspects`, `Flags.Registry` | Runtime feature toggles; in-process store; `FlagGated`/`FlagVariant` aspects backed by the pure-Lyric `Flags.Registry`. No remote (HTTP-polling) store is implemented. | — |
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
                                       # accepts --manifest <lyric.toml> to override discovery.
                                       # A broken nearest manifest (TOML error, invalid field,
                                       # or [package] missing a required field) stops the walk
                                       # with "warning: ignoring lyric.toml at ..." instead of
                                       # silently adopting an ancestor; a [workspace]-only file
                                       # (no [package]) is skipped and the walk continues

# Build
lyric build <file.l>                   # compile to .dll + .runtimeconfig.json
                                       # prints elapsed time on success: "built foo.dll in 342ms"
                                       # project mode: "built foo.dll (3 package(s), 1204ms)"
lyric build --force <file.l>           # rebuild unconditionally (bypass incremental check)
                                       # PROFILE axis (optimization + debug symbols):
lyric build --debug <file.l>           # unoptimized, debug info retained (the default)
lyric build --release <file.l>         # optimized, debug info stripped. On --target native, the
                                       # clang -O level defaults from this axis (2 vs. 0). Integer
                                       # overflow wraps instead of panicking (D163). dotnet/jvm
                                       # perform no further optimization, and contract elision
                                       # is not yet profile-driven (#6263).
                                       # NOTE: --release no longer implies AOT. Pass --aot too.
                                       # SHAPE axis (packaging), independent of profile and target:
lyric build --shape portable <file.l>  # framework-dependent (default)
lyric build --shape standalone <file.l>  # bundles a runtime (not implemented — F0044, #6262)
lyric build --shape aot <file.l>       # native binary; --aot is sugar for this
lyric build --target native --triple wasm32-wasi --shape module <file.l>  # .wasm + .js glue + .d.ts for a JS host (--shape component builds a WebAssembly component, needs wasm-tools and $LYRIC_WASI_ADAPTER)
                                       # a manifest's own [build] shape = "portable"/"standalone" on
                                       # --target native raises F0043 too (#6268) -- not silently
                                       # upgraded to aot; only an UNDECLARED manifest shape defaults
                                       # to aot on that target.
lyric build --release --aot <file.l>   # single-file: self-contained Native AOT binary
lyric build --release --aot            # project-mode: entry package auto-detected (func main())
lyric build --release --aot --manifest lyric.toml  # explicit project manifest
lyric build --release --aot <file.l> --rid <rid>   # override host runtime identifier
lyric build --release --aot <file.l> -o <bin>      # native binary output path
lyric build --release --aot --target jvm <file.l>  # GraalVM native-image over the bundled JAR.
                                       # native-image found via $GRAALVM_HOME/bin, $JAVA_HOME/bin,
                                       # then PATH; always --no-fallback (never a JVM-requiring
                                       # image). Cannot cross-compile: --rid must name the host.
lyric build --release --shape portable <file.l>    # optimized framework-dependent DLL
lyric build --release-from-dll <dll>   # link a pre-built managed artifact to a native binary,
                                       # skipping source compilation entirely: ILC + clang on
                                       # --target dotnet, native-image on --target jvm (pass a .jar).
                                       # defaults to <stem> next to the artifact; use -o to override.
lyric build --release-from-dll <dll> --extra-refs-dir <dir>
                                       # add every *.dll (or *.jar on --target jvm) in <dir>,
                                       # except the primary artifact, as extra references —
                                       # used by bootstrap.sh for stage-2 builds.
lyric build --target dotnet <file.l>   # target .NET (default): writes foo.dll + foo.runtimeconfig.json
lyric build --target jvm <file.l>      # writes a runnable foo.jar (NO runtimeconfig.json) via the
                                       # self-hosted JVM emitter (`Main-Class` derived from the source
                                       # `package` declaration; runs under `java -jar foo.jar`)
lyric build --target native <file.l>   # writes a self-contained POSIX executable (no extension)
                                       # via the LLVM backend + clang; --triple cross-compiles,
                                       # --opt 0|1|2|3|s sets the clang -O level. triple/opt default
                                       # from the manifest [native] table (CLI flags override); with
                                       # neither, -O level now defaults from the PROFILE axis (#6263):
                                       # 2 under --release, 0 under the default --debug profile.
                                       # [native].extra_libs adds -l<name>.
                                       # ARC-managed (no GC; cycles need NativeWeak[T]). Surface:
                                       # scalars/strings, records, opaque types (share record
                                       # codegen — construction/field access/ARC release),
                                       # unions, enums, distinct types,
                                       # tuples, match, generics (monomorphized), closures,
                                       # non-generic interfaces (impl I for Record, vtable
                                       # dispatch on an interface-typed receiver, or direct
                                       # resolution on the concrete record receiver),
                                       # NativeWeak[T], slice[T], List/Map +
                                       # for/indexing (map keys String or scalar); non-generic
                                       # protected types (entry/func both lock a mutex buffer via
                                       # a lock/unlock wrapper); non-generator async func as a
                                       # real LLVM coroutine on a cooperative scheduler (direct
                                       # calls await in place; spawn holds the task for a later
                                       # await; spawned tasks genuinely interleave;
                                       # Std.Time.sleepMillis in an async body suspends only the
                                       # calling task; Std.Process.runCapture captures without
                                       # blocking other tasks, timeoutMs honored); scope { } as a
                                       # real lexical scope;
                                       # defer (normal-exit paths: fall-off, return,
                                       # break, continue); raw FFI
                                       # (NativePtr[T], nativeAddrOf, nativeNullPtr,
                                       # nativeLoadByte/nativeStoreByte,
                                       # closure-as-C-callback trampolines) only in @unsafe_ffi
                                       # functions / _kernel_native packages (N0100).
                                       # Not yet lowered (build fails naming the construct):
                                       # interface default/generic methods, generic protected
                                       # types, when: barriers, invariant re-checking,
                                       # async generators (yield in async func), a defer that
                                       # must run during a panic
lyric build -o <dir> <file.l>          # write output files to <dir>
lyric build --manifest lyric.toml      # build from project manifest
                                       # (with [project] output = "single", bundles every
                                       # [project.packages] entry into one DLL with one
                                       # Lyric.Contract.<Pkg> resource per package)
                                       # auto-restores [dependencies] when lyric.lock is missing/stale
                                       # ([nuget]/[maven] edits aren't detected — run `lyric restore`)
                                       # --target native (N9.7, #6809) compiles a project's own
                                       # [project.packages] from source too, plus its path and
                                       # workspace = true [dependencies] and theirs, each with
                                       # its own [features] (#7833); a registry or git
                                       # dependency fails a native build. Reordering units so
                                       # whichever package declares main drives C-main synthesis
                                       # regardless of manifest order; --triple/--opt override the
                                       # manifest [native] table here too (#6815 item 2). A
                                       # workspace/path dependency is skipped (not built) for
                                       # --target native rather than crashing (#6815 item 1a) — its
                                       # own SOURCE is still not compiled into the native bundle
                                       # (no restored-binary concept, item 1b remains open). `lyric
                                       # run --manifest --target native` works (item 3a); `lyric
                                       # test`'s manifest mode stays native-unsupported (item 3b).
lyric build <file.l>                   # single-file mode also resolves dependencies from a nearby
                                       # lyric.toml (--target dotnet/jvm): explicit --manifest wins,
                                       # else discovered by walking up from <file.l>'s OWN directory
                                       # (not the shell's cwd). No new dependency syntax in the .l
                                       # file itself; an unbuilt dependency fails loud (never
                                       # auto-restores). No-op (byte-identical build) when no
                                       # manifest is found, or one is found with nothing
                                       # dependency/feature-relevant to contribute.
lyric build --no-restore               # build against the lock as-is (skip auto-restore)
lyric build --package-version <ver>   # override the version string embedded in Lyric.Contract.*
                                       # metadata resources (instead of the version in lyric.toml);
                                       # used by publish pipelines to stamp the git release version
lyric build --define KEY=VALUE <file.l>  # inject a compile-time String into a @build_const("KEY")
                                       # module-level val (docs/60). Repeatable. Substituted before
                                       # type-check as a String literal (no source re-parse). An
                                       # unsupplied key keeps the val's in-source fallback literal.
                                       # v1: single-file AND project (--manifest / lyric.toml),
                                       # all three targets (native project builds shipped in N9.7,
                                       # #6809 — a side effect of gaining a project build path at
                                       # all). On a project build the manifest
                                       # [package].version is the well-known `version` fallback an
                                       # explicit --define version=… overrides. The active backend
                                       # (dotnet/jvm/native) is auto-injected as the well-known
                                       # `target` define on every build (also override-able), and
                                       # `build_profile` is auto-injected from the PROFILE axis:
                                       # debug (default) or release (--release), independent of
                                       # shape — so --release --shape portable reports "release".
                                       # User --define is rejected with --watch and with a
                                       # non-portable --shape (docs/63 §5.3 re-scoped this off
                                       # --release). Native --define works (#5977).

# Build kind (manifest [build] kind, .NET target; default "lib")
#   kind = "lib"     -> managed foo.dll + foo.runtimeconfig.json (run via `dotnet exec`)
#   kind = "exe"     -> the above PLUS a native apphost launcher `foo` (`foo.exe` on
#                       Windows); run directly with `./foo` (still needs .NET installed).
#                       `lyric run` execs the launcher instead of `dotnet exec`; if the
#                       launcher is missing it warns and falls back to `dotnet exec`.
#   kind = "bundle"  -> self-contained (runtime bundled) — planned, build errors for now
#   kind = "aot"     -> REMOVED (F0042). "aot" is a packaging shape, not an artifact kind:
#                       use [build] shape = "aot". Hard error, never a silent remap.

# Build shape and profile (manifest [build], docs/63) — axes independent of each other
#   shape   = "portable" | "standalone" | "aot"   (default "portable")
#   profile = "debug" | "release"                  (default "debug")
#   # CLI over manifest over default. shape = "aot" -> native AOT, no runtime;
#   # Linux (x64/arm64) and macOS, clang/ld64 required; Windows tracked in #1975.

# Build defines (manifest [build.define] table; docs/60 §3.1)
#   [build.define]
#   build_channel = "stable"          # string values only; injected into @build_const("build_channel")
#   api_base      = "https://api.example.com"
#   # Layered beneath CLI --define (a --define of the same key wins). Applied on
#   # --target dotnet/jvm project builds; rejected on a non-portable shape.
#   # (native is single-file only, so [build.define] is dotnet/jvm; native uses
#   #  single-file --define.)

# Build features (compile-time gating; see chapter 20 §20.7)
lyric build --features X,Y <file.l>    # additive over manifest's [features] default
lyric build --no-default-features      # suppress the default = […] set
lyric build --all-features             # transitive closure of every declared feature
                                       # (all of the above flags also work on
                                       #  lyric run / test / prove / publish)
                                       # --features/--no-default-features propagate to
                                       # workspace-dependency builds; a platform-named
                                       # default feature (dotnet/jvm/native) is swapped
                                       # to match --target (docs/24 s2.3)

# Runtime contract control (manifest [contracts])
#   [contracts]
#   enabled = true              # toggle for user-level contract checks (requires:, ensures:)
#   # Default: true (all contracts checked at runtime). When false, user-written
#   # requires: and ensures: assertions are gated out (but system-level invariants,
#   # range checks, and @proof_required modules remain active). Useful for
#   # production deployments where contract overhead matters. See language reference
#   # §3.7 and §6.4, and chapter 8 for @proof_required exemption details.

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
lyric test <file.l> --target native    # compile via the LLVM backend and run the binary
                                       # directly (single-file only; no try/catch isolation
                                       # per test — a failing assertion aborts the process,
                                       # D-N-003/D-N-018)
lyric test <file.l> --properties       # also run `property` declarations (#677): auto-derived
                                       # sampling + shrinking for Int/Bool/Double forall binders;
                                       # any other binder type still reports `# skip`. Rejected
                                       # on --target native (no unwinding to isolate a sample).
lyric test <file.l> --properties \
  --property-trials <N>                # (v2 slice 1, #6907) override the per-property sample
                                       # count (default 100, must be >= 1); requires --properties
lyric test <file.l> --properties \
  --seed <N>                           # (v2 slice 1, #6907) override the starting RNG seed
                                       # (default 1000; each property in the file still gets its
                                       # own distinct offset seed); requires --properties. A
                                       # failure's panic message reports the exact seed/trials
                                       # used, so it can be replayed exactly.
lyric test <file.l>                    # a loose test file next to a lyric.toml also resolves
                                       # that manifest's dependencies (D123/#5341), exactly like
                                       # `lyric build`/`lyric run` — an unbuilt dependency fails
                                       # the run rather than silently compiling without it
lyric test <file.l> --target jvm \
  --coverage                           # instrument with JaCoCo, write
                                       # <dir>/.lyric-test/coverage/<stem>-cobertura.xml
                                       # (+ <stem>-jacoco.xml); single-file JVM-target only
                                       # for now (D135). Needs jacocoagent.jar/jacococli.jar
                                       # via LYRIC_JACOCO_AGENT/LYRIC_JACOCO_CLI or `make jacoco`.
lyric test <file.l> --update-snapshots # (#678) rewrite every Std.Testing.Snapshot baseline this
                                       # test file touches to match its actual output instead of
                                       # failing on mismatch; commit the rewritten snapshot files.
lyric test                             # project mode: run every [project.tests] entry;
                                       # falls back to scanning [project.packages] for
                                       # @test_module files when [project.tests] is empty
lyric test --fail-fast                 # project mode: stop after first failing test entry
lyric test --properties                # project mode: also run `property` declarations in
                                       # every test entry (composes with --fail-fast/--filter)
lyric test --properties \
  --property-trials <N> --seed <N>     # project mode: same trial-count/seed override, applied
                                       # to every [project.tests] entry that runs properties
lyric test --update-snapshots          # project mode: rewrite snapshot baselines across every
                                       # [project.tests] entry
lyric test --manifest <lyric.toml>     # project mode: override manifest discovery
                                       # (v2: --doctests, cross-package non-pub access)
lyric test --features a,b              # project mode: activate manifest [features]
                                       # (same grammar/precedence as lyric build)
lyric test --no-default-features       # suppress the manifest's default feature set
lyric test --all-features              # activate every declared feature
                                       # e.g. run a suite against the jvm-gated kernel:
                                       #   lyric test --manifest m.toml --target jvm \
                                       #     --no-default-features --features jvm
lyric test <file.l>                    # a @test_module gated out entirely by an inactive
                                       # file-level @cfg(feature = "X") prints "0 test(s),
                                       # module gated by inactive @cfg" and exits 0, instead
                                       # of compiling/running an erased module (#6868)

# Stale-stdlib-bundle warning (dev tree only, --target dotnet)
#   `lyric run` / `lyric test` link the PRECOMPILED Lyric.Stdlib.dll for
#   runtime, so editing lyric-stdlib/std/** without rebuilding the bundle
#   silently runs against stale code.  When run inside a source checkout, both
#   commands print a stderr warning if any stdlib source is newer than the
#   compiled bundle — rebuild with `make lyric` before trusting the run.  It is
#   a no-op for installed SDKs (no source tree) and for a freshly-built bundle,
#   and goes to stderr so TAP output on stdout stays clean.

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
#        L004 TODO/FIXME in doc, L005 pub func without contracts,
#        L007 package-private type in a pub signature
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
                                       # a single-file proof is relative to the file's ancestor
                                       # manifests; prove a package whose manifest lists files
                                       # outside its own tree with --manifest

# Benchmarking  (see chapter 28)
lyric bench <file.l>                   # compile and run @bench_module timing harness
lyric bench <file.l> --target jvm      # benchmark on JVM target (java -jar)
lyric bench <file.l> --target native   # benchmark the native executable
lyric bench <file.l> --target native --opt 3   # native at another -O level (default 2; also --triple)
lyric bench <file.l> --runs <N>        # number of timed iterations (default: 100, at least 1)
lyric bench <file.l> --warmup <N>      # un-timed warmup iterations (default: 5)
lyric bench <file.l> --filter <substr> # only run benchmarks whose name contains <substr>
lyric bench                            # project mode: run all @bench_module files in project
lyric bench --target jvm               # project mode: JVM target
lyric bench --manifest <lyric.toml>    # project mode: override manifest discovery
# Output: "name  min=Xms  max=Xms  mean=Xms  alloc=NB/run" per @bench function
#   alloc = heap bytes per run (Std.Bench.allocatedBytes(), current thread)
# Requirements: file must carry @bench_module; @bench functions must be pub func f(): Unit

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
                                       # ([maven] entries of workspace/path deps included, transitively)
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
lyric publish --package-version <ver>  # override the NuGet <version>, .nupkg filename, and
                                       # cross-library <dependency> versions in the nuspec; also stamps
                                       # Lyric.Contract.* metadata resources embedded in the DLL;
                                       # used by publish pipelines to stamp the git release version
lyric publish --wasm                   # pack the built wasm32 module/component as an NPM tarball
                                       # (--wasm-file <path>, -o <dir>); then `npm publish <tgz>`
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
| `L0015` | error | Unrecognised numeric suffix (e.g. `100xyz`, `1u7`, `2i128`): the message names the suffix and lists the valid ones — `i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64` `f32` `f64` on a decimal literal, only the integer suffixes on a hex/octal/binary literal, only `f32`/`f64` on a float literal |
| `L0016` | error | Radix prefix with no digit after it, separators aside (e.g. bare `0x`, `0b`, `0o`, `0b___`): reported on the prefix as the literal's only diagnostic, with no follow-on `L0010`; a suffix after it adds no `L0015`, so `0xu8` is one `L0016` |

### Linter (L-series)

Style and quality rules checked by `lyric lint`.  These are single-digit codes (no leading zeros) distinct from the four-digit lexer codes above.

| Code | Severity | Meaning |
|---|---|---|
| `L001` | error | Type name must be `PascalCase`; constants must be `PascalCase` or `UPPER_SNAKE_CASE` |
| `L002` | error | Function name (including `entry` in `protected` blocks) must be `camelCase` |
| `L003` | warning | `pub` item has no doc comment (`///`) |
| `L004` | warning | Doc comment contains `TODO` or `FIXME` |
| `L005` | warning | `pub func` with a block body has no `requires:`/`ensures:` contracts |
| `L007` | warning | `pub`/`internal` item's signature names a package-private type from the same file (receiver, parameter, return, field, union case payload, interface method, `pub val` type) |

### Type checker (T-series)

| Code | Meaning |
|---|---|
| `T0001` | Duplicate declaration: two top-level items in the same package share a name |
| `T0010` | Unknown type name |
| `T0012` | Primitive type does not take type arguments |
| `T0013` | Name is not a type |
| `T0014` | Unknown qualified type name (last segment not in scope) |
| `T0015` | Integer literal out of range for the declared integer type (an inline range-refined type, a plain `Byte`/`Int`/`UInt`/`Long`/`ULong`/`Nat` binding or assignment target, or a literal pattern or range bound against a `Byte`/`UInt`/`ULong` scrutinee) |
| `T0016` | Non-exhaustive `match` (uncovered union/enum case, `Bool`, or scalar without `_`) |
| `T0017` | Type alias is part of a cycle and does not resolve to a type |
| `T0020` | Unknown name (undefined variable or function), including a type or package-qualified path whose package is not reachable from the file's imports (add the `import` it names) — the same check covers a qualified path in TYPE position (`val c: Pkg.Sub.Type`, a parameter/field/return type, or a generic type argument) and a qualified PATTERN head (`case Pkg.Sub.Kind.A -> ...`) |
| `T0030` | Arithmetic on a non-numeric type, or on a distinct type without the operator's `derives` marker (including a compound assignment such as `+=` without `Add`) |
| `T0031` | Arithmetic operands have mismatched types |
| `T0032` | Equality operands have mismatched types |
| `T0033` | Comparison operands must be matching ordered types |
| `T0034` | Logical operator applied to non-Bool operand |
| `T0035` | `??` misuse: the left operand is not a nullable type, or the right operand does not match the nullable's inner type |
| `T0036` | Unary minus on a non-numeric type (including any distinct type) |
| `T0037` | `not` applied to non-Bool operand |
| `T0041` | List literal elements have mismatched types |
| `T0042` | Wrong number of arguments to a function or method call, a named argument naming no parameter, a parameter with no default left without an argument, or a parameter given more than once (named twice, or named after a leading positional argument supplied it: `f(1, a = 2)`) |
| `T0043` | Argument type does not match parameter type |
| `T0044` | Called value is not a function |
| `T0050` | Unknown type parameter in where clause |
| `T0051` | Unknown constraint marker in where clause |
| `T0060` | `val` binding (local or module-level), field default or parameter default does not match its declared type |
| `T0061` | `var` binding type annotation does not match initialiser |
| `T0062` | `let` binding type annotation does not match initialiser |
| `T0063` | Assignment type does not match target type |
| `T0064` | `return` without value in non-Unit function |
| `T0065` | Returned type does not match declared return type |
| `T0066` | `if` condition, `while` condition, or `match`-arm guard is not `Bool` |
| `T0067` | Incompatible `if`/`match` branch types (or value-position `try` handler type incompatible with the `try` body) — branch unification is position-aware: a `Unit`-vs-value branch mismatch is lenient in statement position but rejected in value position; where the position has a declared type (return, annotated binding, parameter, field) each branch is checked against it instead, so branches of different types that each fit it are accepted |
| `T0068` | A const pattern (`case @NAME ->`) names a constant whose type does not match the scrutinee's type |
| `T0069` | A const pattern (`case @NAME ->`) names a `val` that is not initialized with a literal, so it is not a compile-time constant |
| `T0070` | Function body type does not match declared return type |
| `T0071` | A const pattern (`case @NAME ->`) names a constant of generic type; const patterns must be monomorphic |
| `T0072` | A const pattern (`case @NAME ->`) names something that is not defined, or is not a `val`/`const` |
| `T0073` | `null` used in pattern position — Lyric has no null literal or null pattern; `case null -> ...` parses as an ordinary catch-all binding named `null`, not a null test |
| `T0080` | `old(…)` outside an `ensures:` clause, nested inside another `old(…)`, or applied to an operand that mentions `result` |
| `T0085` | `out`/`inout` argument must be a mutable l-value: a value-type argument a `var`, a by-reference parameter, a writable field or an element of a writable array; no argument a module-level binding, or an element of a `List`, `Map`, slice, `String` or extern type (#8180) |
| `T0086` | `out` parameter is never assigned before the function returns |
| `T0087` | Reassigning an immutable binding (`val`/`let` or an `in` parameter), or assigning `self` when the receiver is `in` |
| `T0090` | Range bounds are inverted or produce an empty range |
| `T0091` | `range` applied to a non-numeric underlying type |
| `T0093` | Range bound expression cannot be evaluated at compile time |
| `T0094` | `yield` used in a function that is not `async` (generators must be `async`) |
| `T0095` | A `yield` value's type does not match the generator's declared element type |
| `T0096` | `@hot` on an `async` generator has no effect and is ignored (warning) |
| `T0097` | Package-private symbol referenced from another package, including a package-private type used as a `Type.method(...)` receiver, a type-position reference (`val w: Pkg.Widget`), a private union/enum's case in a pattern head, or a private record in a record-pattern head — qualified or bare — whether or not the declaring package is imported (mark it `pub` or `internal`) |
| `T0098` | `impl` is missing an abstract interface method |
| `T0099` | `impl` method parameter arity does not match the interface declaration |
| `T0100` | Opaque type constructed outside its declaring package |
| `T0101` | Constructor names a field the type does not have |
| `T0102` | Pattern-matching an opaque type's representation outside its declaring package |
| `T0103` | A numeric/character conversion method (`.toInt()`, `.toLong()`, `.toByte()`, `.toChar()`, `.toDouble()`, `.toNat()`, ...) is called on a receiver type it does not apply to, such as `String`, `Bool` or `Unit`, `.toUInt()` on a primitive outside `Byte`/`UInt`, or `.toULong()` on a primitive outside `Byte`/`UInt`/`ULong` |
| `T0104` | Constructor argument does not fit the constructed type: a named or positional argument's type does not match the field's type (including a record `.copy(field = value)` argument), more positional arguments are supplied than the type has fields, or a field is given more than once (named twice, or named after a leading positional argument supplied it) |
| `T0105` | Constructor call (record, opaque, generic or non-generic, or a named-field union case) omits a required field with no default, in an all-named-args construction |
| `T0106` | An `impl` method's parameter type does not match the interface method's declared parameter type |
| `T0107` | An `impl` method's return type does not match the interface method's declared return type |
| `T0108` | A generic type argument does not satisfy a `where`-clause constraint on its type parameter |
| `T0109` | Value expression used where a type argument is required |
| `T0110` | Generic constructor's type parameter(s) cannot be inferred from the arguments (add explicit type arguments). A field value that leaves a parameter open, such as `None`, does not stop another field from fixing it: `Holder(value = None, fallback = 5)` is a `Holder[Int]` (#7844). Also a function's value generic parameter that no array argument gives a length, such as `make()` for `func make[N: Nat](): array[N, Int]` (write `make[4]()`). |
| `T0111` | Unknown constraint name in a `where` clause (warning) |
| `T0112` | Refutable pattern in a `for` loop binding (only names, `_`, parentheses, and tuples of those) |
| `T0113` | Unknown member: `x.name` or `x.name(...)` names no field, method, or impl method of the receiver's user-defined type, or of a distinct type (a distinct type does not expose its underlying type's members; read them through `.value`) |
| `T0114` | A function declares a non-`Unit` return type but has no body that produces a value (only `@axiom` functions, externs, and interface method signatures may omit the body) |
| `T0115` | A qualified reference (`Pkg.name`) does not resolve to anything the compiler can verify — most commonly a `pub val` in a workspace/restored dependency whose initializer isn't a literal (only literal-foldable `pub val`/`pub const` values round-trip across a restored-dependency boundary today, docs/45); the fix is to wrap the value in a `pub func` in the producing package and call that instead. Raised at MSIL codegen time (`Msil.Codegen`), not by the type checker proper — the check catches the reference just before it would otherwise fall through to a silent `null`/uninitialized read. |
| `T0116` | Field-style access (`x.name`, no call parens) to a name that exists only as a D037 dot-named (UFCS) function, never as a real field — e.g. `e.message` where `message` is declared as `pub func IOError.message(e: in IOError): String`. Call it instead (`e.message()`). Fires for both locally-declared and imported/cross-package receiver types, since dot-named function signatures are known globally. |
| `T0117` | Diamond conflict: two (or more) same-file interfaces each provide a default method with the same name for the same impl target, and no impl block overrides it. Resolve by overriding the method explicitly in an impl block — the override claims the name for the whole target and no default copy is synthesized. |
| `T0118` | A default-method body references a non-member through a `Self`-typed value (`self.<field>`, or `<param>.<field>` where the parameter is typed `Self`) — including through a chain of calls to other `Self`-returning interface members (`self.withX().field`) and through a parenthesized receiver (`(other).field`). A default method's `Self` is the interface itself, which owns no fields — the body may only reference interface members (`self.<member>()` or bare `<member>()`). A body that needs a field must be overridden in the implementing `impl` block, where `Self` narrows to the concrete target type. A local binding that shadows a `Self`-typed parameter name inside a nested block is exempt for the extent of that block (block-scoped shadowing). |
| `T0119` | `Alias.member` on an extern type does not resolve to a static property getter, a literal constant, a static field, or a zero-argument static method in .NET reference-assembly metadata (`Alias` names an `extern type`) — most often a typo, or a member the auto-FFI static-access probes don't cover (an argument-bearing method, an overload). Check the name for a typo, or declare an `@externTarget` wrapper for a custom binding. Raised at MSIL codegen time (`Msil.Codegen`) with the access expression's source span; `Lyric.Emitter`'s bridge boundary catches it, prints it as a normal diagnostic, and carries it in `EmitResult.diagnostics` instead of letting it reach the CLI as an uncaught exception (#6449). |
| `T0120` | Generic fallback for an MSIL codegen failure that panicked without its own `error[T0NNN]:`-prefixed diagnostic — `Lyric.Emitter`'s bridge boundary catches every MSIL codegen panic (the same layer as the JVM target's `J008` catch-all; `Msil.Bridge` itself deliberately lets the panic escape as its library contract) so a build always ends in a printed diagnostic plus an `EmitResult.diagnostics` entry, never a raw uncaught exception with a .NET stack trace. The wrapped message names the underlying failure; treat it as a compiler-internal-error report (file an issue) unless the wrapped text itself points at a source-level mistake. |
| `T0121` | A member access could not be resolved because the receiver's static type was erased to `object` before codegen, so the compiler cannot verify the member exists. Annotate the receiver with an explicit type (`val x: Pkg.Type = ...`) or check the member name for a typo. Raised at MSIL codegen time (`Msil.Codegen`), with the receiver's source position, like `T0119`. |
| `T0122` | A qualified union- or enum-case pattern (`case Pkg.Kind.A -> ...`) names a qualifier that does not match the scrutinee's own union or enum |
| `T0123` | A bare (unqualified) name — a function, `val`/`const`, or union/enum case constructor — is declared by two or more packages imported at the same use site; referencing it unqualified is an error naming every declaring package, rather than silently resolving to whichever package happened to register the name last. Two packages reached only transitively (through the whole imports of different imported packages) that both declare the name collide the same way. Fix by qualifying the reference (`Pkg.name`). Not flagged: a local declaration that shadows the ambiguous import, a name reachable through only one of the imports (no actual collision), a name reachable only transitively through another package's own whole imports when a direct import also declares it (the direct one wins), or a pattern match against a scrutinee of statically known type (which resolves the case against the scrutinee's own union/enum directly, without needing qualification). Also raised when a function reference used as a value, bare or qualified, names a package function that has overloads: a value reference cannot pick an overload, so wrap the call in a lambda with typed parameters. |
| `T0124` | A receiver structurally matches `Std.Core.Result[T, E]` / `Option[T]`'s reserved shape (bare name + matching arity) but is a *different* type declared outside `Std.Core`, and one of the six reserved accessor names (`.isOk`/`.isErr`/`.value`/`.error`/`.isSome`/`.isNone`) was accessed on it with no real matching member of its own. `Result`/`Option`'s accessor sugar is resolved by type identity, not by name, so a same-named foreign union never receives it (#6630); define your own member under that name, or call it through `Std.Core.Result`/`Option` if that was the intent. |
| `T0125` | A call's callee names a `union` or `enum` **type** itself (`DbError(message = …)` where `DbError` is a union), not one of its cases. A union/enum has no constructor of its own — a value is built through a case (`OpenFailed(message = …)`), so the message names the constructible cases. Fix by naming the intended case. Reported at type-check time rather than degrading to an unresolved-callee failure at code generation (#6838, D-progress-875). Not flagged: constructing an actual case, or a record/opaque type by its name (those have real constructors). |
| `T0126` | A `for` loop iterates a value that is not iterable. Iterable: slices, arrays, the stdlib `List[T]`, `Map[K, V]`'s key/value collections, ranges, generator calls and `extern type`s (a single-type-parameter one iterates its type argument — the phantom-type-param idiom for a foreign collection). Everything else is rejected, whatever its arity: records, unions, enums, opaque, protected, distinct and interface types (`Option[T]`, #6720; `record Pair[A, B]`, #7781), primitives, tuples, function values, and the stdlib `Map[K, V]` itself — iterate `mapKeys(m)`/`mapValues(m)`/`mapEntries(m)`; a distinct type's `.value`. A `String` is rejected too — iterate `Std.String.codePoints(s)` or index with `s.codeUnitAt(i)` (D-progress-1006). These used to type the loop variable as an error, hiding every diagnostic about it in the body, and fail at runtime. |
| `T0127` | A record `.copy(...)` call is malformed: it passes a positional argument (copy takes named field arguments, `r.copy(field = value)`) or names the same field more than once. |
| `T0128` | Another package's function is used as a value, but it is generic, `async`, has a non-`in` parameter, or has a parameter type that cannot be named at the use site, so no forwarding lambda can stand for it. Wrap the call in a lambda instead: `{ x: Int -> Pkg.f(x) }`. |
| `T0129` | A union- or enum-case pattern is matched against a value of a different type: `case Some(i)` on an `Int`, or `case Ok(v)` on an `Option`. The pattern can never match; it used to type-check and then take the wrong arm on dotnet or fail JVM verification. Fix the scrutinee or the pattern. A bare nullary case (`case None`) is checked the same way. Not checked when the scrutinee's type is unknown or open (a type variable, `Self`, a nullable). |
| `T0130` | `break` or `continue` outside a loop, or `break label` / `continue label` where no enclosing loop has that label. A lambda body, a `defer` body and a `finally` block start with no enclosing loops. |
| `T0131` | A loop reuses the label of a loop it is nested in, so `break label` would be ambiguous. Rename one; sibling loops may share a label. |
| `T0132` | A contract clause has the wrong type: `requires:`, `ensures:`, `when:`, loop `invariant:` and a protected type's `invariant:` must be `Bool` (a protected invariant reads the fields by bare name). Clauses are checked in the function's scope, with `result` typed as the declared return type. |
| `T0133` | A contract clause or loop invariant calls a function that is not `@pure`. Mark the callee `@pure` if it has no side effects (the compiler trusts the annotation), or move the check into the body. |
| `T0134` | A compound assignment (`+=`, `-=`, ...) to a distinct type, or to a record with derived `Add`/`Sub`, has a target that is not a variable or field path (`xs[i] += y`). The assignment is rewritten to `x = x op y`, which evaluates the target twice; write it out explicitly. |
| `T0135` | A protected type's `func` member, or a method of an `impl` for a protected type, is `async` or declares its own type parameters. Every `entry` and `func` (and every such impl method) runs under the instance lock, which cannot be held across an `await` or taken by a method-generic member. |
| `T0136` | An `impl Iface for P`, where `P` is a protected type, that cannot become part of `P`: the impl is declared in another package than `P`, its target names `P` through an `alias`, `P` or the impl is generic, or an impl method has the same name as one of `P`'s own `entry`/`func` members or as a method of another impl for `P`. An impl method on a protected type is itself a locked member of the type, so move the body into the impl or rename the member. (An impl method's signature mentioning a BARE `Self` is accepted on `--target dotnet`/`--target jvm` since #7550 and on `--target native` since #7585; `Self` nested inside a generic type argument, e.g. `List[Self]`, is accepted on `--target dotnet`/`--target jvm` but still rejected on `--target native` with `N0006`, tracked in #7603.) |
| `T0137` | A record pattern's own head (`case Head { field = pat, … } -> …`) does not name the scrutinee's own record: a different record, a union/enum case, an unresolved name, or (for a qualified head) the right record's simple name under the wrong package qualifier. The record-pattern counterpart of `T0129`'s union/enum-case check. Not checked when the scrutinee's type is unknown or open (a type variable, `Self`, a nullable). A qualified head naming the right record under an unreachable package is `T0020`, and one naming a package-private record is `T0097` (checked first), instead of `T0137`. |
| `T0138` | Retired (D160): renaming a selectively imported name (`import P.{f as g}`) is supported. |
| `T0148` | A renamed import's new name (`import P.{f as g}`) is also a declaration or case of this package, another import's bare name, a public name or case of a package imported whole, a package alias, or the first segment of an imported package's path; choose another name. |
| `T0149` | An `extern func` names no `@library` on `--target dotnet` or `--target jvm`; add `@library("name")` so the managed target knows which C library to bind. |
| `T0150` | An `@library` argument is not one non-empty string, or a declaration has more than one `@library`. |
| `T0151` | A C binding's parameter or result type cannot cross the call; use `Int`, `Long`, `Byte`, `Float`, `Double`, `NativePtr[T]`, or `Unit` as a result. |
| `T0152` | A record derives arithmetic it cannot have: only `Add` and `Sub`, and only on a non-generic record with no invariant whose fields all have one numeric type (component-wise, D155). |
| `T0153` | `==` or `!=` on a record that compares field by field (no `var` field, or `@derive(Equals)`) reaches a function-typed field, which has no `==` (D164). The same for `==` on an array whose elements are functions (D167). |
| `T0154` | A method-call receiver evaluated before an `await` or `?` in its arguments has a type argument that neither the receiver, the other arguments nor the expected result type fixes; bind the receiver to an annotated local (#7844). |
| `T0155` | A bracket literal where an `array[N, T]` is expected does not have exactly `N` elements (D167). |
| `T0156` | A declaration of array type with no initializer, or a record field of array type with no default, has an element type with no zero value: a `String`, a union, a function, or a range excluding zero (D167). Give it an initializer. |
| `T0157` | An element write `a[i] = v` (or `a[i] op= v`), or an `inout`/`out` array argument, on an array that is not a writable place: it needs a `var` local, an `out`/`inout` parameter or a `var` field; a collection element is not one (D167). |
| `T0158` | An array index that is not an integer or a range subtype of one (D167). |
| `T0159` | `@derive(Equals)` (or `Hash`, `Show`, an ordering, ...) on a record or union that has an array field: derived code would compare or print the array by reference, so write the method by hand. `==` on the type already compares the array element by element. The array may be reached through an `Option`, a tuple, a collection, an alias or a nested record or union (D167). |
| `T0160` | The length in an `array[N, T]` type is neither a compile-time constant from 0 to 2147483647 nor a value generic parameter; or `==` on a type that holds an array is recursive or nested too deeply to compare element by element. A function's value generic parameter is supported: each length is checked in its own specialisation. |
| `T0161` | (warning) A parameter of an `impl` method has a different default from the interface member's, or only one of the two declares a default. A call on an interface-typed value takes the interface's default and a call on the concrete type the `impl` method's, so the two would fill the argument differently; declare the same default in both (#7828). |
| `T0162` | Two methods of one name in one record, interface or `impl` have the same number of parameters. Methods of one name must differ in their number of parameters, as functions must (`T0001`). This is a limit of this compiler, not of .NET or the JVM: its MSIL, JVM and native backends identify a method by its type, name and parameter count (#8085). |
| `T0163` | A generic argument of the wrong kind for a record with value generic parameters: a type where the record takes a length (`FixedVec[Int, String]`), a length where it takes a type, or a length that is neither a compile-time constant integer from 0 to 2147483647 nor a value generic parameter (D169). |
| `T0165` | A method receiver with a mode it cannot have: `self: out T` anywhere, `self: inout` on an interface method or an `impl` method, or an `out`/`inout` receiver on a protected type's entry or function. Use `self: inout` on a record method or dot-named function, or return the new value (#8179). |
| `T0166` | The receiver of a method whose receiver is `self: inout` (or of any call passing a by-reference first parameter with method syntax) is not a writable place: a `val`, an `in` receiver, a module-level binding, a call result, a field path starting at a call result, an element of an array that may not be written, or an element of a `List`, `Map` or slice. Pass a `var`, an `out`/`inout` parameter, a field path starting at a named binding (#8179) or an element of a writable array (#8180). |
| `T0164` | Retired (D173): a value-generic record may be used from any package. |
| `T0168` | A protected type with a value generic parameter (`protected type Ring[N: Nat]`) is `pub`. Each length is specialised, whole, in the package that uses it, so for now the type is not shared across packages (#8149, D178). |
| `T0139` | An `impl` for a non-protected target (record, exposed record, union, or opaque type) declares a method whose name clashes with the target's own record-body (D037) method, or with a method of another `impl` for the same target. No backend can compile either shape (MSIL/JVM fail codegen with a duplicate-member error; native has no consistent tie-break); rename the impl method, the record's own method, or one of the two interface methods. The protected-type analog of this check is `T0136`. |
| `T0140` | A non-`Std.*` package declares a `func`/`pub func` under one of the reserved language-built-in names (`println`, `print`, `panic`, `assert`, `toString`, `default`, `expect`, `format1`-`format4`, `hashCode`, `__lyric_protected_wait`, `__lyric_protected_notify`) — every backend's builtin-call dispatcher intercepts these names unconditionally, so the declaration would be silently uncallable. Rename it. A `Std.*` package may still declare one of these names for its own distinctly-typed, qualified-only function (`Std.Console.println`) — see D-progress-1024 (#7508). |
| `T0141` | `&<expr>` is used anywhere — `&` is grammatically prefix-only (no infix form) and reserved for a planned function-reference form no backend implements. Every use is rejected, including `x & y`, which previously parsed as `x` (a complete expression) followed by a silently re-entered, silently accepted `&y` statement that discarded `y` with no diagnostic. Use `.and()`/`.or()`/`.xor()`/`.shl()`/`.shr()` for bitwise operations; pass a lambda where a function reference was wanted. |
| `T0142` | A `yield` inside a `catch` handler, a `finally` block, or a `defer` block of an async generator. Those blocks run while an exception or an exit is in flight, and a generator cannot suspend and later re-enter them. A `yield` in the protected `try` body itself is fine: suspending there does not run the `finally`. Record the value and yield it after the `try`. |
| `T0143` | Indexing (`x[i]`) a Lyric-native record, union or enum. No backend has an indexer protocol for one, so it used to compile and then fail at runtime with a cast exception. The indexable types are slices, arrays, `String`, and the stdlib `List`/`Map` (recognised by identity, so a package's own `record List[T]` is not one); extern types keep backend-resolved indexing (#7737). |
| `T0144` | Refutable pattern in a module-level `val` (a constructor, record, literal, range, type-test, alternative or const pattern). A module value has no failure path, so only names, `_`, `name @ <pattern>` and tuples of those are allowed; the message names the form. State a type with `val n: Int = 3`, not `val n is Int = 3` (#7763). |
| `T0145` | An `impl` for a generic type whose type arguments are not the impl's own type parameters, each named once, or with an impl type parameter the target never names. An impl applies to every instantiation of its target (both backends attach its methods to the target's one generic class), so write `impl[T] I for Box[T]` (parameters in any order: `impl[K, V] I for Pair[V, K]`); an impl for a single instantiation such as `impl I for Box[Int]` is not supported (#7704). |
| `T0146` | A local `val`'s pattern cannot match every value of its initializer's type (or annotation). A local `val` destructures with no failure path, so a tuple pattern needs a tuple of the same arity at every level (`val (a, b) = 5` and `val (a, b) = (1, 2, 3)` are errors), a constructor pattern needs the sole case of a single-case union (`val Some(x) = opt` is an error), a record pattern must name the initializer's own record and only its fields (`val Point { x, y } = n` for an `Int` `n` is an error), and a literal, range, type-test, alternative or const pattern is never allowed; use a `match`. Such bindings used to compile and fail at runtime (#7778). |
| `T0147` | Unary minus on an unsigned operand (`Byte`, `UInt`, `ULong`, or a range over one), including a negated unsigned constant written in a range bound. No non-zero unsigned value has a negation of its own type, so `-(5u8)` used to wrap (#7854); convert a `Byte` first (`-(b.toInt())`), and give a value that can be negative a signed type |

### Type checker warnings (W-series)

| Code | Severity | Meaning |
|---|---|---|
| `W0002` | warning | A `forall`/`exists` in a contract of a runtime-checked package: its domain is a type, so it cannot be evaluated. The top-level `and`-conjunct containing it is skipped at runtime; the clause's other conjuncts are still checked. Put the property in a `@proof_required` package to have it proved. |
| `W0006` | warning | A `pub` function exposes an **imported nested** host extern type (a CLR FQN containing `+`, e.g. `System.Text.Json.JsonElement+ArrayEnumerator`) in its signature. Nested types are host implementation details meant to stay behind the `_kernel/` FFI boundary. A kernel file that declares the extern type locally is exempt. Fix: wrap the host type in an opaque Lyric type (as `Std.Json` does with `JsonArrayCursor` / `JsonObjectCursor`) instead of exposing it directly. Top-level domain extern types are not flagged. |
| `W0040` | warning | A `pub func` is left out of the `--shape module` JS glue because a parameter or its result is a type the module shape cannot carry (a record, list or option), or it is generic, overloaded, or takes an `out`/`inout` parameter. The function is still compiled; it just has no JS wrapper. |
| `W0041` | warning | A `pub async func` is exported from a `--shape component` build as a synchronous WIT function: the wrapper runs its task to completion, sleeping out its timers, so the host call blocks. Use the module shape for a non-blocking, Promise-returning export. |

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

### MSIL codegen diagnostics (F-series)

Compile-time-detectable codegen errors raised by the self-hosted MSIL
backend (`msil/codegen.l`, #4898): reported as positioned
`CodegenCtx.diagnostics` entries — the same convention the type-checker /
mode-checker / cfg-erasure diagnostic lists use — instead of an escaped
`panic`. The `F`-code prefix is shared with other, unrelated diagnostic
families (`docs/24-build-features.md`'s cfg-erasure codes, `docs/60-build-
defines.md`'s build-define codes, `docs/63-build-profiles-and-debugger.md`'s
profile/shape codes); see those docs for their own F-series ranges.

| Code | Meaning |
|---|---|
| `F0021` | External-interface `impl` block: an abstract interface method has no matching impl method. |
| `F0022` | External-interface `impl` block: an impl method's parameter count, or its Nth parameter type, does not match the interface's declared signature. |
| `F0023` | External-interface `impl` block: an impl method's return type does not match the interface's declared signature. |
| `F0024` | External-interface `impl` block: the `extern type` FQN does not resolve to any type in an indexed reference-pack or restored-dependency assembly (typically a typo); silently skipped only when the metadata index itself could not be populated (an SDK-less build). |
| `F0025` | `try`/`catch` used as an expression, where a catch arm yields `Unit` while the try body (or an earlier catch arm) already established a value-producing result type — the MSIL backend cannot route an absent value through the shared result slot (type-checker gap #2042; the JVM backend rejects the same shape at check time with `J004`). |
| `F0034` | External-interface `impl` block: the target resolves through `extern type` / `import extern`, but its .NET metadata is not an interface (e.g. `impl Math for Foo` against the class `System.Math`). Numbered `F0034`, not `F0020`, to avoid colliding with `propagate.l`'s pre-existing `F0020` (`?` used in a function returning neither `Result` nor `Option`) — see issue #6648. |
| `F0046` | A direct call to an `async func` inside a `try`/`catch`/`finally` of another `async func`, on `--target dotnet`: the call awaits in place, and a suspend point inside a protected region cannot be lowered. Await the call explicitly before or after the `try` block (#7838). |
| `F0047` | An untyped module-level `val` whose initializer's type (e.g. a call or numeric conversion) disagrees with the type the rest of the package was compiled against, on `--target dotnet`. Add an explicit annotation, `val x: Long = ...`. |

### Native codegen / build diagnostics (N-series)

Toolchain and (since #7585) compile-time-detectable codegen errors for
`--target native`, reported to stderr as `error[N0XXX] line:col: message`
and a non-zero exit — never an unhandled exception. `N0001`-`N0005` are
toolchain/environment failures with no meaningful source span (`line:col`
is omitted for these; they print as a bare `error[N0XXX]: message` line
instead, mirroring the `B0001` project-build-failure line), reported by
`Lyric.LlvmBridge` (`llvm_bridge.l`). `N0006` is a real source diagnostic
with a span, reported by a pre-pass over the file's interface
declarations that runs BEFORE codegen. `N0007` (#7452) is a codegen-time
type-mismatch `Bug` raised by `Lyric.LlvmCodegen`'s `coerceTo`
(`llvm_codegen.l`) and CONTAINED — never thrown to the CLI — by
`Lyric.Emitter`'s `emitNativeInProcess`/`emitNativeProject`
(`emitter.l`), the native twin of the `T0120`/`J008` catch-all boundary
`emitMsilInProcess`/`emitJvmInProcess` already had: a message with its
own embedded `error[N0007] line:col:` (the common case — every mismatch
reached through `lowerExprExpecting`, which has the argument/binop/branch
`Expr`'s real span) prints and keeps that span; any other native codegen
panic (including one from a call site `coerceTo` was not given a span
for) is wrapped under the same `N0007` code with a synthetic file-start
span, exactly like `T0120`/`J008`.

| Code | Meaning |
|---|---|
| `N0001` | `clang` was not found on `PATH` (for `--triple wasm32-wasi`: the wasi-sdk's `clang` under `$WASI_SDK_PATH` could not be run). |
| `N0002` | The generated LLVM IR (`.ll`) could not be written to disk. |
| `N0003` | `lyric_rt.a` (the native runtime archive) was not found; set `LYRIC_RT_PATH` or run `make -C lyric-rt`. |
| `N0004` | `clang` failed while compiling/linking the generated `.ll` file; its own stderr is included. |
| `N0005` | A native project build received no packages to compile. |
| `N0006` | An interface method's parameter or return type mentions `Self` NESTED inside a generic type argument (e.g. `List[Self]`, `Option[Self]`) — accepted on `--target dotnet`/`--target jvm`, but native's generic types monomorphize per concrete type argument and there is no call site to infer one from at an interface declaration. A BARE `Self` (a parameter, a return, or the implicit receiver's own type) is accepted on native too, since #7585 — only the nested shape is `N0006`. |
| `N0007` | A value flows into a codegen slot whose type it cannot be coerced to — most commonly a call argument against an extern generic collection method (`List[T].add`/`Map[K, V].add`, …) that the type checker admits with NO argument validation at all (an unresolved generic parameter is satisfied by any argument type on every target), so a genuinely incompatible argument (not a numeric narrowing — `coerceTo` narrows a wider `Int`/`Long` argument to a declared-narrower `Byte`/`Int` slot on its own, matching MSIL's implicit `List<byte>.Add` narrowing and JVM's `i2b`) reaches native codegen with no LLVM-IR-level conversion available. |
| `N0008` | Retired: generic protected types now build on `--target native` (D176). |
| `N0009` | A `--triple wasm32-wasi` build found no wasi-sdk; set `WASI_SDK_PATH` to its install directory. |
| `N0010` | An `extern func` signature (including a callback parameter or a return) names an inline `array[N, T]` or a by-value union, which have no C equivalent, or a by-value record on a target whose C struct ABI the native backend does not lower (x86-64, AArch64 and wasm32 are lowered, #8009; Windows triples are not). Pass a `NativePtr` (to an array's first element), or give the type its heap form. |
| `N0011` | `--shape module` or `--shape component` was given a triple that is not wasm32; pass `--triple wasm32-wasi`. |
| `N0012` | An unknown native output shape name reached the native bridge; the wasm32 shapes are `module` and `component`. |
| `N0013` | A generated file could not be written next to the `.wasm`: the `--shape module` JS glue (`<name>.js`) or declarations (`<name>.d.ts`), or the `--shape component` WIT (`<name>.wit`) or C wrappers (`<name>.cabi.c`). |
| `N0014` | A `@wasmImport` `extern func` has a parameter or result type the host import ABI cannot carry; use `Int`, `Long`, `Bool`, `Byte`, `Float`, `Double`, `String` or `Unit`. |
| `N0015` | A package declares a `@wasmImport` `extern func` but the build is not `--shape module`; only that shape can satisfy a host import. |
| `N0016` | A `--shape component` build could not run `wasm-tools`, or `$LYRIC_WASI_ADAPTER` (the preview1 reactor adapter) is unset or missing, or a `wasm-tools` step failed. |
| `N0018` | Generating the `--shape component` shims for a package failed: a `@wasmImport` extern with an unsupported type, a module or import name that is not a WIT identifier (a letter first, then letters, digits, `.`, `-`, `_`), or too many flat parameters. |
| `N0019` | `@wasmImport` externs conflict in a `--shape component` build: one host function (module and name) declared with different signatures, module or function names that fold to the same WIT name (`ui.log` and `ui-log`), or a module named like an exported package. |
| `N0020` | An `array[N, T]` reached `--target native` with no native layout: a length the type checker did not resolve to an integer, or an element type with no native lowering (D167). The checker rejects a non-constant length (T0160) first, so this is the backend's own check. |
| `N0021` | `--wit-out` or `--js-bindings` was given without `--shape component`, or the `--wit-out` path contains `;`. |
| `N0022` | `--js-bindings` could not run `jco` (`$JCO`, else `PATH`), or `jco transpile` failed. |

### Custom source generators (X-series)

Reported while a file's `@generate(Pkg.Name)` annotations run (docs/40, D150),
each at the annotation as `<file>: error[X000n] line:col: message`. All failing
annotations in a file are reported together.

| Code | Meaning |
|---|---|
| `X0001` | `@generate(Pkg.Name)` on something that is not a record, exposed record, opaque type, union, enum or interface. |
| `X0002` | The named dependency's manifest does not declare `kind = "source-generator"`. |
| `X0003` | The generator declares no `generate` entry point, or no `main` that calls `runGenerator(generate)`. |
| `X0004` | The generator returned code that does not parse; the message gives the line within the generated code. |
| `X0005` | The generator reported a diagnostic, shown with its own code. An `Error` fails the build; a `Warning` or `Info` is printed as `warning[X0005]` or `note[X0005]`. |
| `X0006` | A source-generator package is imported; it can only be used through `@generate`. |
| `X0008` | The generator is not declared in `[dependencies]`. |
| `X0009` | The generator could not be built or run: its build failed, it exited non-zero, wrote no or malformed JSON, ran longer than 60 seconds, or is a registry or git dependency (only `path` and `workspace = true` generators are supported). |

The first-party UI generators (D151) report their own codes under `X0005`:

| Code | Meaning |
|---|---|
| `FD001` | `@generate(Forms.Derive)` on something that is not a record or opaque type. |
| `FD002` | A field type a form cannot edit (a nested record, `List`, or a type declared in another file); annotate it `@form_parse(f)` and `@form_format(g)`. Also an optional `Bool`. |
| `FD003` | `@form_parse` without `@form_format`, or the reverse. |
| `FD004` | A generic type. |
| `FD005` | `@maxLength` on a field that is not text, or without its one argument. |
| `FD006` | No field the form can edit. |
| `RT001` | `@generate(Ui.Routes)` on something that is not a union, or on a union with no cases. |
| `RT002` | A case without `@path("/...")`, a path with a query or fragment, a literal segment outside letters, digits and `-._~`, or a `{field:Type}` whose type is not `String`, `Int` or `Long`. |
| `RT003` | A positional case field, a `{name}` that is no field of the case, or a field that is not in its path exactly once. |
| `RT004` | A field type a path segment cannot hold; name the segment's type, as in `{id:Long}`. |
| `RT005` | Two cases with the same path shape. |
| `RT006` | A generic union. |

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
| `V0014` | error | (mode checker) A spawned task is discarded: a `spawn` used as a statement is fire-and-forget. Bind the handle and `await` it inside the `scope { }` (D119 §7.4) |
| `V0032` | error | Contract clause (`requires:`/`ensures:`) on an `async func` or `yield`-bearing generator — the WP/SP calculus cannot model suspend/resume, so the verifier rejects the function rather than checking it against an unmodelled body. Move the contract to a synchronous core, or mark the package `@runtime_checked` |
| `V0033` | error | A proof obligation cannot be translated faithfully — an unsigned (`UInt`/`ULong`) operand beside a signed variable, a negative or too-wide constant used as an unsigned value, an unsigned negation, or a result range bound that is not a fitting literal. Add an explicit conversion or write the bound as a literal of the base type |
| `V0034` | error | (mode checker) `spawn` outside a `scope { }`. A spawned task must not outlive its scope, so every `spawn` sits lexically inside one in the same function or lambda body (D165, docs/68 §4). Wrap the `spawn` and its `await` in `scope { ... }` |

### Multi-file package diagnostics (B001x)

Reported against the file at fault (`<path>: error[B0013] line:col: ...`) before any backend runs; see docs/19.

| Code | Meaning |
|---|---|
| `B0013` | A file of a package declares another package (every file of a package declares that package). |
| `B0014` | Two files of a package disagree on a file-level annotation: different verification levels (`@runtime_checked`, `@proof_required`, `@axiom`), or one annotation with different arguments. (`@pure` in one file and `@io` in another is `Y0009`.) |

### NPM restore diagnostics (B006x)

| Code | Meaning |
|---|---|
| `B0060` | `lyric restore` could not install the `[npm]` packages: `npm install` exited non-zero or timed out, or a declared package is missing from `target/npm/node_modules/` afterwards. |
| `B0061` | A wasm32 project build found a package declared in `[npm]` with no shim under `_extern_npm/` (the build's own restore scaffolds one, so this is reported under `--no-restore`); run `lyric restore`. |
| `B0062` | A shim's `@wasmImport("npm:<package>")` binds a name the installed package does not export (or the package cannot be loaded under `node`); the message lists the exports it has. |
| `B0063` | A shim in `_extern_npm/` lost its `@axiom("from npm <name> ...")` header; restore will not treat it as the shim for that package. |
| `B0064` | A project package imports `@wasmImport("npm:<package>")` for a package `[npm]` does not declare. |

### Bench (B-series)

| Code | Meaning |
|---|---|
| `B0900` | File passed to `lyric bench` is missing the `@bench_module` annotation |
| `B0901` | `@bench_module` package declares a `func main()` — not allowed |
| `B0902` | No `@bench`-annotated functions found (or `--filter` matched none) |
