# Error Handling

Lyric draws a clear line between two kinds of bad things that can happen in a program: errors that the caller should be prepared to handle, and bugs that indicate something fundamentally wrong. The first category is expressed in return types; the second terminates the current operation. This distinction changes how you write code, and for the better.

If you are coming from Java or C#, you are used to exceptions covering both categories. A `FileNotFoundException` is a recoverable condition you might want to try again with a fallback path. A `NullPointerException` is a sign that something is wrong with the program itself. Both arrive through the same `catch` syntax, both appear in the same stack traces, and both are routinely swallowed by `catch (Exception e) { log.error(e) }` handlers that have given up trying to distinguish them. Lyric's design gives each category a different mechanism.

Chapter 8 covers contracts — `requires` and `ensures` clauses — which is where bugs originate when they come from violated preconditions. This chapter is about the `Result` side of the boundary.

## Two error categories

**Recoverable errors** are conditions the caller ought to handle. The account might not exist. The amount might be invalid. The network might be unavailable. These conditions are an expected part of the domain. You express them in the return type: a function that might fail returns `Result[T, E]`. The caller must handle or propagate it — there is no way to ignore it accidentally.

**Bugs** are conditions that indicate the program is wrong. A contract violation (a `requires:` check fires), an array bounds violation, an integer overflow, an explicit `panic("invariant broken")`. These do not belong in return types. They propagate like unchecked exceptions, and catching them in normal application code is a code smell. The compiler emits a warning if you do it gratuitously.

The test for which category applies: "is this something a caller could handle gracefully?" If yes, it is a `Result`. If not — if the right response is to abort what was happening and alert a human — it is a bug.

## `Result[T, E]`

`Result` is a union type defined in `std.core`:

```lyric
union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}
```

You define a domain-specific error union for each package, containing exactly the cases a caller needs to distinguish:

```lyric
pub union TransferError {
  case InsufficientFunds
  case AccountNotFound(id: AccountId)
  case SameAccount
}

pub func transfer(
  from: in Account,
  to: in Account,
  amount: in Amount
): Result[(Account, Account), TransferError] {
  ...
}
```

The function signature is a contract: this operation might fail in one of three ways. The caller must deal with all three. Pattern matching is the natural way:

```lyric
match transfer(from, to, amount) {
  case Ok((newFrom, newTo)) -> saveAll([newFrom, newTo])
  case Err(InsufficientFunds) ->
      HttpResponse.unprocessable("insufficient funds")
  case Err(AccountNotFound(id)) ->
      HttpResponse.notFound("account not found: ${toString(id)}")
  case Err(SameAccount) ->
      HttpResponse.badRequest("cannot transfer to same account")
}
```

The exhaustiveness check from Chapter 5 applies here. If you add a `DestinationClosed` case to `TransferError`, every `match` in the codebase that covers `TransferError` fails to compile until you handle it. This is the same guarantee you saw with unions in general — it applies equally to error unions.

::: note
**Note:** Any type used as the `E` in `Result[T, E]` must implement the `Error` interface from `std.core`. For union types, the compiler auto-derives an `Error` implementation from each variant's name and payload. You can override this with an explicit `impl Error for MyError` if you want a custom message format.
:::

## The `?` operator

Explicitly matching every `Result` on every call would be exhausting in a function that chains several fallible operations. The `?` operator handles propagation automatically:

```lyric
func processTransfer(req: TransferRequest): Result[Receipt, TransferError] {
  val from = AccountId.tryFrom(req.fromId)?
  val amount = Amount.make(req.amountCents)?
  val (newFrom, newTo) = transfer(from, req.toId, amount)?
  return Ok(makeReceipt(newFrom, newTo))
}
```

On each line with `?`: if the expression is `Ok(v)`, the `?` unwraps it to `v` and execution continues. If it is `Err(e)`, the enclosing function immediately returns `Err(e)`. The early return happens at the operator site; there is no need to write it explicitly.

Two requirements apply. The enclosing function must return `Result` — the compiler rejects `?` in a function with a non-`Result` return type (this is D027 in the decision log; using `?` in a non-Result context would turn explicit error propagation into a hidden panic, which is exactly the confusion the distinction is meant to prevent). The error type must be compatible — if `AccountId.tryFrom` returns `Result[AccountId, ParseError]` but the function returns `Result[Receipt, TransferError]`, the types must match or you need to convert.

Converting error types uses `.mapErr`:

```lyric
val dbUrl = Url.tryFrom(raw.databaseUrl)
    .mapErr { _ -> InvalidUrl("databaseUrl", raw.databaseUrl) }?
```

`.mapErr` takes a closure from the original error type to the new one. Here, any parse failure in `Url.tryFrom` becomes an `InvalidUrl` error in the caller's error type. The `?` then propagates that converted error if needed.

You will see this pattern any time errors cross a package boundary — domains define their own error types, and the conversion point is explicit in the code rather than hidden.

::: sidebar
**Why no `raises:` declaration?** Java's checked exceptions were an attempt to put recoverable errors in the signature — the right instinct — but the mechanism failed. `throws IOException` does not tell you which operations throw, or how to compose multiple operations that each throw different types. Refactoring a method changes what it throws, which breaks callers. Lambdas and higher-order functions required the `@FunctionalInterface`-with-sneaky-throw workarounds that everyone eventually learned. The `RuntimeException` escape hatch swallowed the whole system.

`Result[T, E]` is a typed value. You can `map` it, `mapErr` it, `flatMap` it, and pattern-match on it. The compiler's exhaustiveness check replaces the "did I catch everything?" problem entirely. The call site tells you the error type, not just that something might throw. See D007 in the decision log for the full history.
:::

## `Option[T]` and nullable

For values that may legitimately be absent — a database lookup that might find nothing, a configuration key that is optional — use `Option[T]`:

```lyric
union Option[T] {
  case Some(value: T)
  case None
}
```

The distinction between `Option` and `Result` is intent. `Option[T]` says "this value might not be there, and that is normal." `Result[T, E]` says "this operation might fail, and here is how." A database lookup that returns nothing is `Option`; a database lookup that fails with a connection error is `Result`.

In practice, many functions combine both: a lookup returns `Result[Option[Account], DbError]` — it might fail with a connection error (recoverable, the caller should retry or fail gracefully), or it might succeed but find nothing (the account does not exist).

The `??` null-coalescing operator provides a default when an `Option` is `None`:

```lyric
val displayName = user.nickname ?? user.email
```

If `user.nickname` is `Some(name)`, the expression evaluates to `name`. If it is `None`, it evaluates to `user.email`. `??` also works with nullable `T?` types — a `String?` that is `null` falls through to the right-hand side.

`?` on an `Option[T]` propagates `None` from the enclosing function if the option is absent. The enclosing function must return a compatible `Option` or nullable type.

## Bugs

Bugs in Lyric are raised by:

- **Contract violations**: a `requires:` precondition fires at a call site, or an `ensures:` postcondition fires on return
- **Invariant violations**: an opaque type's invariant is not satisfied
- **Array bounds violations**: accessing an index outside the array's length
- **Integer overflow**: in debug builds, or always for range-constrained types
- **`unwrap()` on `Err` or `None`**: explicit "I know this can't fail" that turns out to be wrong
- **Explicit `panic("message")`**: programmer-triggered abort

Bugs propagate like unchecked exceptions. They abort the current operation and propagate up the call stack. In an `async` task, they propagate to the task's awaiter or to the structured scope that owns the task. If a `protected type` entry raises a bug, the entry aborts without committing state changes.

Catching bugs is possible with `try`/`catch Bug`, but it is a robustness boundary pattern — appropriate at the perimeter of a system, not in ordinary application logic:

```lyric
// fs.l — wrapping a BCL call that might throw for any reason
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

Here the `try`/`catch Bug` is the translation boundary between .NET BCL semantics (which may raise arbitrary exceptions) and Lyric semantics (which uses `Result` for recoverable errors). The wrapper converts any unexpected failure into an `IoError`. Callers of `readBytes` deal with a typed `Result`, not with the possibility of a BCL exception leaking through. This pattern appears in Example 8 of the worked examples.

The compiler emits a warning on `catch Bug` outside of recognised boundary contexts. If you find yourself catching bugs in the middle of application logic, the right response is usually to ask why the bug was raised — either the contract is wrong, the input validation is missing, or the code has a genuine defect.

**`unwrap()`** asserts that a `Result` is `Ok`, raising a bug if it is `Err`:

```lyric
// Fine — the PEM string is a compile-time constant; a bug here means the
// constant itself is wrong, not a runtime condition
val cert = Cert.parse(HARDCODED_PEM).unwrap()

// Wrong — user input can fail; use match or ? instead
val id = AccountId.tryFrom(req.userId).unwrap()  // panics on malformed input
```

`unwrap()` is appropriate when you have a value that cannot be `Err` by construction, and you want the program to fail loudly if your reasoning turns out to be wrong. It is not appropriate for user input, for I/O results, or for anything that could plausibly fail in normal operation.

## Error design guidelines

A few conventions that emerge from experience with `Result`-based error handling.

**Define error unions per package, not globally.** A `pub union TransferError` in the `Transfer` package describes exactly the ways a transfer can fail. A shared `AppError` that accumulates every possible failure across the whole codebase becomes an unstructured `Exception` analog — it tells callers nothing useful.

**Each case carries exactly the data the caller needs.** `AccountNotFound(id: AccountId)` carries the ID that was not found, because callers need it to produce a sensible message. `InsufficientFunds` carries nothing, because callers do not need to know the balance — they just need to know the transfer failed. Over-engineering error payloads is as much a problem as under-engineering them.

**Error unions are `pub` when callers handle them, package-private when they do not.** A `ValidationError` that is fully handled inside a package before anything is returned to callers does not need to be `pub`. Only export what callers need to match on.

**Convert at package boundaries with `.mapErr`.** When errors cross a package boundary, the conversion point is the boundary function. The downstream package should not need to import the upstream package's error type just to propagate it unchanged.

**Reserve `panic` for programmer mistakes.** `panic` means "the program's invariants are violated; aborting is the only safe option." It is appropriate when a required-to-be-valid internal state is not valid. It is not appropriate for anything a user input or external system could cause.

## Exercises

1. Write a `union ValidationError { case Empty; case TooLong(max: Int, actual: Int); case InvalidChar(c: Char) }` and a `func validateUsername(s: in String): Result[String, ValidationError]` that rejects empty strings, strings over 20 characters, and strings containing non-alphanumeric characters. Pattern-match on the result in a caller and produce a human-readable message for each case.

2. Write three functions that each return a `Result` with a different error type. Write a fourth function that calls all three in sequence using `?` and `.mapErr` to convert all errors to a common `union AppError { ... }`. Observe what the compiler says if you forget to convert one of the error types before applying `?`.

3. Write a function where `unwrap()` is justified — for example, parsing a compile-time constant string as a URL. Write a second function where `unwrap()` on the same operation would be wrong — where the value comes from user input. Explain the difference in one sentence.

4. The `??` operator provides a default value for `Option[T]`. Write a function `firstNonEmpty(xs: in slice[Option[String]]): String` that returns the first `Some` value, or `"none"` if all are `None`. Use `??` in the loop body.

5. Write a `try { } catch Bug` block that wraps a function call which might raise a bug, and converts the bug into a `Result`. Then ask yourself: does the function being called have a contract violation that should be fixed instead? In which cases is the `catch Bug` wrapper the right answer, and in which is it hiding a defect?
