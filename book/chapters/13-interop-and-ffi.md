# Interoperability and FFI

Lyric runs on .NET, and the .NET runtime carries forty years of BCL surface behind it: file I/O, HTTP clients, cryptography, database drivers, JSON serialization, and far more. You can use that surface from Lyric — but every use is explicit, visible, and carries a contract. This chapter covers the `extern package` declaration, the `@axiom` annotation, the rules for crossing the boundary in both directions, and the standard library's hand-curated wrappers that handle most of the BCL surface you will need day to day.

If you have come from a language that lets you call platform types as freely as local ones — C# calling `File.ReadAllText`, Kotlin calling Java APIs — the explicit boundary may feel like extra ceremony. The rationale is not arbitrary: platform code does not have Lyric contracts, can throw, may use reflection, and may modify state the type system cannot see. The `extern` boundary is a declaration of what you are trusting and what you have reviewed. That declaration is the ceremony, and it is weight-bearing.

Chapter 12 introduced `Std.File`, `Std.Http`, and `Std.Time` as the recommended interface to the BCL. This chapter explains how those modules are built, what to do when you need something they do not cover, and what the rules are when .NET types cross into Lyric.

## §13.1 Why an explicit FFI boundary?

Most languages that target a managed runtime let you call platform types as if they were local. Lyric does not — not because it cannot, but because it will not without an explicit declaration.

The reasoning has three parts.

First, contracts. A `requires:` clause on a Lyric function is either checked at runtime (`@runtime_checked`) or proved at compile time (`@proof_required`). A BCL function has neither. If your `@proof_required` module calls into `System.IO.File.ReadAllText` without a declared contract, the prover has nothing to work with. The `@axiom` annotation supplies that contract — in your name, reviewed in your PR, recorded in your package's metadata. Wrong axioms produce wrong proofs, which is why the system makes axioms heavyweight by design.

Second, exceptions. Lyric's error model has two channels: `Result` for recoverable errors and `Bug` for violations. The BCL has one: exceptions. A BCL call that throws crosses from one model into the other. The `try { } catch Bug` robustness boundary (covered in Chapter 7) is how that conversion is made explicit and isolated. Without the explicit boundary, every BCL call is a latent exception that the type system cannot see.

Third, reflection. Opaque types are sealed against .NET reflection. A BCL library that calls `typeof(T).GetField(...)` can crack open a Lyric opaque type. The `extern` declaration does not prevent that — but it identifies the boundary where the guarantee holds. Code inside the extern surface is not covered by Lyric's opaque guarantees; code outside it is.

The practical consequence for most programs is nothing: you use `Std.File`, `Std.Http`, and `Std.Time`, and the extern declarations are inside those modules, not yours. You write extern declarations only when you reach for BCL surface that the stdlib does not wrap.

## §13.2 `extern package` and `@axiom`

An `extern package` declaration declares a set of functions and types that are implemented by the host runtime. It requires an `@axiom` annotation with a human-readable description:

```lyric
@axiom("System.IO.File operations conform to the .NET BCL contract")
extern package System.IO {
  pub func readAllBytes(path: in String): slice[Byte]
    requires: path.length > 0
    ensures: result.length >= 0

  pub func readAllText(path: in String): String
    requires: path.length > 0

  pub func writeAllBytes(path: in String, bytes: in slice[Byte]): Unit
    requires: path.length > 0

  pub func exists(path: in String): Bool
}
```

The `@axiom` string is not a comment — it is part of the contract metadata emitted into the package's `.lyric-contract` artifact. Every package that imports yours can inspect it. `lyric doc` renders it in the generated documentation. `lyric public-api-diff` includes it in change reports.

The `requires:` and `ensures:` clauses inside an extern declaration are axioms in the proof-theoretic sense: the prover treats them as facts, does not try to prove them, and uses them when verifying callers. If a caller in a `@proof_required` module calls `readAllBytes`, the prover knows `result.length >= 0` after the call because the axiom says so. If that axiom is wrong — if there is some code path that returns a negative length — the proof is wrong, and no tool will catch it. This is why the axiom string should be precise and the contracts should be conservative.

::: note
**Note:** The `Lyric.Stdlib` F# shim is fully retired; the compiler now resolves `extern package` declarations directly against the BCL via reflection-driven binding. Any BCL type can be declared in an `extern package` block and annotated with `@externTarget`. Reach for the stdlib modules first — they provide idiomatic Lyric wrappers with contracts — but arbitrary BCL surfaces are accessible when needed.
:::

**Static vs. instance calls.** Lyric writes `@externStatic` or `@externInstance` next to `@externTarget` to tell the compiler which CIL/JVM call instruction to emit:

```
@externTarget("System.Math.Abs")
@externStatic
pub func absInt(n: in Int): Int

@externTarget("System.String.Trim")
@externInstance
pub func strTrim(s: in String): String
```

`@externStatic` emits `call` / `invokestatic`; `@externInstance` emits `callvirt` / `invokevirtual` with Lyric arg 0 as the receiver. They are mutually exclusive; setting both is a diagnostic. When neither is present the .NET self-hosted MSIL emitter defaults to static — instance externs must annotate explicitly.

**Unresolvable targets.** On `--target dotnet` an `@externTarget` whose CLR type cannot be resolved to a known reference assembly (anything outside the `System.*` BCL surface and the `Lyric.*` internal host) fails the build with a clear diagnostic naming the unresolvable type, rather than silently mis-binding to `System.Runtime` and throwing `MissingMethodException` at runtime.  On `--target jvm` there is no compile-time class-resolution check; an unresolvable Java class name throws `NoClassDefFoundError` at class-load time.

**Passing a lambda to a delegate-typed parameter.** When an `@externTarget` function itself declares a function-typed (`TFunction`) parameter and you pass a Lyric lambda directly at the call site, `--target dotnet` binds it to a real closed `System.Func<...>`/`System.Action<...>` delegate — matching the BCL API's exact declared type, including value-type type arguments such as `CancellationToken` — rather than the boxed `Func<object,...,object>` shape every other function-typed value in Lyric uses. This is a narrow fix (D122): it only applies to an `@externTarget` function's own declared parameters, not to lambdas in general, so it is safe to rely on when wrapping a BCL API like `SocketsHttpHandler.ConnectCallback` that expects a specific delegate signature.

## §13.3 The `@axiom` social contract

An `@axiom` block is not just compiler syntax. It is a commitment you record in your code review history.

When someone audits your package's safety properties — your team's security review, a downstream consumer evaluating whether to depend on you, or a formal audit — they read the axiom blocks first. Every line of an extern declaration represents something you are claiming is true about platform behaviour that the compiler cannot check. The audit starts there.

This has practical implications for how to write axiom blocks:

**Be conservative on `ensures:`.** If the BCL documentation says a function returns a non-null string, that is a reasonable ensures clause. If the documentation is silent on a property, do not claim it holds. An ensures clause you cannot support is a proof liability.

**Be precise on `requires:`.** If `ReadAllText` throws `ArgumentNullException` when `path` is null, capture that as `requires: path.length > 0`. If it also throws on empty strings (it does), the requires clause should reflect that. A caller with a valid path that still triggers an exception is a gap in your requires clause.

**Make the `@axiom` string accurate.** The string "System.IO.File operations conform to the .NET BCL contract" is accurate when the functions declared do conform. If you are declaring a subset of File operations with stricter contracts than the BCL provides, say so. The string is read by humans who need to understand what trust they are extending.

The decision log entry D013 explains why the proof system is per-module rather than per-function: a verified module calling unverified helpers gives you nothing. The same logic applies to axiom blocks — a sound proof built on a wrong axiom is a wrong proof.

## §13.4 Wrapping the boundary

Raw `extern` declarations expose platform surface directly: functions that can throw, return types that carry no Lyric error channel, and contracts that are trusted rather than checked. The idiomatic pattern is to wrap an extern declaration in a Lyric package that translates platform exceptions into `Result` and gives callers a clean, contractual interface:

```lyric
// fs.l
@runtime_checked
package Fs

import System.IO as Sys

pub union FsError {
  case NotFound(path: String)
  case IoError(path: String, message: String)
  case PermissionDenied(path: String)
}

pub func readBytes(path: in String): Result[slice[Byte], FsError]
  requires: path.length > 0
{
  if not Sys.exists(path) {
    return Err(NotFound(path))
  }
  return try {
    Ok(Sys.readAllBytes(path))
  } catch Bug as b {
    Err(IoError(path, b.message))
  }
}
```

The `try { } catch Bug as b` block converts a platform exception into a typed `Result`. Inside this block, catching a `Bug` is intentional — it is the robustness boundary. The compiler would normally emit a warning for catching `Bug` in application code, but this is exactly the pattern the boundary is for.

Downstream callers of `Fs.readBytes` see only the Lyric API. They receive `Result[slice[Byte], FsError]`. They never see a platform exception. The axiom block is isolated to one file, one review diff, and does not leak into the rest of the codebase.

This is how `Std.File` is built. Its `@axiom` block is in `stdlib/std/file.l`. The file exports `readText`, `writeText`, `fileExists`, and `createDir` — all returning `Result` or `Bool` — and internally calls the wrapped BCL functions. You can read its source to see exactly what is trusted and what is derived.

::: sidebar
**Why not just catch exceptions everywhere?** Some languages encourage catching `Exception` broadly and converting to a local error type at every call site. This works but erases information: you lose the distinction between "the file was not found" and "the disk is full." The wrapper-package pattern converts BCL exceptions once, at the extern boundary, into a union that names each condition. Callers get exhaustive match coverage and precise error types. The cost is one more source file per BCL surface area; the benefit is a typed error channel across the entire codebase above it.
:::

## §13.5 Cross-boundary marshalling

When Lyric values cross into the BCL and back, the type mapping follows a fixed set of rules.

**Lyric to .NET.** Opaque types pass as sealed opaque handles — a generated .NET type with no public properties and no accessible constructors. Reflection on an opaque handle returns nothing useful; the representation is invisible. Exposed records pass as their generated .NET `record class`, with public fields that match the record's fields. Primitives (`Int`, `Long`, `Double`, `Bool`, `String`) map directly to their .NET counterparts (`int`, `long`, `double`, `bool`, `string`). Slices pass as .NET arrays.

**NET to Lyric.** A .NET type arriving at an extern boundary enters Lyric as an exposed record by default. If you need to validate it and wrap it into an opaque type — re-establishing invariants that the BCL does not enforce — you do that explicitly in a constructor that can return `Result`. There is no implicit coercion.

This asymmetry is intentional. Lyric opaque types carry invariants that the compiler enforced at construction. Accepting a .NET value as an opaque type without validation would silently bypass those invariants. The rule "`.NET → Lyric` requires explicit construction" is what keeps the invariant sound.

For primitive types, there is no marshalling cost. `Int` and `int` have identical runtime representations; the compiler generates no conversion code.

### §13.5.1 Nullable references: the `Option[T]` return convention

Many host methods return a nullable reference — `System.Environment.GetEnvironmentVariable` on .NET, `java.lang.System.getenv` on the JVM — where a missing value is `null` rather than an exception. Lyric has no `null` literal and no nullable type, so an `@externTarget` function can declare its return as `Option[T]` (with `T` a reference type) instead:

```lyric
@externTarget("System.Environment.GetEnvironmentVariable")
func getEnvOpt(key: in String): Option[String] = ()
```

The emitter binds the call to the host method's real nullable reference return, then coerces the result at the call boundary: a `null` reference becomes `None`, a non-null reference becomes `Some(value)`. Callers match on `Option[String]` with ordinary `case None` / `case Some(v)` — there is no `null` literal, no nullable type, and no unchecked `case null` pattern (the self-hosted front end has no nullable-match support, so a `String?` extern matched by `case null` would silently miscompile).

The convention applies only to a non-constructor, non-async `@externTarget` function; constructors and async externs use their own return-shaping rules, and a static-field-typed extern (a bare constant read, not a method call) is unaffected. It is implemented identically on both targets — `--target dotnet` and `--target jvm` bind to the host's real reference return and construct `Std.Core.Option`'s `Some`/`None` cases the same way — so a `_kernel/` binding written once against this convention needs no per-target variation. See decision-log entry D107 for the full rationale and D-progress-908 for the JVM emitter parity that completed cross-target support.

## §13.6 AOT compatibility

All Lyric code is AOT-compatible. The compiler generates no calls to `System.Reflection.Emit`, no `Type.GetType(...)`, no `Activator.CreateInstance`. Everything the compiler produces is statically known at build time.

`@generate(Json)` generates a serializer at compile time. `@generate(Sql)` generates a query mapper at compile time. The `wire` block resolves the dependency graph at compile time. None of these require any runtime type introspection.

Native AOT (`lyric build --aot`) produces a self-contained executable. No .NET runtime is required at the deployment site — the runtime is compiled into the binary. This is meaningful for server deployments with strict startup-time budgets, for CLI tools shipped without a runtime prerequisite, and for environments where installing .NET is not practical.

::: sidebar
**Why no reflection?** Reflection is structurally incompatible with opaque types. If you could call `typeof(Account).GetField("balance")`, the opaque guarantee would be advisory at best. Any caller with access to the type's .NET name could inspect its internals without going through the public API. The safety story collapses.

Reflection is also incompatible with Native AOT, which requires knowing at build time which types and members will be accessed at runtime. A runtime-discovered `GetField` call cannot be included in the AOT compilation because the compiler does not know about it until it happens.

Source generators — the compile-time alternative Lyric uses — are more explicit about what they generate, faster (no startup cost), and AOT-safe. The trade is that you must opt in with `@generate`. The decision log entry D006 records this as one of the deliberate design costs.
:::

## §13.7 `Std.Bcl` wrappers

For the common BCL surfaces, you do not write extern declarations yourself. The standard library ships wrappers with reviewed axiom blocks:

- `Std.File` wraps `System.IO.File` — `readText`, `writeText`, `fileExists`, `createDir`
- `Std.Http` wraps `System.Net.Http.HttpClient` — the `HttpClient` interface and its default implementation
- `Std.Time` wraps `System.DateTime` and `System.DateTimeOffset` — `Instant`, `Duration`, `SystemClock`
- `Std.Random` wraps `System.Random` — seeded RNG, `nextInt`, `nextDouble`

Each wrapper has an `@axiom` block in its source that you can read. The axiom strings and contracts are reviewed as part of the Lyric project's CI and release process. If you find an inaccuracy in a stdlib axiom — a postcondition that is not actually guaranteed, a precondition that is too weak — that is a bug worth reporting.

When you write your own `extern` declarations for BCL surface not covered by the stdlib, you take on the same review responsibility. The `docs/17-axiom-audit.md` document lists every axiom shipped in the standard library with rationale and BCL documentation links. It is a useful reference for how to write your own axiom strings.

::: note
**Note:** The standard library axiom blocks are reviewed and stabilised alongside the modules that use them. When a stdlib module is marked `@stable(since="1.0")`, its axiom block is part of that stability commitment — the contracts will not be weakened in a backward-incompatible way.
:::

## §13.8 A complete example

Here is a small but complete example: wrapping a hypothetical .NET CSV parser that the stdlib does not cover.

First, the extern declaration:

```lyric
// csv_extern.l
@axiom("System.Formats.Csv.CsvReader.Parse returns rows where each row is a slice of field strings. Throws ArgumentException on malformed input.")
extern package System.Formats.Csv {
  pub func parse(text: in String): slice[slice[String]]
    requires: text.length >= 0
}
```

Then a Lyric wrapper that converts exceptions to typed errors:

```lyric
// csv.l
@runtime_checked
package Csv

import System.Formats.Csv as RawCsv
import Std.Errors

pub func parse(text: in String): Result[slice[slice[String]], ParseError] {
  return try {
    Ok(RawCsv.parse(text))
  } catch Bug as b {
    Err(ParseError(message = b.message))
  }
}
```
The rest of your application imports `Csv`, not `System.Formats.Csv`. The axiom block is in one place. The exception conversion is in one place. The surface your application depends on is fully typed and exception-free.

## §13.9 Calling BCL methods directly with `import extern` and `.new`

The `extern package` / `@externTarget` style wraps hand-written host signatures. For direct, lightweight calls to a .NET type's **static, instance, or constructor methods**, Lyric provides the `import extern` syntax. This is the preferred FFI mechanism, as it unifies package imports and external imports under one cohesive syntax.

An `import extern` declaration imports host types from external namespaces:

```lyric
import extern System.{ Math as SystemMath, TimeSpan }
import extern System.Text.{ StringBuilder }
```

Calls on these imported names resolve against the reference assemblies (or JDK class files) at compile time. The compiler reads the type's metadata, selects the overload that matches your argument types, and emits the real statically-typed instruction — no hand-written host signature, and no runtime reflection.

Alternatively, `extern type Name = "CLR.Type"` can be used to bind a Lyric name to a CLR type within the package, though `import extern` is preferred.

**Static methods.** Overloads resolve by argument type, including widening (`Int` → `Double`) and `object` parameters:

```lyric
SystemMath.Max(2, 5)        // binds Max(int, int): int  ->  5
SystemMath.Sqrt(9)          // Int widened to double; Sqrt(double): double  ->  3.0
```

**Constructors and the `.new` shorthand.** To instantiate external reference types, call the `.new(args)` pseudo-method. This emits the real CLR `newobj` instruction under the hood, matching the resolved constructor signature:

```lyric
val sb = StringBuilder.new(64)  // constructor shorthand
sb.Append("Hello, world!")
```

**Value types and class types, as parameters and returns.** A method returning a `struct` (value type) or `class` (reference type) is matched by that type's fully-qualified name, and its result flows straight into subsequent calls:

```lyric
// value-type return feeding value-type parameters:
TimeSpan.Compare(TimeSpan.FromMinutes(5.0), TimeSpan.FromMinutes(3.0))   //  ->  1
```

**Instance methods.** When a call's receiver is itself a class-typed extern result, its instance methods dispatch via `callvirt` against the real method:

```lyric
sb.ToString()                 //  ->  "Hello, world!"
```

**Properties, static fields, and constants.** Plain member access on an extern name or extern-typed value resolves CLR properties (the compiler probes the real `get_`/`set_` accessor methods), static fields (`ldsfld` with the field's true type), and literal constants — which are inlined from metadata at their exact bit pattern:

```lyric
import extern System.{ Math }
import extern System.Text.{ StringBuilder }

Math.PI                       // literal R8 constant, inlined at compile time
val sb = StringBuilder.new(8)
sb.Capacity                   // instance property getter (get_Capacity)
sb.Capacity = 64              // instance property setter (set_Capacity)
sb.Length                     // property getter via member access
```

**Value types.** Instance methods and property getters on an extern struct value (`TimeSpan`, `Guid`, `DateTime`, …) dispatch directly — the compiler spills the receiver and calls through its address — and `.new(args)` constructs value types too (a zero-arg `.new()` on a struct with no parameterless constructor yields the zero-initialised default, like C#'s `new Guid()`):

```lyric
import extern System.{ TimeSpan, Guid }

val ts = TimeSpan.FromMinutes(90.0)   // value-type static factory
ts.TotalHours                         // instance property on a struct receiver -> 1.5
val g = Guid.new()                    // zero-initialised default
g == Guid.new()                       // struct equality boxes correctly -> true
```

Resolution is total: if no overload matches your argument types, the call is a compile-time error — it is never silently mis-bound to the wrong method. When a binding genuinely cannot be expressed this way (a method needing narrowing, a `float` parameter, an `out`/`ref` parameter, or an `inout` struct receiver), fall back to an `@externTarget` wrapper as in §13.4.

Because `import extern` and `extern type` resolve against real metadata, they carry no `@axiom` block: the signature is read from the assembly, not asserted by you. The trust boundary is narrower — you are trusting the BCL's documented behaviour of the method you named, not a hand-written signature that could drift from it.
::: note
Calling `System.Type.GetType` yourself through an `import extern` is a direct, statically-emitted `MemberRef` call — not runtime reflection, and fully AOT-compatible. This is distinct from §13.6, which is about the *compiler* never needing reflection to marshal Lyric's own opaque types.
:::

## §13.10 Calling C libraries with `@library`

Some libraries exist only as C: a native GUI toolkit, a codec, a system API. An `extern func` with `@library` calls one directly, on every target:

```lyric
@library("c")
extern func labs(x: Long): Long = "labs"

@library("webview")
extern func webviewCreate(debug: Int, window: NativePtr[Byte]): NativePtr[Byte] = "webview_create"
```

The string after `=` is the C symbol. The `@library` argument is the library's base name: write `"webview"`, and each runtime looks for `libwebview.so`, `libwebview.dylib` or `webview.dll` on its own library path. `"c"` is the C library itself. For a system library whose unversioned name exists only in development packages, give the versioned file name instead (`@library("libm.so.6")`); a name containing `.` or `/` is passed to the loader as written.

Each target calls the symbol its own way. On .NET the declaration becomes a P/Invoke method. On the JVM it becomes a call through the Foreign Function & Memory API, which needs **JDK 22 or later** to run; the handle is looked up on the first call, so a missing library fails at that call rather than when your program starts. On `--target native` the symbol is called directly and the library is linked in.

Only simple values cross the call: `Int`, `Long`, `Byte`, `Float` (a C `float`), `Double` and `NativePtr[T]`, with `Unit` allowed as a result (error T0151 otherwise). A `NativePtr[T]` is an opaque address. Code that holds one must be an `@unsafe_ffi` function (N0100), the same rule as on the native target:

```lyric
@library("c")
extern func malloc(size: Long): NativePtr[Byte] = "malloc"

@library("c")
extern func free(p: NativePtr[Byte]): Unit = "free"

@unsafe_ffi
func scratch(): Unit {
  val p: NativePtr[Byte] = malloc(64)
  free(p)
}
```

Records and callbacks do not cross a C binding on .NET or the JVM. On `--target native` they do: a record with no `var` field whose fields are all values (a `Vec3`, a colour) is passed and returned the way C passes the matching struct on x86-64, AArch64 and wasm32 (Linux and macOS; not Windows, where it is error N0010), so a C function taking a `struct { float x, y, z; }` by value can take your record, and a Lyric closure can be the callback C calls with one. Keep the C surface small, give it pointer-and-integer signatures, and wrap it in a safe Lyric function, as §13.4 does for BCL calls. On `--target dotnet` and `--target jvm` an `extern func` with no `@library` is error T0149.

A C function that takes `const char*` wants a NUL-terminated UTF-8 buffer in C memory, not a Lyric `String`. `Std.Ffi` makes one on every target: `toCString(s)` copies the string into a new buffer on the C heap, and `release(p)` frees it. Going the other way, `tryFromCString(p)` copies a C string back, returning `None` for the null pointer or bytes that are not UTF-8. Release a buffer exactly once, after the C side is done with it:

```lyric
import Std.Ffi as Ffi

@library("webview")
extern func webviewSetTitle(w: NativePtr[Byte], title: NativePtr[Byte]): Int = "webview_set_title"

@unsafe_ffi
func setTitle(w: in NativePtr[Byte], title: in String): Int {
  val c = Ffi.toCString(title)
  val rc = webviewSetTitle(w, c)
  Ffi.release(c)
  rc
}
```

`Std.Ffi` is built from two intrinsics you can use directly for other C data: `nativeLoadByte(p, offset)` reads the byte at `p + offset` and `nativeStoreByte(p, offset, value)` writes one, on all three targets. `Ffi.allocate(size)` gives you C heap memory to use them on. There is no bounds check, which is why they, like every function in `Std.Ffi`, are allowed only in `@unsafe_ffi` code.

## §13.10a C structs with `foreign record`

A C API that takes a descriptor struct needs a Lyric type with the same memory layout. On `--target native`, a kernel file (`_kernel_native/`) declares one with `foreign record`:

```lyric
foreign record WindowDesc {
  width: Int
  height: Int
  scale: Double
  flags: array[4, Byte]
  userdata: NativePtr[Byte]
}
```

A foreign record is a value with no identity. Its fields are `Plain` types, `NativePtr[T]`, `array[N, T]` of those, other foreign records, or a C callback (a function type with a `NativeUserdata` parameter). It cannot be generic and has no `var` fields, defaults, methods or invariants, because C writes its memory without running any Lyric code. It is stored inline, laid out as clang lays out the matching C struct, and passed to `extern func` by value (under the platform C ABI) or by pointer.

Many C APIs take their callback inside a struct, next to the user pointer that is handed back:

```lyric
foreign record RequestInfo {
  mode: Int
  callback: (Int, NativeUserdata) -> Unit
  userdata: NativeUserdata
}

@unsafe_ffi
func ask(): Unit {
  val done: (Int) -> Unit = { status: Int -> Console.println(status.toString()) }
  val info = RequestInfo(mode = 1, callback = done, userdata = done)
  request(info)
}
```

The closure for `callback` has the callback's type without its `NativeUserdata` parameter; the compiler stores the address of a trampoline there, and the same closure stored in the `void*` field is the pointer C passes back to it. Bind the closure to an annotated `val` first, and keep it alive until C has finished calling back.

A `val` or `in` binding is immutable. A `var` local or an `inout` parameter is written field by field in place, so its address can be handed to C:

```lyric
var d = WindowDesc(width = 0, height = 0, scale = 1.0, flags = [0u8, 0u8, 0u8, 0u8], userdata = nativeNullPtr())
d.width = 640
d.flags[2] = 1u8
fill(nativeAddrOf(d))
```

Writing these declarations by hand does not scale to a large C header. `lyric bindgen` generates them from `clang`'s AST: you list the functions, structs and constants you want in an allow-list file and it emits the `extern func`, `foreign record` and `val` declarations, with `NativeUserdata` marking each callback's user pointer:

```sh
lyric bindgen window.h --package Window.Kernel --allow window.allow --library window -o window_kernel.l
```

Commit the output, and run the same command with `--check` in CI to catch a header that has moved on.

A project that binds a C library says where the library is in its manifest, and every application that depends on the project inherits that:

```toml
[native.libs.window]
dir = "native"          # a directory holding libwindow.so (or .dylib / .a), relative to this manifest
# pkg_config = "window" # or: a system library found with pkg-config
```

A library you do not build yourself can be a prebuilt archive per target triple. Pin its SHA-256 in the manifest and run `lyric restore`, which downloads and verifies it into `.lyric/native/` beside the manifest:

```toml
[native.libs.window.prebuilt.x86_64-unknown-linux-gnu]
url     = "https://example.org/window-linux-x86_64.zip"
sha256  = "<64 hex digits>"
members = ["lib/libwindow.so"]
```

The build links the library, copies its shared files next to the executable and adds an `$ORIGIN` run path, so the program runs from its output directory even after the library's original directory is gone.

### A worked binding: `lyric-gpu`

`lyric-gpu` binds wgpu-native, the WebGPU C API, this way: `Gpu.Kernel.Wgpu` is `lyric bindgen` output over `webgpu.h` and `wgpu.h` (the library comes from pinned prebuilt archives, so `lyric restore` is all an application runs), and `Gpu` wraps it so that no pointer reaches the public API. Every GPU object is an opaque `Long` handle; a callback result lands in a record with `var` fields that the callback closure captures; descriptor chains take the first member's address as a `NativePtr[Byte]`, which converts to any typed pointer. A compute pass is a few calls:

```lyric
val d = match Gpu.openDevice() { case Ok(x) -> x; case Err(e) -> panic(e) }
val buf = Gpu.createBuffer(d, 4000, Gpu.usageStorage + Gpu.usageCopyDst + Gpu.usageCopySrc)
Gpu.writeInts(d, buf, 0, input)                       // input: buffer[Int]
val pipeline = Gpu.createComputePipeline(d, wgsl, "main")
```

then `createBindGroup`, `dispatch` and `readInts`. `examples/triangle` renders into an offscreen target and checks the pixels against a golden image; both examples run in CI on a software Vulkan device.

`foreign record` is allowed only in a stdlib `_kernel_native/` package or in a file annotated `@unsafe_ffi` at file level (N0101 elsewhere), and never appears in a library's public API. The kernel's safe wrappers take ordinary Lyric records. `foreign` is a contextual keyword, recognised only directly before `record`.

## §13.11 JavaScript and NPM packages

On the `wasm32` target the foreign boundary is JavaScript rather than the BCL or C. A
`@wasmImport("module") extern func` declares a function the host supplies, and an
`@wasmImport("npm:<package>")` extern binds an export of an installed NPM package; the
`[npm]` table and `lyric restore` manage the packages. Chapter 32 covers both, along
with the module and component output shapes.

## Exercises

1. Write an `extern package System.Console` that wraps `Console.ReadLine()` and `Console.WriteLine(string)`. Provide `requires:` and `ensures:` clauses that reflect what the BCL actually guarantees. Then write a Lyric `Console` package that wraps it, returning `Option[String]` from `readLine()` — `Some(line)` when a line is read, `None` when EOF is reached.

2. The `@axiom` string is a human-readable commitment. Write the most precise axiom string you can for `System.IO.File.ReadAllText`. What does it actually guarantee about the returned string? What conditions does it not guarantee? How does the string change if you restrict the declaration to "paths that exist and the process has read permission for"?

3. An extern function can throw a .NET exception. The `try { } catch Bug` pattern converts it to `Result`. Write a wrapper for a hypothetical `extern func parseCsv(text: in String): slice[slice[String]]` that handles the BCL's `ArgumentException` (produced on malformed CSV) as a `ParseError` and any other exception as an `IoError`. The `Bug` value carries a `message: String`; use it in the error.

4. Compare the exposed record and opaque type marshalling rules. If you receive a .NET `record class` at an extern boundary, what are your options for turning it into a Lyric opaque type with an invariant? Write the constructor that makes the conversion, assuming the invariant is that a field `age` must satisfy `0 <= age <= 150`.

5. Run `lyric build --aot hello.l` and `lyric build hello.l` on the same source file. What files are produced in each case? Which files are present in one output but not the other? What can you infer about the deployment requirements of each?
