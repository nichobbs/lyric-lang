# 18 — Java Bytecode Emission Strategy

A Phase 6+ deliverable per `docs/05-implementation-plan.md` and decision-log
entry D023. v1 ships a .NET-only compiler; the JVM backend is a stretch
goal once the language is self-hosted.

This document specifies how Lyric source compiles to Java bytecode (the
class-file format defined by JVMS, Java 21 SE LTS).  The companion
document `docs/09-msil-emission.md` plays the same role for the MSIL
backend; readers are expected to be familiar with it.  Differences from
the MSIL strategy are flagged inline.

The emitter described here is also intended to be the **first major
application written in Lyric itself**.  Phase 5 ports the F# bootstrap
compiler to Lyric; the JVM emitter is greenfield Lyric code that exercises
every corner of the language under realistic conditions (binary I/O,
graph data structures, generic containers, contract-heavy data
modelling, async file emit, FFI to existing JVM tooling).  The
implementation plan in §23 is therefore as load-bearing as the lowering
strategy in §§4–22 — it is a stress test for the language, not just a
back-end project.

This document settles every Lyric → JVM mapping decision required for
implementation and flags those that defer (with a recommended default).
The Phase 6 implementer should not need to invent new design decisions
to start coding.


## 1. Design principles

The JVM strategy follows the same five priority axes as MSIL emission,
re-evaluated against the JVM's capabilities and constraints:

1. **Identity preservation under erasure.**  The JVM erases generic
   type parameters at the bytecode level: a method body sees `Object`
   where the source declared `T`.  Lyric's distinct types, range
   subtypes, and opaque types must nevertheless retain runtime identity
   — `UserId` and `OrderId` cannot collapse to `Long` at runtime, even
   though the JVM has no native distinct primitives.  This is the
   single largest divergence from the MSIL strategy and shapes nearly
   every other decision in this document.

2. **Boxed only when necessary.**  The JVM's primitive/object split is
   absolute in pre-Valhalla bytecode: a `long` cannot be a generic type
   argument.  We embrace boxing where required for generic identity,
   but emit unboxed primitives in straight-line monomorphic paths
   (range arithmetic, local arithmetic, intrinsics).  The JIT's escape
   analysis is the substitute for stack-allocated structs.

3. **Sealing via JPMS and class-file flags.**  The JVM's open-by-
   default reflection model is hostile to Lyric's opacity guarantees.
   We compensate with a layered strategy: name mangling, the
   `ACC_SYNTHETIC` flag, JPMS strong encapsulation, and refusal to
   `--add-opens` Lyric-emitted modules.  In trusted hosts (GraalVM
   native-image) we get the same guarantee as AOT'd MSIL.

4. **Java 21 LTS as the floor.**  Sealed classes (JEP 409), records
   (JEP 395), pattern switch (JEP 441), virtual threads (JEP 444), and
   structured concurrency (JEP 462, preview-then-stable) all matter.
   We do not support targeting JDK 17 or earlier; the lowering of
   sum types alone would degrade unacceptably.

5. **Boring lowering for everything else.**  Pattern match → sealed
   interface + `switch`.  Async → virtual thread for the default
   surface, `CompletableFuture` for `@hot`.  Tuples → records.
   Records → records.  Closures → lambda + `LambdaMetafactory`.
   Nothing exotic.

A sixth principle, specific to JVM:

6. **Self-hosted tooling.**  The class-file writer is itself a Lyric
   library.  We do not depend on ASM at runtime in shipped artifacts.
   Bootstrap may shell out to `javap` for diagnostics and to ASM (via
   JNI-style FFI) for stack-map-frame computation until the in-Lyric
   verifier is complete; both are removed before v2 release.


## 2. Compilation artifacts

### 2.1 Per-package outputs

For each package `P`, the JVM emitter produces:

- **`<P>.lyrjar`** — a JAR file (`.jar` is reserved for plain Java
  output; the `.lyrjar` extension distinguishes Lyric output to the
  build driver).  Contents:
  - `module-info.class` — the JPMS module descriptor (`requires`,
    `exports`, `opens`).
  - One `.class` per emitted top-level type (class, sealed interface,
    record, lambda host).
  - `META-INF/lyric/<P>.lyric-contract` — the public-surface JSON
    described in §2.2 of `docs/09-msil-emission.md`, embedded verbatim.
  - `META-INF/lyric/<P>.lyric-signatures` — a binary sidecar holding
    the `LyricSignature` attribute for each emitted member (see §10.4).

- **`<P>.lyric-contract`** — the same JSON manifest also written
  alongside the JAR for `lyric.toml`-driven incremental builds.

JAR metadata (`MANIFEST.MF`) carries:
- `Main-Class` (only on executable packages),
- `Multi-Release: false` (we target a single bytecode version per
  build),
- `Lyric-Lang-Version`, `Lyric-Package-Name`, `Lyric-Package-SemVer`,
  `Lyric-Manifest-SHA256` for incremental cache invalidation.

### 2.2 Module identity and naming

Each `.lyrjar` is a JPMS module:

- **Module name:** `lyric.<package-fully-qualified>` (e.g.
  `lyric.money`, `lyric.std.collections`).  Java module names are
  case-insensitive in some tools; we lowercase the Lyric package name
  for the module name and preserve case for the package's class
  namespace.
- **Package namespace:** `lyric.<package>` for emitted classes
  (e.g. `lyric.money.Cents`).  Sub-packages map to nested namespaces
  (`Account.Internal` → `lyric.account.internal`).
- **Module version:** the Lyric SemVer string, exposed on the
  `Module#getDescriptor().version()` API.
- **`exports` directives:** every `pub` type's containing namespace.
  Internal types live in non-exported sub-namespaces and are
  unreachable from other modules (subject to §7.2's reflection
  caveats).

The build driver also produces a `--module-path` layout suitable for
`java --module-path … --module lyric.<package>/<entry>` execution.

### 2.3 Class-file version

The class-file major version is 65 (Java 21).  Phase 6+ implementers
who want to support older runtimes should fork-and-downgrade rather
than pollute this spec; almost every decision below depends on a
Java-21-class JVM.


## 3. Packages map to modules; sub-packages to nested namespaces

A Lyric package compiles to *exactly one* JPMS module.  Sub-packages
compile to separate modules, mirroring the MSIL strategy's
"sub-packages are separate assemblies" rule.  This is more aggressive
than typical Java practice (where sub-packages live inside one JAR)
because Lyric's encapsulation story relies on the module boundary.

`@test_module` packages emit modules named
`lyric.<package>.tests`.  The test runner discovers them via the
`META-INF/services/lyric.testing.Discoverable` service-loader manifest;
this is the only `ServiceLoader` use in shipped Lyric output, and it
operates over compiler-emitted entries, never user code.


## 4. Primitive types

The Lyric primitives map onto JVM primitives and `java.lang` types as
follows:

| Lyric    | JVM bytecode type         | Box (when needed)        | Notes                                |
|----------|---------------------------|--------------------------|--------------------------------------|
| `Bool`   | `Z` (boolean)             | `java.lang.Boolean`      |                                      |
| `Byte`   | `B` (byte) — see below    | `java.lang.Byte`         | JVM `byte` is *signed*; see §4.4     |
| `Int`    | `I` (int)                 | `java.lang.Integer`      |                                      |
| `Long`   | `J` (long)                | `java.lang.Long`         |                                      |
| `UInt`   | `I` (int)                 | `java.lang.Integer`      | unsigned arithmetic via `Integer.divideUnsigned` etc. |
| `ULong`  | `J` (long)                | `java.lang.Long`         | unsigned via `Long.divideUnsigned`   |
| `Nat`    | `J` (long)                | `java.lang.Long`         | distinct identity via wrapper class (§6) |
| `Float`  | `F` (float)               | `java.lang.Float`        |                                      |
| `Double` | `D` (double)              | `java.lang.Double`       |                                      |
| `Char`   | `I` (int) — code point    | `java.lang.Integer`      | NOT `C`; see §4.3                    |
| `String` | `Ljava/lang/String;`      | (already a reference)    | UTF-16 in memory; UTF-8 at I/O       |
| `Unit`   | `Ljava/lang/Void;` for return values; absent otherwise | — | see §4.5 |
| `Never`  | (no JVM type)             | —                        | functions returning `Never` emit `void` plus a final `athrow` |

### 4.1 Overflow semantics

Reference §2.1 mandates:
- *Checked builds (`--debug`)*: every arithmetic operation on an
  unconstrained primitive panics on overflow.
- *Release builds*: operations on unconstrained primitives wrap;
  operations on range subtypes always panic.

The JVM has no native overflow-trapping integer arithmetic for `int`
and `long` (unlike CIL's `add.ovf`).  We therefore emit overflow
checks as **explicit comparisons** before/after the arithmetic:

- Checked `int + int`: `Math.addExact(int, int)` (throws
  `ArithmeticException`, which the runtime bridges to
  `Bug(IntegerOverflow)` per §20.4).
- Checked `long + long`: `Math.addExactLong(long, long)`.
- Release, unconstrained: plain `iadd` / `ladd`.
- Range subtype: always `Math.*Exact` followed by an in-range check
  against the type's interval (§7.3).

Division by zero traps natively (`ArithmeticException`); the runtime
bridges to `Bug(DivisionByZero)`.

### 4.2 IEEE 754

`Float` and `Double` follow IEEE 754-2019.  The JVM's `fcmpg`/`fcmpl`
opcodes give us NaN-tolerating comparisons; the emitter chooses
`fcmpg` (NaN → 1) or `fcmpl` (NaN → -1) per Lyric's mandated NaN
behaviour, matching the JLS §15.20.1 rules that Java itself uses for
`<` and `<=`.

### 4.3 `Char` is a code point, not a UTF-16 code unit

Lyric `Char` is a Unicode scalar value (per language reference §2.1
and decision-log D027); the JVM `char` type is a UTF-16 code unit
that can be a surrogate half.  We refuse to map Lyric `Char` to JVM
`char`.  Instead `Char` is `int` (code point), and any interaction
with `java.lang.String` goes through `String.codePointAt`/
`String.codePointCount` rather than `charAt`.  An FFI conversion
helper `Char.toUtf16Pair(c): (Char, Char?)` is provided in
`lyric.std.text.unicode` for code that genuinely needs the surrogate
pair (rare).

### 4.4 `Byte` and the JVM signed-byte trap

JVM `byte` is signed (`-128..=127`); Lyric `Byte` is unsigned
(`0..=255`).  The emitter encodes `Byte` using JVM `int` for arithmetic
(treating the upper 24 bits as zero) and `byte` (signed) only at
storage boundaries (`bastore`, `baload`, byte-array fields).  Writes
go through `(byte) (i & 0xFF)`; reads go through `b & 0xFF`.  This
matches the Java-side idiom for unsigned-byte handling.

### 4.5 `Unit` and `Void`

The JVM has no zero-arity tuple type.  We use:
- `Unit`-typed *return*: emit `void` (no return value pushed).
- `Unit`-typed *parameter or generic argument*: box to
  `java.lang.Void` (always `null`-valued, immutable, unique).
- `Unit`-typed *local*: never emitted; the back-end pretends the
  binding does not exist after lowering.

`java.lang.Void` is the canonical JVM marker for "no value"; its only
field is `null`, which is exactly the semantics we want.  This is
ECMA-equivalent to using `System.ValueTuple` on .NET, with the cost
that `Void` is a reference type and `Unit` in generic position will
be a heap reference.  We accept this — the cost is paid only at
generic-instantiation boundaries, not in straight-line code.

### 4.6 `String` interning and equality

`==` on `String` lowers to `String.equals` (not `acmp_eq` /
`if_acmpeq`).  Reference equality is not exposed at the language
level.  The JVM string pool is irrelevant to Lyric semantics; whether
a literal is interned is an implementation detail.


## 5. Records

### 5.1 Lowering shape

A Lyric `record T { f1: T1, ..., fn: Tn }` lowers to a Java record
(JEP 395):

```
public final record T(T1 f1, ..., Tn fn) implements LyricRecord { … }
```

Java records are final, structurally equal, and carry compiler-
generated `equals`, `hashCode`, and `toString`.  This matches Lyric's
record semantics nearly exactly and saves us from the "manually emit
equality / hashCode" bootstrap burden the MSIL backend carries.

`LyricRecord` is a marker interface in `lyric.runtime` carrying the
`@LyricRecord` annotation; it lets tooling (debugger, LSP) distinguish
Lyric records from arbitrary Java records.

### 5.2 No `readonly struct` heuristic

The MSIL strategy splits records by a 16-byte heuristic between
`readonly struct` (stack-friendly) and `record class` (heap-friendly).
The JVM has no analogue: every record is a heap object.  We therefore
**reject the `@valueType` annotation on the JVM backend** with a
`backend mismatch` diagnostic.  The build driver emits a hint pointing
at Project Valhalla as the eventual fix; until Valhalla ships in an
LTS, the JIT's escape analysis is the only mitigation.

The `@referenceType` annotation is silently no-op on JVM (records are
already reference types).

### 5.3 Field layout

Java records lay out fields in declaration order; the JVM does not
expose layout hints for records.  Where FFI requires explicit layout,
the user must drop down to a non-record class plus the
`jdk.internal.foreign.MemoryLayout` API via FFI — the same boundary
the .NET strategy carries to `[StructLayout]`.

### 5.4 Equality, hashing, `copy`

Java records auto-generate `equals` and `hashCode`; we lean on them
unchanged.  The non-destructive `copy(field = e)` method is emitted as
a generated instance method that calls the canonical constructor with
the named field overridden:

```java
public T copy_f1(T1 f1$new) { return new T(f1$new, this.f2, ..., this.fn); }
public T copy_f2(T2 f2$new) { return new T(this.f1, f2$new, ..., this.fn); }
…
public T copy_(T1 f1$new, T2 f2$new, …) { return new T(f1$new, f2$new, …); }
```

The variadic `copy_` form supports multi-field updates without
exposing every combination as a separate method.  Lyric source-level
`r.copy(f1 = a, f3 = b)` lowers to the variadic form.

### 5.5 Default values

A record field with a default value emits a static factory:

```
public static T withDefaults() { return new T(default_f1(), …); }
public static T withDefaults(T1 f1) { return new T(f1, default_f2(), …); }
```

The factories cover every prefix-of-required-fields combination — the
same monomorphisation the MSIL backend does via overload-pairs.  For
records with many defaulted fields, this can produce many factories;
the build driver caps the number at 32 and emits a diagnostic
recommending an explicit builder for higher arities.

### 5.6 Records as canonical sealed-hierarchy leaves

A Lyric record that is a variant of a `union` (§9) is emitted *also*
as a record but additionally `implements` the parent sealed interface.
A single record class can therefore live in two roles: standalone
record, and union variant.  This is the same lowering Java itself
recommends for algebraic data types in the JEP 409 design discussion.


## 6. Distinct types and range subtypes

### 6.1 The erasure problem

This is the section that diverges most sharply from the MSIL strategy.
On .NET we lower `type UserId = Long` to a `readonly struct UserId`
that lives unboxed in calling conventions and on the stack.  On the
JVM, no such option exists: a generic-position `UserId` is `Object`,
which means the wrapper *must be a class*, which means it allocates.

We accept the allocation as the cost of doing business on a JVM.  The
JIT's escape analysis recovers most of the cost in straight-line code;
generic-position uses pay the heap-allocation cost honestly.

### 6.2 Lowering shape

A distinct type or range subtype lowers to a Java record with a single
component:

```java
@LyricDistinct(underlying = "Long")
public final record UserId(long $value) implements Comparable<UserId> {
    public long toLong() { return $value; }
    // generated equality (free, by record), hashing (free), comparison per derives
}
```

Three observations:

1. The component name is `$value` — illegal in Java source, legal in
   class-file form.  This makes the underlying field unforgeable from
   Java code (you can't write `r.$value`).  Reflection still sees it
   in non-modular hosts; §7.2 covers the sealing strategy.
2. The component type is the *unboxed* JVM primitive (`long`, `int`,
   `double`, …).  Java records permit primitive components, and the
   single-field record gets aggressive JIT inlining via record's
   automatic `MethodHandle`-friendly accessors.
3. The record `implements Comparable<Self>` only when `Compare` is
   derived, and so on for each marker — we don't pay for derives we
   don't need.

The `@LyricDistinct` annotation is `RetentionPolicy.CLASS` (visible to
tooling, invisible to runtime reflection).

### 6.3 `derives` clauses

Markers map to generated members exactly as in MSIL §6.2, except
operators are method-named rather than operator-overloaded (the JVM
has no operator overloading).  The Lyric front-end already lowered
`a + b` to a method call by the time the JVM emitter sees it; the
emitter just picks the right method name:

| Marker     | Generated members                                            |
|------------|--------------------------------------------------------------|
| `Add`      | `T plus(T)` (static `T zero()` if `Default` also derived)    |
| `Sub`      | `T minus(T)`; `T negate()` if underlying is signed           |
| `Mul`      | `T times(T)`                                                 |
| `Div`      | `T dividedBy(T)`                                             |
| `Mod`      | `T mod(T)`                                                   |
| `Compare`  | `Comparable<T>`, `int compareTo(T)`                          |
| `Hash`     | `int hashCode()` (records already auto-generate; we override only when underlying needs unsigned hashing) |
| `Equals`   | (records auto-generate)                                      |

A type without any `derives` is *opaque to operators* — only
`toLong()` (or analogous) is exposed.

The naming follows Kotlin's operator convention (`plus`, `minus`,
`times`) rather than Scala's symbolic methods, because Kotlin's
convention is the better-known one in the Java ecosystem and pairs
cleanly with Kotlin/Lyric interop.

### 6.4 Range checks at construction

Range subtypes carry an interval `[lo, hi]`.  Two construction paths:

- **`tryFrom(long value): Result<T, RangeError>`** — checked, returns
  `Err` on out-of-range.  Static method on the wrapper.
- **`from(long value): T`** — panicking, raises `Bug(IntegerOverflow,
  "T")` on out-of-range.

Both are static methods.  Inside the same module, an *unchecked*
package-private constructor is exposed:

```java
T(long $value, lyric.runtime.Unchecked $witness)
```

The `Unchecked` witness is a non-instantiable type whose only field
is a private constant; only code in the same module can produce it.
This is the JVM analogue of the MSIL strategy's
`[EditorBrowsable(Never)]` + Lyric-internal modifier; cross-module
abuse is prevented by the JPMS `exports … to lyric.runtime` directive
(or by being non-exported altogether).

### 6.5 Arithmetic and bound preservation

`Cents + Cents → Cents` invokes the generated `Cents.plus(Cents)`
method.  The implementation chooses one of three strategies depending
on the build mode:

- *Debug*: `Math.addExactLong(a, b)` plus `Cents.from(...)` (panicking
  on out-of-range).
- *Release with proof*: when the function lives in a
  `@proof_required` module and the prover discharges the in-range
  obligation, emit just `ladd` (no overflow check, no bounds check)
  followed by the unchecked constructor.
- *Release without proof*: `Math.addExactLong` plus `Cents.from`,
  with the resulting violation classified as a `Bug` rather than
  recoverable.

### 6.6 Conversions

All conversions are explicit:

- `T.toLong()` (or analogous `toInt`, `toDouble`) — extract the
  primitive value, by accessor on the record component.
- `Long.toUserId(x)` — only emitted when explicitly declared (e.g.
  `derives From[Long]`, deferred to v2).
- `T.tryFrom(underlying)` — `Result`-returning checked construction.

There are no implicit conversions.

### 6.7 Generic position and boxing

When a distinct type appears in a generic position (e.g.
`List<UserId>`), the JVM erases the type parameter to `Object`.  The
record wrapper is already a reference type, so this is free — `UserId`
flows as `Object` through the generic body and downcasts at use sites.
This is the same shape Java itself uses for boxed primitives in
generics; Lyric's distinct-type wrapper *replaces* the primitive box,
so we do not double-wrap.

This is, in practice, a uniform improvement over straightforward
`Long`-in-generic position: a `List<UserId>` heap-allocates one
`UserId` per element, exactly as `List<Long>` heap-allocates one
`Long` per element.  We do not pay an extra layer.


## 7. Opaque types

### 7.1 Lowering form

An `opaque type T` whose body is `record { f1: T1, ..., fn: Tn;
invariant: φ }` lowers to a final non-record class (records would
expose accessors automatically — undesirable for opaque types):

```java
@LyricOpaque
public final class T {
    private final T1 $f1;
    private final T2 $f2;
    ...
    T(T1 $f1, T2 $f2, ...) { this.$f1 = $f1; ...; assertInvariant(); }
    // generated equality if @derive(Equals); no auto-generation here
}
```

Three differences from a plain record:

1. Fields are emitted with a *mangled* name (`$<field>`) — illegal in
   Java source, legal in class-file form.  Java cannot reference
   identifiers starting with `$` followed by an alphabetic character
   without warnings, and the JLS reserves `$`-prefixed names for
   compiler use; reflection from Java source is awkward but possible
   (see §7.2).
2. The class is `final`, has no accessors, and is annotated
   `@LyricOpaque` for tooling.
3. The constructor and any field-mutation methods are
   *package-private* (not `public`); cross-module construction goes
   through the package's exposed `pub` constructor functions, which
   live in the same module and can call the constructor.

### 7.2 Reflection sealing

The JVM's reflection model is more permissive than .NET's.  We layer
five mechanisms; the strength of the guarantee depends on the
deployment mode:

1. **Mangled field names** as above.  Defeats accidental reflection;
   does not defeat determined reflection.
2. **`ACC_SYNTHETIC` flag** on the field.  Java's reflection API
   treats synthetic members as compiler-generated; tools that respect
   the flag (debuggers, IDEs) hide them.  `Field.isSynthetic()`
   returns `true`.
3. **JPMS strong encapsulation.**  The opaque type lives in a
   non-exported package; any reflection from outside the module
   requires `--add-opens lyric.<pkg>/<package>=ALL-UNNAMED` at JVM
   launch.  We document this prominently: a host that adds the open
   has explicitly opted out of the opacity guarantee.
4. **`@LyricOpaque` annotation** that build-time linters and the
   GraalVM native-image agent respect.  Code that targets a
   `@LyricOpaque`-marked class via `Field.setAccessible(true)`
   produces a `LyricSealing` warning under the Lyric build driver
   and a hard error under `lyric publish --aot`.
5. **GraalVM native-image strong sealing.**  In native-image mode,
   reflection over `@LyricOpaque` fields requires a
   `reflect-config.json` entry, which the Lyric driver refuses to
   generate.  This is the AOT-grade guarantee, equivalent to the
   strongest MSIL story.

In an ordinary `java` launch with default flags, reflection over
private fields *is* possible.  The language reference documents this
caveat: the full opacity guarantee on JVM requires either GraalVM
native-image, or a JPMS-strict launch (no `--add-opens`).  The Phase 6
implementer must surface this in `lyric build --target=jvm`'s help
text.

### 7.3 Projectable opaque types (`@projectable`)

Identical to MSIL §7.3 in user-visible behaviour.  The generated
`TView` is a public record (§5.1 lowering); the projection function
`T.toView(): TView` and the reverse `TView.tryInto(): Result<T,
ContractViolation>` are emitted alongside the opaque class.
`@projectionBoundary` enforcement is unchanged.

### 7.4 Construction inside the package

The package author writes `pub func make(...): T`.  Inside the
package, the type's package-private constructor is reachable.  Outside
the package (and especially outside the module), only the `pub func`
factory is reachable.  We *do not* expose a `T(...)` constructor for
opaque types as part of the public API; the JPMS `opens` clause
excludes the constructor.


## 8. Sum types and enums

### 8.1 Union (sum) lowering

A `union T { case A(...), case B(...) }` lowers to a Java sealed
interface plus per-variant records:

```java
public sealed interface T
    permits T.A, T.B
    extends LyricUnion {

    record A(U1 field1, U2 field2) implements T { }
    record B(V1 field1)             implements T { }

    int $tag();
    static T A(U1 f1, U2 f2) { return new A(f1, f2); }
    static T B(V1 f1)         { return new B(f1); }
}
```

Java sealed interfaces (JEP 409) give us:
- exhaustiveness checks via `switch` patterns (§14),
- closed extension at the bytecode level (`PermittedSubclasses`
  attribute carries the variant set),
- structural equality on each variant (records).

The `$tag()` discriminator method is *not strictly required* for
exhaustive `switch` patterns, but we emit it because:
- it accelerates the bytecode-level `tableswitch` that pattern-switch
  lowers to (the JVM JIT specialises tag-based dispatch),
- it's the canonical way for FFI-bound code to query the variant
  without reflection.

### 8.2 Variant-free unions vs. enums

A `union` with all payload-free variants stays a sealed interface
(future variants might add payload).  An `enum` declaration lowers to
a JVM `enum`:

```java
public enum Color { RED, GREEN, BLUE }
```

The values are case-renamed to upper-snake-case to match Java
convention (the formatter already enforces `UpperCamelCase` source-
side, but JVM enums conventionally use `SCREAMING_SNAKE`; we follow
the convention to make Java interop smooth).  `Color.RED` is the JVM-
side identifier; Lyric source `Color.Red` continues to work
transparently.

### 8.3 Generics in unions

`union Result[T, E] { case Ok(T), case Err(E) }` lowers to:

```java
public sealed interface Result<T, E> permits Result.Ok, Result.Err {
    record Ok<T, E>(T value) implements Result<T, E> { }
    record Err<T, E>(E error) implements Result<T, E> { }
}
```

JVM generics are erased: `Result<UserId, OrderError>` is the same
runtime class as `Result<OrderId, OrderError>`.  The distinct-type
identity is preserved by the *value* (each `UserId` is its own
wrapper) but lost at the *type* level — `instanceof Result<UserId,
?>` is not expressible.

This is the core erasure tax we pay on the JVM.  §10 details the
mitigations (`LyricSignature` attribute, witness-based runtime checks
for code that needs them).

### 8.4 Adding a variant is a breaking change

Adding a `case` to a `pub union` changes the sealed interface's
`PermittedSubclasses` attribute, which is a JLS-level binary-
incompatible change (any pattern switch in a downstream module would
need recompilation to retain exhaustiveness).  `lyric public-api-diff`
flags it as SemVer-major, identical to the MSIL behaviour.


## 9. Exposed records

`exposed record T` lowers to a public Java record (the same lowering
as §5.1), with three differences:

1. The class is *not* annotated `@LyricRecord`.  Instead it is
   annotated `@LyricExposed`, which tooling (and the
   `lyric public-api-diff` engine) treats as part of the package's
   wire-level surface.
2. Field names are *not* mangled.  Java source can reference
   `record.field()` directly.
3. The containing JPMS package is `exports` (no `to <module>`
   restriction), and the JPMS `opens` clause is included so that
   Jackson, Hibernate, etc. can reflect over fields.  The
   `META-INF/lyric/opaque-fences` sidecar lists the opaque types whose
   reflection is still forbidden, so the strong sealing in §7.2 is
   preserved.

`@derive(Json)`, `@derive(Sql)`, `@derive(Proto)` are processed at
compile time by source generators; the emitter's role is just to drop
the generator-produced classes alongside the user's classes in the
same module.  Java records are first-class supported by Jackson 2.12+
and by Avro/Protobuf code-gen tooling, so the JVM ecosystem is friendly
here.


## 10. Generics

This is the second-largest divergence from the MSIL strategy
(after §6).  MSIL gets reified generics from the CLR for free; the
JVM erases.  This section describes how Lyric preserves the
*language-level* identity of distinct types under JVM erasure, even
though the *runtime-level* identity at the type-parameter slot is
lost.

### 10.1 Erasure model

A Lyric `func[T] f(x: T): T` lowers to:

```
public static <T> T f(T x);   // signature attribute carries the type parameter
```

In bytecode, `T` erases to `Object` for the method descriptor; the
class-file `Signature` attribute (JVMS §4.7.9) carries the generic
form for tooling and source-level languages (Lyric, Java, Kotlin,
Scala) to read.

Lyric's existing front-end already monomorphises generics into
specialised typed AST nodes (per `docs/03-decision-log.md` D035 and
§9 of `09-msil-emission.md`).  The JVM emitter keeps the same lowered
AST and emits:

- **One generic class file** per generic source declaration.  This is
  the canonical erased form.
- **Zero specialised class files** per instantiation.  We rely on JVM
  erasure rather than emitting per-instantiation copies.

This is an explicit reversal of the MSIL strategy's "per-
instantiation method bodies for value-type parameters."  The JVM
makes this impossible (or rather, Valhalla-dependent); we accept the
boxing cost.

### 10.2 Specialised dispatch helpers

For instantiations the front-end has identified as performance-
critical (`@hot` annotation, or the prover-discharged loop bodies in
proof-required code), the back-end *may* emit a specialised
*helper* class:

```java
@LyricSpecialisation(method = "lyric/std/collections/List#sum",
                      witness = "lyric/money/Cents")
final class lyric$std$collections$List$sum$Cents {
    public static Cents apply(List<Cents> xs) { … unboxed long arithmetic … }
}
```

The decision is per-call-site; the build driver records the
specialisation choice in the `<P>.lyric-signatures` sidecar so that
downstream incremental builds know to keep or discard the helper.
No source-level Lyric construct triggers specialisation directly; it
is a pure optimisation.

### 10.3 Marker constraints (`where`)

The closed marker set (D034) has the following JVM lowering:

| Marker     | JVM constraint                                            |
|------------|-----------------------------------------------------------|
| `Equals`   | (no constraint; everything has `Object.equals`)            |
| `Compare`  | `T extends Comparable<T>`                                  |
| `Hash`     | (no constraint; everything has `Object.hashCode`)          |
| `Default`  | runtime witness `LyricDefault<T>` parameter (see §10.4)    |
| `Copyable` | (no constraint; the language guarantees value semantics)   |
| `Add`      | runtime witness `LyricArith<T>` parameter                  |
| `Sub`      | runtime witness `LyricArith<T>` parameter (same shared type with explicit method) |
| `Mul`      | runtime witness `LyricArith<T>` parameter                  |
| `Div`      | runtime witness `LyricArith<T>` parameter                  |
| `Mod`      | runtime witness `LyricArith<T>` parameter                  |

`Compare` is the only marker that maps cleanly to a CLR-style
constraint, because Java has `Comparable<T>` natively.  The arithmetic
markers and `Default` cannot — Java has no arithmetic interface
hierarchy — so they are passed as **type-class witnesses** at the
bytecode level: a hidden parameter of type `LyricArith<T>` (or
`LyricDefault<T>`) is added to every generic method that requires the
marker, and the front-end synthesises the appropriate witness instance
at the call site.

This is the same trick the Scala compiler uses for its type-class
encoding, except we generate the witness mechanically rather than
exposing it as user-visible source.  Witness synthesis runs on the
already-monomorphised AST: by the time the back-end sees `f[Cents]`,
the front-end has resolved `Cents` to `Cents$Arith` (a generated
companion class) and emitted the witness constant.

### 10.4 The `LyricSignature` attribute

Class files carry an extra `LyricSignature` attribute (JVMS §4.7
extension; vendor-specific attributes are permitted).  This attribute
carries the *full* Lyric type signature — distinct types, range
bounds, generic constraints, contract clauses — that erasure would
otherwise discard.  Consumers:

- The Lyric LSP for JVM-targeted projects.
- The Lyric proof system, if invoked across module boundaries.
- The `lyric public-api-diff` tool when comparing JVM artefacts.
- Other JVM-hosted Lyric-aware tooling.

The attribute payload is a length-prefixed UTF-8-encoded
representation of the same syntax tree the `lyric-contract` JSON
serialises.  Standard Java-only consumers ignore the attribute (per
JVMS §4.7.1's mandate that unknown attributes are silently skipped).

### 10.5 Value generics

Lyric `generic[T, N: Nat] record FixedVec` is non-trivial on a JVM
without integer generics.  We use the same phantom-marker-class trick
the MSIL strategy uses, except every marker is necessarily a
reference type:

```java
public final class N_42 implements LyricNatTag {
    public static final long VALUE = 42L;
    public static long value() { return VALUE; }
}
```

`FixedVec<T, NTag>` takes the phantom type parameter, and references
to `N` in the body lower to `NTag.value()`.  JIT inlining gets us
back to a constant.

For the bootstrap, the emitter generates `N_<value>` classes lazily,
on first reference, and caches them per package.

### 10.6 Variance

Lyric is invariant on user-declared generics (`docs/03-decision-log.md`
D-progress-XXX); we lower with no `? extends` / `? super` wildcards on
declarations.  Use sites that need variance go through the language's
explicit upcast operator, which lowers to a Java-level wildcard at the
bytecode boundary.


## 11. Functions, parameter modes, closures

### 11.1 Function lowering

A regular `func` lowers to a `public static` method on a generated
class named `<package>$Funcs` (mirroring the MSIL convention).  The
class is `final`, has a private no-arg constructor, and lives in the
package's namespace.

There is no top-level method support in JVM bytecode; every method
lives on a class.

### 11.2 Parameter modes — `in` / `out` / `inout`

The JVM has no native `in`/`out`/`inout` parameter conventions.  Lyric
lowers them with explicit boxing:

| Mode    | JVM convention                                              |
|---------|-------------------------------------------------------------|
| `in`    | by-value for primitives; by-reference for objects (the JVM's only convention) |
| `out`   | a single-element array `T[]` of length 1 — caller passes a fresh array, callee assigns to `arr[0]` |
| `inout` | the same single-element array convention, with the array pre-populated |

The single-element array is the canonical Java idiom for
out-parameter simulation (used in `java.lang.ref` and `java.util`
internals).  We considered `Cell<T>` (a generated wrapper class) and
`AtomicReference<T>`; `T[]` of length 1 wins because:
- it costs one allocation (same as a `Cell`),
- the JIT specialises array element access well,
- it preserves the underlying primitive type (`long[]` for
  `out Long`), avoiding box-then-unbox.

Front-end mode-checking (definite assignment for `out`,
mutability for `inout`) runs unchanged on the AST; the back-end's
only role is the array-allocation prelude and the indexed
assignment for body operations.

### 11.3 Closures and lambdas

A closure `{ x: Int -> x + n }` lowers via `LambdaMetafactory` (the
standard Java 8+ mechanism):

- The closure body becomes a `private static` synthetic method on the
  enclosing class, taking the captured values as leading parameters.
- A `invokedynamic` instruction at the closure-creation site calls
  `LambdaMetafactory.metafactory` with the appropriate functional
  interface and the synthetic method handle.
- Captured values are partial-applied at the `invokedynamic` callsite.

For Lyric's closure shapes (`func[A, R](x: A): R`, etc.), the back-
end emits or reuses a small set of **generated functional interfaces**
in `lyric.runtime.functions`: `LFun0<R>`, `LFun1<A,R>`, `LFun2<A,B,R>`,
…, plus primitive-specialised variants (`LFun1IL` for `int -> long`,
`LFun1JD` for `long -> double`, etc.) to match Java's
`java.util.function` specialisation pattern.

`var`-capture rules (Q007) apply unchanged: a captured `var` is
snapshot-by-value at closure creation; capturing a `var` for write-
back across an async boundary is a compile error.  The captured-by-
value semantics is automatic on the JVM because `LambdaMetafactory`
captures by value at the call site.

### 11.4 `inout` and async

Per Q005, `inout` parameters used after an `await` are rejected at
compile time.  No special back-end handling.

### 11.5 Default parameter values

Java has no native default parameter values.  Lyric default parameters
lower to **method overloads**:

```java
// public func draw(x: Int = 0, y: Int = 0, c: Color = Color.Black)
public static void draw(int x, int y, Color c) { … real body … }
public static void draw(int x, int y) { draw(x, y, Color.BLACK); }
public static void draw(int x) { draw(x, 0); }
public static void draw() { draw(0); }
```

For `n` defaultable parameters this generates `n + 1` overloads,
identical to the MSIL emission's "overload pair" strategy except
generalised.  Same 32-overload cap as §5.5; over the cap the
back-end refuses to emit and the front-end recommends a builder.


## 12. Compile-time constants

Constants emit as `public static final` fields on `<package>$Consts`,
initialised in the class's `<clinit>` method.  Java's class-load
semantics (lazy initialisation per JVMS §5.5) gives us "evaluated
once per JVM" for free.  Where the constant is a numeric or string
literal computable at emit time, the constant is folded directly into
the `ldc` operand at every use site (the `<clinit>` field is still
emitted for reflection and `lyric public-api-diff` consumption, but
the field itself is rarely read at runtime).


## 13. Pattern matching

### 13.1 Lowering shape

Java 21 introduced pattern switch (JEP 441), which is the natural
target.  A Lyric `match e { case ... }` lowers to a Java
`switch (e) { case ... }` expression with type patterns and record-
deconstruction patterns.  For union types whose lowering is the
sealed-interface form (§8.1), the JVM verifier and the JIT both
recognise the pattern as exhaustive and dispatch via
`tableswitch`-equivalent codegen.

```java
// match shape { case Circle(r) -> 3.14159*r*r; case Rectangle(w,h) -> w*h }
return switch (shape) {
    case Shape.Circle(double r) -> 3.14159 * r * r;
    case Shape.Rectangle(double w, double h) -> w * h;
};
```

The bytecode is a `invokedynamic` against
`SwitchBootstraps.typeSwitch`, the same shape Java's own pattern
switch lowers to.  Lyric does not invent a new dispatch mechanism; we
lean on the JVM's bootstrap-method infrastructure exactly as Java's
own compiler does.

### 13.2 Exhaustiveness

The semantic analyser confirms exhaustiveness; the JVM emitter
assumes it and emits no fallthrough default.  If a type-tested
dispatch reaches the end without matching (which can only happen
if a downstream module added a variant we didn't know about — a
binary-incompatible change), `MatchException` is thrown by the
bootstrap, and the runtime bridges it to a `Bug(NonExhaustiveMatch)`.

### 13.3 Guards (`where` / `if`)

Java pattern switch supports guards (`when`) directly:

```java
case Shape.Circle(double r) when r > 0 -> 3.14159 * r * r;
```

We emit them verbatim.

### 13.4 Range and literal patterns

Java 21's pattern switch does not yet support range patterns or
literal patterns directly (JEP 441 calls these out as future work,
JEP 488 added them in Java 23 as preview).  For Java 21 targeting,
we lower these to guards on a binding pattern:

```java
// case 0..=9 -> ... lowers to:
case Integer i when i >= 0 && i <= 9 -> ...
```

For string-literal patterns, the back-end emits
`String.equals` guards (Java's own `switch` on String is also
hash-then-equals at the bytecode level).

### 13.5 Record-shape patterns

`Point { x = 0.0, y }` lowers to a Java record-deconstruction
pattern with a guard on the bound `x`:

```java
case Point(double xVal, double y) when xVal == 0.0 -> body
```

This is exactly how Java's own pattern switch handles records, so
no novel emission is required.


## 14. Async functions

The async story diverges meaningfully from MSIL because the JVM has
two viable async substrates:

- **Virtual threads** (JEP 444, stable in Java 21): a synchronous
  programming model that *looks like* blocking, but the platform
  scheduler parks the carrier thread on `Thread.sleep`,
  `Future.get`, I/O, etc.
- **`CompletableFuture<T>`**: the .NET-`Task<T>` analogue, with a
  callback-based completion model.

Lyric chooses **virtual threads as the default** and `CompletableFuture`
for `@hot` paths.  This inverts the MSIL strategy's defaults
(MSIL: `Task<T>` default, `ValueTask<T>` for `@hot`) and is justified
by the Java ecosystem's ongoing migration toward virtual-thread-first
service code.

### 14.1 Default lowering: virtual threads

An `async func f(...): T` lowers to a synchronous `T f(...)` on the
JVM, and *callsites* spawn a virtual thread when needed:

```java
// async func loadUser(id: UserId): User?
public static Optional<User> loadUser(UserId id) {
    // ... ordinary synchronous body, with `await` lowered to direct calls ...
}
```

`await callee()` inside an async function is **a no-op at the
bytecode level** — the call is direct, and the platform's virtual-
thread scheduler handles parking on I/O.  This is the radical
simplification Loom enables: async code looks like sync code.

The Lyric compiler does *not* compile async functions to a state
machine on the JVM.  This is the most important divergence from MSIL
emission.  The cost is that integrating with `CompletableFuture`-
heavy Java libraries requires an explicit bridge (§14.4); the benefit
is dramatically simpler bytecode and stack traces.

### 14.2 `@hot` lowering: `CompletableFuture<T>`

For functions annotated `@hot`, the back-end falls back to a
`CompletableFuture<T>`-shaped lowering:

```java
public static CompletableFuture<User> loadUser$hot(UserId id) { … }
```

`await` inside a `@hot` function lowers to `CompletableFuture.thenCompose`
chains, with a small state-machine translation similar to what
javac's *unfinished* loom-and-cooperative-suspend mechanism would
produce.  The translation is mechanical and follows the standard
"continuation-passing transform" recipe documented in Kawaguchi 2002
and the Kotlin coroutine compiler's transform.

The two lowerings are *not* mutually compatible.  A `@hot` async
function called from a non-`@hot` context bridges via:

```java
result = loadUser$hot(id).join();  // blocks the virtual thread
```

The `join()` works correctly under virtual threads because the
carrier thread is parked, not blocked.

### 14.3 The implicit `cancellation` parameter

Every `async func` carries an implicit `cancellation` parameter.  On
the JVM we map it to a hidden `LyricCancellation` parameter (a thin
wrapper around `Thread.currentThread().isInterrupted()` for virtual-
thread-default code, and around an explicit token for
`CompletableFuture` code).

`cancellation.checkOrThrow()` lowers to:
```java
LyricCancellation.checkOrThrow(token);   // throws Bug(Cancelled) if cancelled
```

For virtual-thread-default code, the implementation is just
`if (Thread.interrupted()) throw new Bug.Cancelled();`.  This means
any blocking JDK call that respects interruption (`Thread.sleep`,
`Object.wait`, `Lock.lockInterruptibly`, `InterruptibleChannel`) is
automatically a cancellation point — a free benefit of virtual
threads.

### 14.4 Cross-package and Java-interop async

Java code typically returns `CompletableFuture<T>` (or in older
codebases, `Future<T>`).  Lyric provides bidirectional bridges in
`lyric.runtime.async`:

- `await` of a `CompletableFuture<T>` from a default async function:
  lowers to `cf.join()` (blocks the virtual thread until completion;
  cancellation propagates via `cf.cancel(true)`).
- Calling a default Lyric async function and obtaining a
  `CompletableFuture<T>`: wraps with
  `CompletableFuture.supplyAsync(() -> f(args), virtualThreadExecutor)`.

These bridges are emitted as standard library helpers, not generated
per-call.

### 14.5 `Task<T>` / `ValueTask<T>` parity (Q010)

Lyric's `@hot` annotation triggers `CompletableFuture<T>` lowering,
matching the user-visible MSIL distinction.  The diagnostic for re-
awaiting a `@hot` value (which is undefined behaviour for
`ValueTask` on .NET, and equally undefined for the
continuation-passing transform on JVM) is identical: error if a
`@hot` value flows into two `await` positions.


## 15. Structured concurrency scopes

### 15.1 Scope-block lowering

A `scope { ... }` block lowers to Java's `StructuredTaskScope`
(JEP 462, finalised in Java 25; for Java 21 we use the preview API
behind `--enable-preview` until 25 ships).  The shape:

```java
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    var f1 = scope.fork(() -> child1());
    var f2 = scope.fork(() -> child2());
    scope.join();
    scope.throwIfFailed();
    return new Pair<>(f1.get(), f2.get());
}
```

`StructuredTaskScope` is purpose-built for the structured-concurrency
pattern: child tasks cannot outlive the scope, cancellation
propagates, and aggregate failures bubble up.  This is the *right*
shape for Lyric scopes.

### 15.2 `spawn`

`spawn e` lowers to `scope.fork(() -> e)` — exactly the
`StructuredTaskScope` API.  The result is a `StructuredTaskScope.
Subtask<T>` that the scope tracks and joins automatically.

A `spawn` outside a `scope` block is rejected at compile time, same
as MSIL (the rule is on the AST; no back-end work).

### 15.3 Aggregate failure

`StructuredTaskScope.ShutdownOnFailure` collects the first failure
and cancels remaining children.  For Lyric's "aggregate the failures"
semantics (every child's failure is reported), we use a custom
subclass `LyricAggregatingScope` (in `lyric.runtime.structured`) that
overrides `handleComplete` to accumulate.  The class is small and
ships with the Lyric stdlib; the back-end emits it as the default
scope type.

### 15.4 Java-interop with `ExecutorService`

A Lyric scope that calls into a Java library expecting an
`ExecutorService` exposes one via `scope.executor()`, a synthetic
method on `LyricAggregatingScope` that adapts to the
`ExecutorService` interface.  Tasks submitted to the adapter are
scope-tracked.  This is necessary because much of the Java ecosystem
(Spring, Vert.x, gRPC) accepts an `ExecutorService` as a primary
configuration knob.


## 16. Cancellation

Cancellation is cooperative and driven by the
`LyricCancellation` token described in §14.3.  Every async boundary
checks the token; long synchronous loops in async contexts call
`cancellation.checkOrThrow()` per iteration.

The JVM's `Thread.interrupt()` model is the underlying primitive for
default async code.  `StructuredTaskScope` cancels children by
interrupting their virtual threads, which raises
`InterruptedException` on the next blocking call.  The runtime
catches `InterruptedException` and bridges to `Bug(Cancelled)` per
§20.4.

For `@hot` paths that use `CompletableFuture`, cancellation is
explicit: a `CancellationToken` field on the state machine is
checked at every transition point.


## 17. Protected types

### 17.1 Lowering shape

A `protected type P { ... }` lowers to a `final` Java class with:

- private fields for each declared `var` / `let` / field,
- a lock field whose type is chosen by the tri-modal flavour
  selection (mirroring MSIL §17.4: `ReentrantLock` for barriers,
  `ReentrantReadWriteLock` for func-bearing types,
  `Semaphore` for value-only types),
- one Java method per `entry` and `func` declaration, each wrapping
  the body in lock-acquire / lock-release.

The lock-flavour decision and selection table are unchanged from MSIL
§17.4; only the runtime types differ:

| `hasBarriers` | `hasFuncs` | Lock emitted (JVM)       |
|---------------|------------|--------------------------|
| true          | (any)      | `ReentrantLock` + per-barrier `Condition` |
| false         | true       | `ReentrantReadWriteLock` |
| false         | false      | `Semaphore`              |

`ReentrantLock` is the JVM analogue of `Object` monitor (`Monitor`
in .NET) but with explicit `Condition` objects, which we need for
multiple barriers per protected type — `Object.wait`/`notify` only
support a single anonymous condition.

### 17.2 Entry method shape

For `entry tryAcquire(count: Double): Bool` with `requires: count > 0.0`:

```java
public boolean tryAcquire(double count) {
    if (!(count > 0.0)) throw new Bug.PreconditionViolated("tryAcquire");

    _lock.lockInterruptibly();
    try {
        assertInvariant();
        var snapshot = _captureSnapshot();
        try {
            var result = _bodyImpl(count);
            assertInvariant();
            return result;
        } catch (Bug e) {
            _restore(snapshot);
            assertInvariant();
            throw e;
        } finally {
            _signalBarriers();
        }
    } finally {
        _lock.unlock();
    }
}
```

`_captureSnapshot` and `_restore` are generated only when the
protected type has fields whose mutation could be observed before the
abort (matching MSIL §17.2).

### 17.3 `when:` barriers

Barrier-bearing types use `ReentrantLock` plus one `Condition` per
distinct `when:` predicate.  The body of an entry waits in a loop on
the relevant condition:

```java
public T entryFoo(...) throws InterruptedException {
    _lock.lockInterruptibly();
    try {
        while (!barrier_predicate()) {
            _condition_for_predicate.await();
        }
        // ... body, invariant checks, etc. ...
        _condition_all.signalAll();   // wake any waiters whose predicates may now hold
        return result;
    } finally {
        _lock.unlock();
    }
}
```

Lyric semantics (Ada-orthodox) is that an unsatisfiable barrier
blocks indefinitely; we therefore use `await()` (uninterruptible
relative to the predicate) and let cancellation propagate via the
JVM's interrupt mechanism — `Condition.await` throws
`InterruptedException` when the carrier thread is interrupted.

### 17.4 Cancellation integration

The JVM gives us a free advantage over the MSIL strategy here.  All
the lock-acquisition and condition-wait operations support
interruptible variants (`lockInterruptibly`, `Condition.await`,
`Semaphore.acquire`).  Cancellation in `LyricCancellation` translates
to a `Thread.interrupt()`; the lock primitives raise
`InterruptedException`; the runtime bridges to `Bug(Cancelled)`.

This means the "infinite-wait" caveat documented in MSIL §17.3 does
not apply on JVM.  The Phase 6 implementer should document this as a
JVM-side improvement.

### 17.5 Pattern matching is rejected (Q019)

Same rule as MSIL: any pattern that destructures a protected type at
the outer level is rejected at type-check time.  No JVM-side work.


## 18. Wire blocks (DI)

### 18.1 Lowering shape

A `wire ProductionApp { ... }` block lowers to a generated `final`
class `ProductionApp` with `private` constructor and:

- `public static <T> bootstrap(<provided values...>): <Wire>` — entry
  point.  Returns a wire instance with singletons constructed.
- `public static <T>` accessors for each `expose`d value.
- `private static <T>` factories for each `singleton` and `scoped`
  declaration.

### 18.2 Singleton resolution

Each `singleton` is emitted using the **lazy holder idiom** (the
canonical JVM thread-safe lazy-init pattern):

```java
private static final class _MakeBarHolder {
    static final Bar INSTANCE = makeBar();
}
private static Bar bar() { return _MakeBarHolder.INSTANCE; }
```

This is faster than `Lazy<T>` (no atomic compare-and-swap on every
access) because the JVM's class-load semantics give us "initialise
exactly once" without explicit synchronisation.

### 18.3 Scoped resolution

Each `scoped[Scope]` value is emitted as an `AsyncLocal`-equivalent
lookup using `ScopedValue<T>` (Java 21+, JEP 446) for short-lived
scopes (HTTP request, transaction).  For longer-lived scopes
(application-lifetime) we fall back to a thread-local
`ConcurrentHashMap<ScopeId, T>`.

`ScopedValue` is preferred where applicable because it interacts
correctly with virtual threads (`InheritableThreadLocal` does not).

### 18.4 Lifetime checking

Same rule as MSIL: a singleton may not depend on a scoped value; a
wider scope may not depend on a narrower one.  This check runs over
the AST of the wire block; if it fails, no class file is emitted.

### 18.5 Multiple wires

A program with several `wire` blocks emits one class per wire.  Wires
do not share instances; each is its own DI graph.


## 19. Reserved (no JVM-specific section)

This section number is held for parity with `09-msil-emission.md` (no
exposed-record-specific JVM behaviour beyond §9 above).


## 20. Contract elaboration

### 20.1 Where contracts insert bytecode

Per `docs/08-contract-semantics.md`, contracts evaluate at specific
points; the JVM emitter inserts checks at the same points as the
MSIL emitter.  The insertion table is unchanged; the only difference
is the runtime helper invoked on failure:

| Contract clause       | Insertion point                                  | Helper                  |
|-----------------------|--------------------------------------------------|-------------------------|
| `requires:` on `f`    | first instructions of `f`                        | `Bug.requires(...)`     |
| `ensures:` on `f`     | wrapping every `return`                          | `Bug.ensures(...)`      |
| `invariant:` of T     | end of constructors; before/after public methods | `Bug.invariant(...)`    |
| `when:` on entry      | inside the lock wrapper, in a wait-loop          | (see §17.3)             |
| `result`              | a generated local populated immediately before `ensures:` | (no helper)     |
| `old(e)`              | a generated local populated at function entry, after `requires:` succeeds | (no helper) |

A failing check calls `Bug.raise(...)`, which constructs the canonical
`Bug` value and throws a JVM exception of class
`lyric.runtime.LyricBugException`.  This is the JVM analogue of the
MSIL `Bug.Raise` helper.

### 20.2 Snapshotting for `old(e)`

Identical to MSIL §19.2.  A local of `e`'s type is allocated and
populated after `requires:` succeeds; the `ensures:` block reads from
the local.

For slice-typed (lowered to `java.util.List` or
`java.util.Collections.unmodifiableList`) and mutable-record-typed
`e`, the local stores a *snapshot copy*.  We use
`List.copyOf(original)` for slices (cheap immutable copy) and the
generated `copy()` method on records for record snapshots.

### 20.3 Elision in release mode

Same `lyric.toml`-driven elision rules as MSIL.  The class-file
`LyricElisionMode` attribute records which classes had which checks
elided so `lyric public-api-diff` can warn on a downgrade.

### 20.4 Bug bridging

The JVM raises specific exceptions for many of the conditions Lyric
classifies as Bugs.  The runtime's top-level handler wraps every
Lyric public function entry in a `try`/`catch` that re-wraps such
JVM exceptions into `Bug` tags:

| JVM exception                                  | Lyric Bug                |
|------------------------------------------------|--------------------------|
| `ArithmeticException` on `/` or `%`            | `Bug(DivisionByZero)`    |
| `ArithmeticException` from `Math.*Exact`       | `Bug(IntegerOverflow)`   |
| `ArrayIndexOutOfBoundsException`               | `Bug(ArrayBoundsViolated)` |
| `IndexOutOfBoundsException`                    | `Bug(ArrayBoundsViolated)` |
| `NullPointerException`                         | `Bug(NullDereference)`   |
| `InterruptedException`                         | `Bug(Cancelled)`         |
| `MatchException` (from JEP 441 bootstrap)      | `Bug(NonExhaustiveMatch)` |
| `OutOfMemoryError`                             | `Bug(OutOfMemory)` (re-thrown verbatim; not wrapped) |

The wrapper is emitted only on functions whose body actually contains
operations that can raise these exceptions; pure functions over
range-bounded values get no wrapper.  This is identical to the MSIL
strategy.

`NullPointerException` should be impossible from Lyric source — opaque
types do not permit `null`, nullable `T?` is a Lyric union.  An NPE
indicates the type system has been bypassed (typically via FFI).  We
still bridge to `Bug` so the failure surfaces as a Lyric-shaped
diagnostic rather than a Java stack trace.


## 21. `@derive` and source generators

`@derive(Json)`, `@derive(Sql)`, `@derive(Proto)`, `@derive(Equals)`
are processed at compile time by source generators that emit
additional Lyric or class-file declarations.  The set of supported
derives is identical to the MSIL backend; the emitter just produces
different artefacts.

For `@derive(Json)`, the generator produces a Jackson `MixIn`-shaped
class plus a `JsonSerializer<T>` and `JsonDeserializer<T>` pair, all
emitted as direct class files (no runtime reflection).  For
`@derive(Sql)`, the generator targets the JDBI 3 fluent SQL mapping
interface, again emitting the mapper class directly.

The source generators run as Lyric-side AST transformers in the same
compilation pipeline; they do not run as `javac` annotation
processors (Lyric does not invoke `javac`).


## 22. AOT compatibility (GraalVM native-image)

The MSIL strategy treats Native AOT as the production target.  The
JVM analogue is **GraalVM native-image**; we adopt the same posture.

### 22.1 What we can't emit

In Lyric output for the JVM:

- No `Method.invoke` (or other reflective dispatch) on user types.
- No `Class.forName` lookup.
- No dynamic proxy generation (`java.lang.reflect.Proxy.newProxyInstance`).
- No `MethodHandles.Lookup#findVirtual` over user types.
- No `ServiceLoader` lookup over user types (the test-module case in
  §3 is the lone exception, and it operates over compiler-emitted
  manifest entries).
- No bytecode generation at runtime (`ASM`, `cglib`, etc.).
- No `setAccessible(true)` on user types.

Source generators replace each legitimate use case (DI resolution,
serialisation, test discovery, mocking via `@stubbable`).

### 22.2 Native-image configuration

The build driver emits, alongside the JAR:

- `META-INF/native-image/lyric/<P>/reflect-config.json` —  always
  empty (no reflection) for code generated by Lyric.  Imports from
  Java libraries that need reflection have their own configs; those
  are aggregated at link time.
- `META-INF/native-image/lyric/<P>/resource-config.json` — declares
  resources (the embedded `lyric-contract`) that native-image must
  preserve.
- `META-INF/native-image/lyric/<P>/proxy-config.json` — empty.
- `META-INF/native-image/lyric/<P>/jni-config.json` — empty unless
  the package uses `extern` declarations to JNI helpers (rare; only
  in stdlib).

The Lyric build driver invokes `native-image` directly with these
configs aggregated; trim warnings are upgraded to errors.

### 22.3 Reflection by attribute

The single permitted reflection pathway is reading compiler-emitted
*annotations* via the **`Class#getAnnotation`** API (which
native-image preserves by default for classes listed in
`reflect-config.json`).  The test runner reads `@LyricTestModule` and
`@LyricTest("name")`; the DI runtime reads `@LyricWire("name")`.
These are emitted by the compiler, never by user code, and the trim
model preserves them.


## 23. Implementing the emitter in Lyric

This is the core implementation specification.  The JVM emitter is
built as a Lyric package suite — the first non-trivial application
written in Lyric.  We expect the implementation effort to surface
language-design gaps (missing stdlib pieces, awkward APIs, ergonomic
warts) and we treat that as a feature: every gap closes before v2
ships.  The emitter is therefore both a deliverable and a
self-hosting acceptance test.

### 23.1 Package layout

The emitter ships as five Lyric packages, each its own JPMS module
(in the resulting JAR layout) and Lyric package (in the source tree):

```
compiler/lyric/Lyric.Emitter.Jvm/
├── Lyric.Emitter.Jvm.Classfile/   # binary class-file model + writer
├── Lyric.Emitter.Jvm.Bytecode/    # opcode emitter + frame computation
├── Lyric.Emitter.Jvm.Lowering/    # AST → class-file IR translation
├── Lyric.Emitter.Jvm.Manifest/    # module-info, contracts, native-image configs
└── Lyric.Emitter.Jvm.Driver/      # build orchestration, JAR packaging, FFI
```

Dependencies flow downward; no upward dependencies are permitted.
`Driver` is the only package that talks to the file system; the lower
packages produce in-memory byte buffers.

### 23.2 Why split into five packages

The split is *not* gratuitous.  Each boundary corresponds to a
distinct correctness story:

- **Classfile** owns the binary format.  Its tests are golden-image:
  given an in-memory class file, the bytes match the
  `javap -v`-equivalent of an expected reference.  No semantic
  interpretation lives here.
- **Bytecode** owns instruction-level concerns: opcode emission,
  local variable allocation, stack-map-frame computation, branch
  resolution.  Its correctness is verified by feeding output through
  `java -Xverify:all`.
- **Lowering** owns the Lyric → class-file translation.  Its tests
  are end-to-end: take a Lyric AST node, lower it, run the resulting
  class, observe the expected behaviour.
- **Manifest** owns the JAR / JPMS / native-image plumbing.  Its
  tests check that produced JARs survive `jar -tf`, `jdeps`, and
  `native-image`.
- **Driver** owns the user-visible CLI / build-driver integration.
  Its tests are integration-level (`lyric build --target=jvm`).

Each package is a vertical slice that one engineer can hold in head.
Together they are about 8000–12000 lines of Lyric — comparable to
the F# bootstrap's emitter at the same milestone.

### 23.3 The class-file model (Lyric.Emitter.Jvm.Classfile)

JVMS Chapter 4 defines the class-file format.  We model it
faithfully in Lyric, taking advantage of records and unions:

```
package Lyric.Emitter.Jvm.Classfile

pub record ClassFile {
  minorVersion: Int
  majorVersion: Int                    # 65 for Java 21
  constantPool: ConstantPool
  accessFlags: AccessFlagSet
  thisClass: ConstantPool.ClassRef
  superClass: ConstantPool.ClassRef?   # None only for module-info
  interfaces: slice[ConstantPool.ClassRef]
  fields: slice[FieldInfo]
  methods: slice[MethodInfo]
  attributes: slice[Attribute]
}

pub union ConstantPoolEntry {
  case Utf8(value: String)
  case IntegerC(value: Int)
  case LongC(value: Long)
  case FloatC(value: Float)
  case DoubleC(value: Double)
  case ClassC(name: ConstantPool.Utf8Ref)
  case StringC(value: ConstantPool.Utf8Ref)
  case Fieldref(class: ConstantPool.ClassRef, nameAndType: ConstantPool.NameAndTypeRef)
  case Methodref(class: ConstantPool.ClassRef, nameAndType: ConstantPool.NameAndTypeRef)
  case InterfaceMethodref(class: ConstantPool.ClassRef, nameAndType: ConstantPool.NameAndTypeRef)
  case NameAndType(name: ConstantPool.Utf8Ref, descriptor: ConstantPool.Utf8Ref)
  case MethodHandle(kind: MethodHandleKind, ref: ConstantPool.AnyRef)
  case MethodType(descriptor: ConstantPool.Utf8Ref)
  case Dynamic(bootstrapIdx: Int, nameAndType: ConstantPool.NameAndTypeRef)
  case InvokeDynamic(bootstrapIdx: Int, nameAndType: ConstantPool.NameAndTypeRef)
  case Module(name: ConstantPool.Utf8Ref)
  case Package(name: ConstantPool.Utf8Ref)
}
```

`ConstantPool` is itself an opaque type whose internal representation
is a `slice[ConstantPoolEntry]` plus deduplicating maps.  The
visible API:

```
pub opaque type ConstantPool {
  entries: slice[ConstantPoolEntry]
  utf8Cache: Map[String, Int]
  classCache: Map[String, Int]
  # ... per-kind dedup caches ...

  invariant: entries.length < 65535      # JVMS limit
}

pub func empty(): ConstantPool
pub func intern[T](pool: inout ConstantPool, entry: T): Int
pub func internUtf8(pool: inout ConstantPool, s: in String): Utf8Ref
pub func internClass(pool: inout ConstantPool, internalName: in String): ClassRef
# ... per-kind interners ...
```

Every interner is contract-checked: `requires` clauses ensure the
input is well-formed (e.g. internal names use `/` not `.`); `ensures`
clauses guarantee the returned index is valid and stable.

Note the `inout` parameter mode on `intern` — we mutate the constant
pool, returning the new index.  This is the natural Lyric encoding
of the imperative builder pattern.

### 23.4 Binary I/O (Lyric.Emitter.Jvm.Classfile)

Class-file binary I/O is a closed problem:

- All multi-byte fields are big-endian.
- `u1`, `u2`, `u4` correspond directly to `Byte`, `UInt range
  0..=65535`, `UInt`.
- Strings are "Modified UTF-8" — JVMS §4.4.7 — *not* standard UTF-8
  (NUL bytes are encoded as `0xC0 0x80`, supplementary characters
  are surrogate pairs).

We expose a `BinaryWriter` opaque type built on top of the stdlib's
`slice[Byte]` builder:

```
pub opaque type BinaryWriter {
  buffer: ByteBuilder
}

pub func u1(w: inout BinaryWriter, x: in Byte)
pub func u2(w: inout BinaryWriter, x: in UInt range 0 ..= 65535)
pub func u4(w: inout BinaryWriter, x: in UInt)
pub func modifiedUtf8(w: inout BinaryWriter, s: in String)
pub func raw(w: inout BinaryWriter, bytes: in slice[Byte])
pub func toBytes(w: in BinaryWriter): slice[Byte]
```

The Modified-UTF-8 encoder is the only non-trivial routine in this
package.  It iterates over `String.codePoints()` (Lyric stdlib's
Unicode scalar enumerator) and writes 1, 2, 3, or 6 bytes per code
point per JVMS §4.4.7.

### 23.5 Bytecode emission (Lyric.Emitter.Jvm.Bytecode)

A method body is a sequence of typed instructions.  We model the
JVM's 200+ opcodes as a closed Lyric union:

```
package Lyric.Emitter.Jvm.Bytecode

pub union Insn {
  # 4.10.1 — type-conversion + arithmetic
  case Iadd, Isub, Imul, Idiv, Irem, Ineg
  case Ladd, Lsub, Lmul, Ldiv, Lrem, Lneg
  case Fadd, Fsub, Fmul, Fdiv, Frem, Fneg
  case Dadd, Dsub, Dmul, Ddiv, Drem, Dneg

  # local variable access
  case Iload(slot: LocalSlot)
  case Lload(slot: LocalSlot)
  case Fload(slot: LocalSlot)
  case Dload(slot: LocalSlot)
  case Aload(slot: LocalSlot)
  case Istore(slot: LocalSlot)
  # ... mirror for L, F, D, A ...

  # stack manipulation
  case Pop, Pop2, Dup, DupX1, DupX2, Dup2, Dup2X1, Dup2X2, Swap

  # constants
  case Iconst(value: Int range -1 ..= 5)
  case Lconst(value: Long range 0 ..= 1)
  case Bipush(value: Byte)
  case Sipush(value: Int range -32768 ..= 32767)
  case Ldc(ref: ConstantPool.AnyConstantRef)

  # control flow
  case Goto(target: Label)
  case IfEq(target: Label), IfNe(target: Label), IfLt(target: Label),
       IfGe(target: Label), IfGt(target: Label), IfLe(target: Label)
  case IfIcmpEq(target: Label) /* … */
  case Return, Ireturn, Lreturn, Freturn, Dreturn, Areturn
  case Athrow

  # method dispatch
  case Invokestatic(ref: ConstantPool.MethodRef)
  case Invokevirtual(ref: ConstantPool.MethodRef)
  case Invokespecial(ref: ConstantPool.MethodRef)
  case Invokeinterface(ref: ConstantPool.IMethodRef, count: UInt range 1 ..= 255)
  case Invokedynamic(ref: ConstantPool.IndyRef)

  # field access
  case Getstatic(ref: ConstantPool.FieldRef)
  case Putstatic(ref: ConstantPool.FieldRef)
  case Getfield(ref: ConstantPool.FieldRef)
  case Putfield(ref: ConstantPool.FieldRef)

  # arrays
  case Newarray(typeCode: ArrayTypeCode)
  case Anewarray(elementClass: ConstantPool.ClassRef)
  case Arraylength
  case Iaload, Laload, Faload, Daload, Aaload, Baload, Caload, Saload
  case Iastore /* … */

  # tableswitch / lookupswitch
  case Tableswitch(default: Label, low: Int, high: Int, targets: slice[Label])
  case Lookupswitch(default: Label, pairs: slice[(Int, Label)])

  # type tests
  case Instanceof(class: ConstantPool.ClassRef)
  case Checkcast(class: ConstantPool.ClassRef)
  case New(class: ConstantPool.ClassRef)

  # synchronization
  case Monitorenter, Monitorexit

  # … ~200 more …
}
```

This is the largest sum type in the whole codebase; the closed-union
shape means exhaustiveness checks catch every place that needs to
handle every opcode.  Adding a new opcode (Java 25 may add one or
two) is a single source-level change followed by a flurry of
exhaustiveness errors that the developer chases to completion.

The `MethodEmitter` is a builder over `slice[Insn]`:

```
pub opaque type MethodEmitter {
  insns: slice[Insn]
  labels: Map[LabelId, Int]              # Insn index per label
  locals: LocalAllocator
  maxStack: Int
  maxLocals: Int
}

pub func emit(m: inout MethodEmitter, insn: in Insn)
pub func emitLabel(m: inout MethodEmitter): Label
pub func bindLabel(m: inout MethodEmitter, label: in Label)
pub func finalize(m: in MethodEmitter, pool: inout ConstantPool): MethodInfo
```

`finalize` resolves all labels to byte offsets, computes the
stack-map frames per JVMS §4.10.1, and produces a serialised
`Code` attribute.

### 23.6 Stack-map frame computation

This is the hardest single algorithm in the emitter.  JVMS §4.10.1
specifies a verifier that tracks operand-stack and local-variable
types at every branch target; a class file must declare
`StackMapTable` entries that match what the verifier computes, or
class-loading fails.

We adopt the algorithm from JVMS §4.10.1.4 (the type-inference
verifier):

```
package Lyric.Emitter.Jvm.Bytecode.Verifier

pub union VerifierType {
  case TopT
  case IntegerT
  case FloatT
  case LongT
  case DoubleT
  case NullT
  case UninitializedThis
  case Uninitialized(offset: Int)
  case Object(class: String)
}

pub record Frame {
  locals: slice[VerifierType]
  stack: slice[VerifierType]
}

pub async func computeFrames(
  insns: in slice[Insn],
  initialFrame: in Frame,
  exceptionHandlers: in slice[ExceptionHandler],
): Result[slice[(Int, Frame)], FrameComputationError]
```

The frame computation is iterative-fixpoint: each instruction
produces a new frame; merging is type-lattice meet.  The function
runs over a control-flow graph and converges in O(insns × locals).

**Bootstrap caveat.** Because this routine is large and subtle, the
initial Lyric implementation will *delegate* via FFI to ASM's
`ClassWriter.COMPUTE_FRAMES`.  ASM is the de-facto Java bytecode
library, BSD-licensed, well-tested.  We invoke it via an
in-process JNI bridge from the Lyric runtime.  Once the in-Lyric
verifier is correctness-tested against ASM on a corpus of >10000
class files (from JDK + Maven Central popular libraries), we ship the
in-Lyric verifier and drop the ASM dependency.

This is the same staged-bootstrap pattern the F# emitter uses for
PE-file emission (delegating to `System.Reflection.Emit` initially,
then migrating piece-by-piece to in-house code).

### 23.7 Lowering (Lyric.Emitter.Jvm.Lowering)

This package consumes the **same lowered AST** the F#-bootstrap
emitter produces and translates it into the class-file IR.  The
lowered AST is the existing `Lyric.Emitter` IR (per
`compiler/src/Lyric.Emitter/`); when the F# bootstrap port ships
(Phase 5), this IR moves into a Lyric-native package
`Lyric.Compiler.Lowered` and the JVM emitter consumes it from there.

The lowering is structured as one function per AST node kind:

```
package Lyric.Emitter.Jvm.Lowering

pub func lowerPackage(
  ctx: inout EmitContext,
  pkg: in LoweredPackage,
): Result[ClassFileSet, LoweringError]

func lowerType(ctx: inout EmitContext, t: in LoweredType): ClassFile

func lowerFunc(
  ctx: inout EmitContext,
  fn: in LoweredFunc,
): MethodInfo

func lowerExpr(
  ctx: inout EmitContext,
  m: inout MethodEmitter,
  e: in LoweredExpr,
): VerifierType                         # the JVM type pushed onto the stack
```

The `EmitContext` carries the per-package mutable state: the
constant pool, the symbol table mapping Lyric names to JVM
descriptors, the lambda-host counter, etc.  It is an opaque type
with `inout` mutation; the contract semantics are documented in its
package-level invariant clause.

`lowerExpr` returns the verifier type of the value pushed onto the
operand stack.  Subexpressions cooperate via this contract: a
caller knows whether to emit `iadd` vs `ladd` vs `dadd` from the
returned types.  This is where the language reference's "explicit
parameter modes" pays off: `m: inout MethodEmitter` makes the
mutation visible at every call site.

### 23.8 Manifest emission (Lyric.Emitter.Jvm.Manifest)

Smaller package, mostly straight-line code:

- `module-info.class`: emit `module` constant, `requires`/`exports`/
  `opens` flags from the package's import table.
- `META-INF/MANIFEST.MF`: text format, key-value pairs.
- `META-INF/lyric/<P>.lyric-contract`: serialise the package's
  public contract to JSON via `lyric.std.json.derive`.
- `META-INF/native-image/lyric/<P>/*.json`: emit the four
  configuration files described in §22.2.

### 23.9 Driver (Lyric.Emitter.Jvm.Driver)

The `Driver` package is the only one that:
- talks to the file system (via `lyric.std.io.fs`),
- launches subprocesses (`javap`, `native-image`),
- reads `lyric.toml`,
- shells out to ASM during the bootstrap phase.

Driver responsibilities:

```
pub async func buildPackage(
  ctx: inout DriverContext,
  manifest: in Manifest,
  options: in BuildOptions,
): Result[BuildArtefact, BuildError]
```

The driver:
1. Resolves the package's import graph (delegating to
   `Lyric.Cli.Manifest`).
2. Loads or compiles each dependency to its `.lyrjar`.
3. Invokes the `Lowering` package once per source file, in parallel
   via a `scope { ... }` block (showcasing structured concurrency).
4. Writes the resulting class files into the output JAR using
   `lyric.std.io.archive.zip`.
5. Optionally invokes `native-image` to produce an AOT executable.

The driver is the thinnest layer that exists; most of its lines are
error handling and progress reporting.

### 23.10 Self-test corpus

The emitter's correctness is established by:

1. **Unit tests** in each package, expecto-style (or whatever Lyric's
   test harness becomes by Phase 6).
2. **Golden-image tests**: for each Lyric program in
   `docs/02-worked-examples.md`, compile both with the F# bootstrap
   targeting MSIL and the new Lyric-self-hosted emitter targeting
   JVM, run both, and diff the output.
3. **Differential fuzzing**: a generator emits random Lyric ASTs;
   we lower each via JVM, run through `java -Xverify:all`; any
   verifier rejection is a back-end bug.
4. **JDK + Maven Central round-trip**: take a sample of Java JARs,
   round-trip them through `Classfile`'s reader/writer (the reader
   is added in §23.13), and diff.  This validates the binary I/O
   independent of lowering.

### 23.11 Bootstrap dependency timeline

The emitter is staged into existence:

| Stage | Deliverable | What still depends on FFI / external tools |
|-------|-------------|-------------------------------------------|
| B1    | `Classfile` reader/writer in Lyric         | none (clean)                |
| B2    | `Bytecode` opcode emitter in Lyric         | ASM `COMPUTE_FRAMES`        |
| B3    | `Lowering` for primitives, records, funcs  | ASM still                   |
| B4    | `Lowering` for unions, generics, async      | ASM still                   |
| B5    | Stack-map computation in Lyric              | ASM dropped                 |
| B6    | `Lowering` for protected types, wires       | none                        |
| B7    | Native-image integration (driver)           | invokes native-image binary (not a library dep) |
| B8    | Differential-fuzzing tooling                | none                        |

Estimated effort: 8–14 person-months for stages B1–B6, and another
3–4 person-months for B7–B8.  This is comparable to the F# emitter's
ramp from M1.1 to M1.4 (about 9 months in the actual timeline).

### 23.12 Language-stress checklist

Building the emitter in Lyric will exercise:

- **Records and unions**: the entire `Insn` and `ConstantPoolEntry`
  hierarchies are large unions, and most of the emitter is
  pattern-matching over them.
- **Opaque types**: `ConstantPool`, `MethodEmitter`, `BinaryWriter`,
  `EmitContext` are all opaque; their internal mutation is the test
  case for every contract-elaboration corner.
- **Range subtypes**: `u1`, `u2`, JVMS limits on constant-pool size,
  local-variable count (≤ 65535), method bytecode length (≤ 65535).
  Each maps to a range subtype in Lyric source; out-of-range produces
  a verifier-style diagnostic at compile time.
- **Generics**: collections of all the union-typed instructions.
  This is the test of how cleanly the JVM emitter handles its own
  generics on the JVM!
- **`inout` parameters**: every emitter call mutates a builder.
  This is the largest body of `inout`-using Lyric code ever written.
- **Pattern matching**: every traversal is a `match` on an `Insn` or
  AST node; exhaustiveness keeps us honest as the JVM evolves.
- **Async + structured concurrency**: parallel file emission is via
  `scope { spawn ... }`.
- **Contracts**: every binary-I/O routine has `requires` clauses
  matching JVMS limits; the `MethodEmitter`'s frame-validity invariant
  catches malformed sequences early.
- **Proof-required code (longer-term)**: once the prover handles
  imperative state, the constant-pool deduplication is a candidate
  for proof-required marking — the proof obligation is roughly "the
  returned index references an entry equal to the input."

### 23.13 Future: Lyric.Emitter.Jvm.Reader

A class-file *reader* is not strictly needed for emission, but is
indispensable for tooling: differential-fuzzing, test harnesses,
linters that consume Lyric-emitted JARs.  The reader is a separate
sub-package that shares the `Classfile` model with the writer; its
inverse-of-write structure means most of the test surface comes for
free (write-then-read-then-compare).

The reader is also the natural foundation for a future "Lyric ←
Java" interop tool: read a Java class file, infer a Lyric public-
contract from it, generate FFI shims.  This is parallel to the
.NET strategy's reliance on the BCL + `Lyric.Stdlib`.


## 24. Open questions and recommended defaults

The following items deferred during this design pass.  Each carries a
recommended default the implementer should adopt absent contrary
evidence:

### Q-J001: Project Valhalla migration path

When Valhalla's value classes ship in an LTS, distinct types and
range subtypes can drop the heap-allocation cost.  The migration
should preserve binary compatibility for users who haven't recompiled.

**Recommended default**: emit a `LyricValhallaCandidate` annotation on
every generated distinct-type class; when an LTS Valhalla ships,
provide a tool that recompiles `LyricValhallaCandidate` classes as
value classes.  Deferred until Valhalla is GA.

### Q-J002: Coroutines vs virtual threads for `@hot`

We chose `CompletableFuture` + state-machine for `@hot`.  Kotlin
coroutines are a competing model with arguably better ergonomics,
but they require a runtime dependency on `kotlinx.coroutines`.

**Recommended default**: stick with `CompletableFuture`.  Revisit if
Kotlin coroutines become a JEP-grade JDK feature.

### Q-J003: When to emit specialised generic helpers (§10.2)

The build driver decides per-call-site whether to generate a
specialised helper class.  The decision policy is undecided: a
naive heuristic (`@hot` annotation or in proof-required code) over-
generates; a sophisticated heuristic (profile-guided) is hard to
build.

**Recommended default**: emit specialised helpers for `@hot` only,
plus any call site the prover discharges as in-bounds (zero-overhead).
Tune empirically once the emitter ships.

### Q-J004: ASM dependency drop deadline

§23.11 stages the ASM dependency away by stage B5.  Slipping this
risks shipping a runtime ASM dependency in v2.

**Recommended default**: hold the deadline.  If verifier work slips,
release v2 with the ASM dependency clearly documented and drop in
v2.1.  Do not ship v3.0 with an ASM dependency.

### Q-J005: Java interop type-mapping for opaque-typed parameters

Java code that calls into a Lyric module sees opaque-typed
parameters as `Object` (since the underlying class is non-exported).
This is awkward for Java callers who *want* to call Lyric APIs.

**Recommended default**: emit a public "facade" class per opaque type
that exposes only the type's `pub func` constructors and accessors,
and Java callers go through the facade.  This keeps internals sealed
without making Lyric APIs unusable from Java.

### Q-J006: Modified UTF-8 vs UTF-8

JVMS class-file string encoding is Modified UTF-8.  Some JVM versions
have begun to allow standard UTF-8 in some contexts.  The risk of
mismatch is low but real.

**Recommended default**: always emit Modified UTF-8 for class-file
strings, and standard UTF-8 for `MANIFEST.MF` / contract JSON.

### Q-J007: Test-runner integration

Lyric's test-module discovery needs a JVM-side runner.  Building one
is a non-trivial add.

**Recommended default**: piggy-back on JUnit 5's
`LauncherFactory` API, with a Lyric-side adapter that translates
`@LyricTest`-annotated methods into `TestEngine` discoveries.  Do
not write a runner from scratch.


## 25. References

- **JVMS**: *The Java Virtual Machine Specification*, Java SE 21
  Edition, Oracle 2023.  The reference for class-file format,
  bytecode, and verification.
- **JLS**: *The Java Language Specification*, Java SE 21 Edition.
  The reference for Java records, sealed classes, pattern switch,
  and module semantics.
- **JEPs**:
  - JEP 395 (Records) — Java 16
  - JEP 409 (Sealed Classes) — Java 17
  - JEP 441 (Pattern Matching for switch) — Java 21
  - JEP 444 (Virtual Threads) — Java 21
  - JEP 446 (Scoped Values) — Java 21 preview
  - JEP 462 (Structured Concurrency) — Java 21 preview
  - JEP 488 (Pattern matching for primitive types) — Java 23 preview
- **GraalVM native-image**: documentation, reflection-config.json
  schema, build-time initialization model.
- **ASM**: 9.x library documentation; reference for stack-map-frame
  computation and the bootstrap pathway in §23.11.
- **Decision log** (`docs/03-decision-log.md`): D001 (target),
  D006 (no reflection), D023 (JVM post-v1), D034 (closed marker
  set).
- **MSIL emission strategy** (`docs/09-msil-emission.md`): the
  parallel document for .NET; this document is structured to mirror
  it section-by-section for easy cross-reference.
- **Operational semantics for contracts**
  (`docs/08-contract-semantics.md`): the source of truth for *when*
  contracts are checked.

---

## Appendix A. Quick-reference: Lyric construct → JVM shape

| Lyric                            | JVM                                                  |
|----------------------------------|------------------------------------------------------|
| primitive                        | matching JVM primitive (boxed only at generic boundaries) |
| `record T`                       | Java `record T(...)`, `final`, `@LyricRecord`        |
| `exposed record T`               | Java `record T(...)`, public, `@LyricExposed`        |
| `type X = Y range a ..= b`       | `final record X($value: Y)`, `@LyricDistinct`        |
| `type X = Y` (no range)          | `final record X($value: Y)`, `@LyricDistinct`        |
| `alias X = Y`                    | (no JVM type; X resolves to Y)                       |
| `opaque type T`                  | `final class T`, `@LyricOpaque`, mangled fields      |
| `union U { case A, case B(...) }`| sealed interface `U`, records `U.A`, `U.B`           |
| `enum E`                         | JVM `enum E` (UPPER_SNAKE-cased values)              |
| `array[N, T]`                    | `T[]` of fixed length, length checked statically      |
| `slice[T]`                       | `java.util.List<T>` (immutable view) — usually `List.copyOf` |
| `T?`                             | sealed interface lowering of `union {Some(T), None}` |
| function (`func`)                | `public static` method on `<package>$Funcs`          |
| `async func` (default)           | synchronous method, runs on a virtual thread         |
| `async func @hot`                | `CompletableFuture<T>` + state-machine               |
| closure                          | `invokedynamic` + `LambdaMetafactory` synthetic method |
| `protected type`                 | `final class` with `ReentrantLock` / `RWLock` / `Semaphore` |
| `wire`                           | `final class` with lazy-holder singletons + `ScopedValue` |
| `interface`                      | Java `interface`                                     |
| `impl I for T`                   | `class T implements I` with method bodies            |
| `extern package`                 | references via FFI; no Lyric class file emitted      |


## Appendix B. Per-Q resolution summary

| Q     | Topic                              | Resolution in this document                      |
|-------|------------------------------------|--------------------------------------------------|
| Q001  | Record vs class lowering           | §5.2: always Java records; `@valueType` rejected on JVM target |
| Q002  | Sealing opaque types               | §7.2: five-layer strategy; AOT-grade only on GraalVM native-image |
| Q003  | Projection cycles                  | §7.3: same as MSIL — `@projectionBoundary` enforcement |
| Q004  | Generic constraint markers         | §10.3: `Compare` → `Comparable<T>`; arithmetic markers → witness parameter |
| Q005  | Async + `inout`                    | unchanged from MSIL; AST-level rejection         |
| Q006  | `?` in non-error functions         | unchanged from MSIL; AST-level enforcement       |
| Q007  | `var` capture across async         | §11.3: same as MSIL — snapshot by value          |
| Q008  | Concurrent `func` on protected     | §17.1, §17.4: tri-modal lock; cancellation via interrupt (better than MSIL) |
| Q009  | Protected type lowering            | §17.1–17.4: tri-modal lock; `Condition.await`/`signalAll` for barriers |
| Q010  | Task vs ValueTask                  | §14: virtual threads default; `@hot` selects `CompletableFuture` |
| Q011  | Stdlib API surface                 | deferred to a separate JVM stdlib doc            |
| Q012  | Package registry                   | deferred; module name mapping is independent     |
| Q-J001 | Valhalla migration                | §24: deferred                                     |
| Q-J002 | Coroutines vs virtual threads     | §24: stick with `CompletableFuture`              |
| Q-J003 | Specialised generic helpers       | §24: `@hot` + prover-discharged sites only       |
| Q-J004 | ASM dependency drop deadline      | §24: hold; v3 must be ASM-free                   |
| Q-J005 | Java interop facade               | §24: emit per-opaque facade class                |
| Q-J006 | Modified UTF-8 vs UTF-8           | §24: Modified UTF-8 in class files; standard UTF-8 elsewhere |
| Q-J007 | Test-runner integration            | §24: JUnit 5 `LauncherFactory` adapter           |


## Appendix C. JVM-specific class-file attributes emitted by Lyric

The emitter writes the following attributes on Lyric-produced class
files (in addition to standard JVMS attributes):

| Attribute name        | Scope               | Purpose                                  |
|-----------------------|---------------------|------------------------------------------|
| `LyricSignature`      | class, field, method | full Lyric type signature pre-erasure   |
| `LyricContract`       | method              | the `requires` / `ensures` syntax tree   |
| `LyricInvariant`      | class               | the `invariant:` syntax tree             |
| `LyricElisionMode`    | class               | which `[contracts]` flags were elided    |
| `LyricSpecialisation` | class (helper only) | which generic instantiation produced it  |
| `LyricSourceMap`      | class               | source-line ↔ bytecode-offset mapping for the Lyric debugger |

All are emitted under the vendor-specific attribute mechanism per
JVMS §4.7.1; standard Java tools silently ignore them.  The
`LyricSourceMap` is in addition to (not in place of) the JVM's
standard `LineNumberTable` attribute, which we also emit for
`javap`/IDE/debugger consumption.
