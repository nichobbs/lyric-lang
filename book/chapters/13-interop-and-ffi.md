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
**Note:** The bootstrap compiler resolves `extern package` declarations against the `Lyric.Stdlib` F# shim for BCL surface used in Phase 1 examples. Arbitrary BCL types not in that shim produce an `E0030` diagnostic. The full reflection-driven binding, which will let any BCL type be used in an `extern package` block, is a Phase 2 deliverable. For now, reach for the stdlib modules; they cover the common BCL surfaces.
:::

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

This is how `Std.File` is built. Its `@axiom` block is in `compiler/lyric/std/file.l`. The file exports `readText`, `writeText`, `fileExists`, and `createDir` — all returning `Result` or `Bool` — and internally calls the wrapped BCL functions. You can read its source to see exactly what is trusted and what is derived.

::: sidebar
**Why not just catch exceptions everywhere?** Some languages encourage catching `Exception` broadly and converting to a local error type at every call site. This works but erases information: you lose the distinction between "the file was not found" and "the disk is full." The wrapper-package pattern converts BCL exceptions once, at the extern boundary, into a union that names each condition. Callers get exhaustive match coverage and precise error types. The cost is one more source file per BCL surface area; the benefit is a typed error channel across the entire codebase above it.
:::

## §13.5 Cross-boundary marshalling

When Lyric values cross into the BCL and back, the type mapping follows a fixed set of rules.

**Lyric to .NET.** Opaque types pass as sealed opaque handles — a generated .NET type with no public properties and no accessible constructors. Reflection on an opaque handle returns nothing useful; the representation is invisible. Exposed records pass as their generated .NET `record class`, with public fields that match the record's fields. Primitives (`Int`, `Long`, `Double`, `Bool`, `String`) map directly to their .NET counterparts (`int`, `long`, `double`, `bool`, `string`). Slices pass as .NET arrays.

**NET to Lyric.** A .NET type arriving at an extern boundary enters Lyric as an exposed record by default. If you need to validate it and wrap it into an opaque type — re-establishing invariants that the BCL does not enforce — you do that explicitly in a constructor that can return `Result`. There is no implicit coercion.

This asymmetry is intentional. Lyric opaque types carry invariants that the compiler enforced at construction. Accepting a .NET value as an opaque type without validation would silently bypass those invariants. The rule "`.NET → Lyric` requires explicit construction" is what keeps the invariant sound.

For primitive types, there is no marshalling cost. `Int` and `int` have identical runtime representations; the compiler generates no conversion code.

## §13.6 AOT compatibility

All Lyric code is AOT-compatible. The compiler generates no calls to `System.Reflection.Emit`, no `Type.GetType(...)`, no `Activator.CreateInstance`. Everything the compiler produces is statically known at build time.

`@derive(Json)` generates a serializer at compile time. `@derive(Sql)` generates a query mapper at compile time. The `wire` block resolves the dependency graph at compile time. None of these require any runtime type introspection.

Native AOT (`lyric build --aot`) produces a self-contained executable. No .NET runtime is required at the deployment site — the runtime is compiled into the binary. This is meaningful for server deployments with strict startup-time budgets, for CLI tools shipped without a runtime prerequisite, and for environments where installing .NET is not practical.

::: sidebar
**Why no reflection?** Reflection is structurally incompatible with opaque types. If you could call `typeof(Account).GetField("balance")`, the opaque guarantee would be advisory at best. Any caller with access to the type's .NET name could inspect its internals without going through the public API. The safety story collapses.

Reflection is also incompatible with Native AOT, which requires knowing at build time which types and members will be accessed at runtime. A runtime-discovered `GetField` call cannot be included in the AOT compilation because the compiler does not know about it until it happens.

Source generators — the compile-time alternative Lyric uses — are more explicit about what they generate, faster (no startup cost), and AOT-safe. The trade is that you must opt in with `@derive`. The decision log entry D006 records this as one of the deliberate design costs.
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

## Exercises

1. Write an `extern package System.Console` that wraps `Console.ReadLine()` and `Console.WriteLine(string)`. Provide `requires:` and `ensures:` clauses that reflect what the BCL actually guarantees. Then write a Lyric `Console` package that wraps it, returning `Option[String]` from `readLine()` — `Some(line)` when a line is read, `None` when EOF is reached.

2. The `@axiom` string is a human-readable commitment. Write the most precise axiom string you can for `System.IO.File.ReadAllText`. What does it actually guarantee about the returned string? What conditions does it not guarantee? How does the string change if you restrict the declaration to "paths that exist and the process has read permission for"?

3. An extern function can throw a .NET exception. The `try { } catch Bug` pattern converts it to `Result`. Write a wrapper for a hypothetical `extern func parseCsv(text: in String): slice[slice[String]]` that handles the BCL's `ArgumentException` (produced on malformed CSV) as a `ParseError` and any other exception as an `IoError`. The `Bug` value carries a `message: String`; use it in the error.

4. Compare the exposed record and opaque type marshalling rules. If you receive a .NET `record class` at an extern boundary, what are your options for turning it into a Lyric opaque type with an invariant? Write the constructor that makes the conversion, assuming the invariant is that a field `age` must satisfy `0 <= age <= 150`.

5. Run `lyric build --aot hello.l` and `lyric build hello.l` on the same source file. What files are produced in each case? Which files are present in one output but not the other? What can you infer about the deployment requirements of each?
