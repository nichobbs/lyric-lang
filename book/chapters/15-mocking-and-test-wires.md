# Mocking and Test Wires

Runtime mocking frameworks work via reflection. They intercept method calls on proxy objects generated at startup, match call signatures with dynamic string comparisons, and return pre-configured values. Lyric has no reflection (D006), so they cannot exist. What Lyric has instead is `@stubbable` — a compiler directive that generates typed stub builders at compile time — and multiple wire blocks for different deployment configurations. The result is compile-time-checked, AOT-safe test isolation.

This chapter covers the full stub API, how to assemble a test wire, and how to assert on recorded calls. If you have not read Chapter 11 yet, skim §11.2 through §11.5 first — test wires are just wire blocks, and this chapter assumes you are comfortable with the wire syntax.

## §15.1 The problem with reflection-based mocking

In Mockito or Moq you write something like:

```java
// Java / Mockito
when(repo.findById(42L)).thenReturn(Optional.of(alice));
```

This looks typed, but the binding between `findById` and its stub is a string match under the hood. If you rename the method, add a parameter, or change its return type, the `when(...)` call continues to compile. The test breaks at runtime — possibly much later if the test only exercises a happy path. In a large codebase with hundreds of mocks, a refactor that should be mechanical becomes archaeology.

Lyric's `@stubbable` stubs are generated from the interface definition. A stub configuration is ordinary Lyric code that calls the interface's methods through a builder. Changing the interface signature is a compile error in the stub configuration, not a runtime surprise. The stub is as type-safe as the production code that calls the interface.

## §15.2 `@stubbable` interfaces

Annotate any interface with `@stubbable` to direct the compiler to emit a corresponding stub builder:

```lyric
@stubbable
pub interface AccountRepository {
  async func findById(id: in AccountId): Account?
  async func saveAll(accounts: in slice[Account]): Unit
}

@stubbable
pub interface IdempotencyStore {
  async func lookup(key: in IdempotencyKey): TransferReceipt?
  async func store(key: in IdempotencyKey, receipt: in TransferReceipt): Unit
}

@stubbable
pub interface Clock {
  func now(): Instant
}
```

For each `@stubbable` interface `Foo`, the compiler emits a type `FooStub` in the same package. Import it alongside the interface:

```lyric
import Repositories.{AccountRepository, AccountRepositoryStub}
import Repositories.{Clock, ClockStub}
```

The generated stub type implements the interface, so it can be used anywhere the interface is expected: in a `wire` binding, as a direct argument, or as a field in a record.

::: note
**Note:** `@stubbable` is for interfaces only. You cannot apply it to a record, opaque type, or function. If you find yourself wanting a stub for a concrete type, the usual answer is to extract an interface for the behavior you want to isolate.
:::

## §15.3 Stub builders

Each generated stub type has three entry points: `.returning { ... }`, `.recording()`, and `.failing { ... }`.

### Fixed return values

When you want the stub to always return the same value for a given call pattern, use `.returning`:

```lyric
val clockStub = ClockStub.returning {
  it.now() -> Instant.fromIso8601("2026-01-01T00:00:00Z").unwrap()
}
```

Inside the `{ ... }` block, `it` is a typed proxy through which you describe each case. The left side is a method call on `it`; the right side is the return value. Pattern matching on arguments uses `_` as a wildcard:

```lyric
val repoStub = AccountRepositoryStub.returning {
  it.findById(alice.id) -> Some(alice)
  it.findById(bob.id)   -> Some(bob)
  it.findById(_)        -> None
}
```

Cases are tested top to bottom; the first matching case wins. An unmatched call — a call that falls off the end with no matching case — raises a `Bug` and fails the test immediately. This is intentional: an unmatched call means your test configuration is incomplete, and silent returns would produce confusing failures downstream.

### Recording and fixed returns combined

`.recording()` starts a stub that records every call. You can chain `.returning` onto it to configure return values:

```lyric
val repoStub = AccountRepositoryStub.recording()
    .returning {
      it.findById(alice.id) -> Some(alice)
      it.findById(bob.id)   -> Some(bob)
      it.findById(_)        -> None
    }
```

The stub now both records calls and returns configured values. Without the `.returning` chain, a plain `.recording()` stub raises a `Bug` on any call — useful when you only want to verify that a method is _not_ called.

### Always-failing stubs

`.failing` configures a stub that returns error values or raises `Bug`s for specified methods:

```lyric
val failingRepo = AccountRepositoryStub.failing {
  it.findById(_)  -> Err(DatabaseError("connection refused"))
  it.saveAll(_)   -> Err(DatabaseError("connection refused"))
}
```

The return type of the failing case must match the method's declared return type. The compiler checks this; returning an `Err` from a method that returns `Account?` (not a `Result`) is a type error.

::: sidebar
**Why not support runtime mocking?** Because it depends on reflection (D006), which Lyric bans. But even ignoring the language constraint, statically-typed stubs are strictly better: they catch interface changes at compile time, they are AOT-compatible, and they make test setup readable in isolation. A Mockito-style `when(repo.findById(eq(42L))).thenReturn(alice)` is harder to follow than a `.returning` block because the argument matchers, the return value, and the control flow are all entangled in a single call chain.

The perceived limitation — "I need different behavior per test" — is solved by parameterising your `wire` block with `@provided` values. Each test bootstraps the wire with different inputs; the stub behavior follows from those inputs naturally.
:::

## §15.4 Asserting on recorded calls

After the test has run, query the stub's recording with `.recorded(methodName)`:

```lyric
val calls = repoStub.recorded("saveAll")
assertEqualInt(calls.length, 1, "saveAll called exactly once")
```

`recorded` returns a `slice` of call records. Each record exposes:

- `.args` — a `slice[Any]` of the arguments passed in that call. The slice is positionally indexed, and you can compare values with `==` after casting to the declared type.
- `.callIndex` — the order in which this call was made (zero-indexed, across all methods on the same stub).

To assert on the actual argument values:

```lyric
val calls = repoStub.recorded("saveAll")
assertEqualInt(calls.length, 1, "saveAll called once")

val savedAccounts = calls[0].args[0] as slice[Account]
assertEqualInt(savedAccounts.length, 2, "two accounts saved")
expect(savedAccounts[0].id == alice.id)
expect(savedAccounts[1].id == bob.id)
```

The `as` cast is necessary because `.args` is untyped at the `slice[Any]` level. If the cast fails, it raises a `Bug` and fails the test clearly. The compiler cannot verify the cast statically — this is one of the few places where you pay a small runtime cost for the convenience of the generic recording API.

::: note
**Note:** `.recorded(name)` returns an empty slice if the method was never called. It does not fail. An `assertEqualInt(calls.length, 1, ...)` on an empty slice fails with `actual: 0, expected: 1`, which is the right signal.
:::

## §15.5 Test wires

For testing a service with multiple dependencies, assemble a `wire` block inside your `@test_module` package. It works exactly like a production wire — the same syntax, the same resolution rules, the same lifetime semantics. The only differences are that it is invisible to production builds and that it uses stubs instead of real implementations.

Here is a complete test wire for the banking transfer service from the worked examples:

```lyric
// transfer_test.l
@test_module
package TransferService

import Std.Testing
import Account.{Account, AccountId}
import Money.{Amount, Cents}
import Time.Instant
import TransferService.{TransferService, transfer, IdempotencyKey, IdempotencyStore}
import Repositories.{AccountRepository, AccountRepositoryStub,
                     IdempotencyStore, IdempotencyStoreStub,
                     Clock, ClockStub}

wire TestWire {
  @provided alice: Account
  @provided bob: Account
  @provided fixedNow: Instant

  singleton accounts: AccountRepository =
      AccountRepositoryStub.recording()
          .returning {
            it.findById(alice.id) -> Some(alice)
            it.findById(bob.id)   -> Some(bob)
          }

  singleton idempotency: IdempotencyStore =
      IdempotencyStoreStub.recording()
          .returning { it.lookup(_) -> None }

  singleton clock: Clock =
      ClockStub.returning { it.now() -> fixedNow }

  singleton svc: TransferService = TransferService.make(accounts, idempotency, clock)

  expose svc
  expose accounts    // so tests can inspect the recording
}

test "successful transfer saves both accounts" {
  val alice  = makeAccount(id = "A", balance = 1_000_00)
  val bob    = makeAccount(id = "B", balance = 0)
  val now    = Instant.fromIso8601("2026-04-29T00:00:00Z").unwrap()

  val w      = TestWire.bootstrap(alice, bob, now)
  val key    = IdempotencyKey.tryFrom("op-1").unwrap()
  val amount = Amount.make(Cents.tryFrom(100_00).unwrap()).unwrap()

  val result = await transfer(w.svc, alice.id, bob.id, amount, key)
  assertTrue(result.isOk, "transfer should succeed")

  val saveCalls = w.accounts.recorded("saveAll")
  assertEqualInt(saveCalls.length, 1, "saveAll called exactly once")
}
```

Walk through the structure:

`@provided` values are parameters to the generated `TestWire.bootstrap(...)` function. Each call to `bootstrap` produces a fresh, independent wire instance with its own stub state. Two calls with different arguments do not share stubs.

The `singleton accounts` line uses `AccountRepositoryStub.recording().returning { ... }`. The `returning` block captures `alice` and `bob` from `@provided` — they are in scope. The compiler verifies that the arguments to `it.findById` match the method's declared parameter type, and that the return values (`Some(alice)`, `Some(bob)`) match the declared return type `Account?`.

`expose accounts` makes `w.accounts` accessible in the test. Without `expose`, the stub is private to the wire. You typically expose any stub you plan to interrogate.

If you change `findById`'s signature in `AccountRepository` — say, you add a second parameter `locale: in Locale` — the `.returning` block is a compile error. There is no way to run a test with a misconfigured stub.

## §15.6 Testing async code

`await` works inside `test` blocks exactly as it does in production code. The test runner handles the `.GetAwaiter().GetResult()` call that bridges the synchronous test frame to the async operation. You do not need any special annotations on a test block to use `await`:

```lyric
test "async transfer completes" {
  val w      = TestWire.bootstrap(alice, bob, now)
  val result = await transfer(w.svc, alice.id, bob.id, amount, key)
  assertTrue(result.isOk, "transfer result")
}
```

Structured concurrency (`spawn`, `scope`) also works inside test blocks, which means you can test concurrent behavior directly. The test runner captures any `Bug` raised in a spawned task and attributes it to the enclosing test.

If a test block contains `await` and you are running `lyric test` without a running async runtime, the test runner initializes one automatically. There is no per-test setup to write.

## §15.7 Comparison with Mockito and Moq

The differences are worth stating plainly, because the implications go beyond syntax:

| Concern | Lyric stubs | Mockito / Moq |
|---|---|---|
| Argument matching | Statically typed; compile error if wrong type | Dynamically typed; runtime failure |
| Signature changes | Compile error in stub configuration | Silently continue until test runs |
| AOT compatibility | Yes | No (reflection required) |
| Unmatched calls | `Bug` at test time | Silent return of zero value (Moq) or exception (Mockito strict) |
| Call recording | Built into `.recording()` | Separate `verify(...)` DSL |
| Test isolation | Wire bootstrap produces fresh stubs per call | Manual `reset(mock)` between tests |

The last row is worth dwelling on. Because each `TestWire.bootstrap(...)` call returns a new wire instance with new stub instances, you never have to worry about state leaking between tests. The stubs are value-like: fresh on construction, independent of everything else. In Mockito or Moq, shared mock objects require explicit reset calls between tests, and forgetting them causes ordering-dependent test failures that are hard to reproduce.

The tradeoff is that Lyric stubs are somewhat less flexible at the individual test level. You cannot configure per-invocation behavior where the third call behaves differently from the first without writing that logic explicitly. For most production scenarios this is not a real constraint; it becomes one mainly when testing retry logic or back-pressure behavior, where the workaround is to parameterize your `@provided` values or to use a hand-written implementation of the interface for that specific test.

## Exercises

1. **Mailer stub**

   Declare `@stubbable pub interface Mailer { func send(to: in String, body: in String): Result[Unit, MailError] }`. Write a service `NotificationService` that calls `mailer.send` once per notification. Write a test that bootstraps the service with a recording `MailerStub`, sends a notification, and asserts that `.recorded("send")` has exactly one entry with the expected `to` address.

2. **Unmatched call failure**

   Configure an `AccountRepositoryStub.returning { it.findById(alice.id) -> Some(alice) }` and then call it with an id that is not `alice.id`. Observe the `Bug` output. Note what it tells you about which method was called and with which argument. Then decide whether you should add a wildcard case (`it.findById(_) -> None`) or whether the unmatched call reveals a real problem in the code under test.

3. **Independent bootstrap instances**

   Call `TestWire.bootstrap(alice, bob, now)` twice within the same test, storing the results as `w1` and `w2`. Call a method through `w1.svc`. Assert that `w1.accounts.recorded("saveAll").length == 1` and `w2.accounts.recorded("saveAll").length == 0`. This confirms that the two bootstrap calls produce independent stubs.

4. **Asserting on argument values**

   Extend the transfer test to inspect the actual accounts passed to `saveAll`. After the transfer completes, retrieve the saved accounts from `calls[0].args[0]` and verify that the deducted amount appears on one account and the credited amount on the other. Cast the argument to `slice[Account]` and use `assertEqual` on each account's balance.

5. **Signature change propagation**

   Change `AccountRepository.findById` to accept a second parameter: `async func findById(id: in AccountId, includeArchived: in Bool): Account?`. Build the project. Observe every location that fails to compile — the production `impl`, the stub configuration in `TestWire`, and any direct calls in test blocks. Work through the compile errors in order. Notice that the compiler tells you every affected site before you run a single test.
