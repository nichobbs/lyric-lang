# Dependency Injection

Most runtime DI frameworks in Java and C# do two things: they describe a graph of object dependencies, and they resolve that graph when the application starts. Lyric does both at compile time. The `wire` block is a language construct — not a framework, not an annotation processor, not reflection. The dependency graph is checked for completeness and cycles before a line of code runs.

If you have used Spring, ASP.NET Core's built-in DI container, or Guice, the wire block will feel familiar in purpose but different in character. You are still declaring what depends on what. The difference is that the compiler does the resolution, and a broken configuration is a compiler error — not a startup exception, not a runtime failure at first use.

## §11.1 The problem with runtime DI

Runtime DI containers resolve dependencies via reflection. When the application starts, the container scans for registrations, builds the graph, and starts constructing objects. This means:

- A missing binding is discovered at startup, not at compile time. In a large service, startup might take thirty seconds. Your CI pipeline runs, the service starts, it crashes on the DI resolution, and you find out minutes later.
- A lifecycle mismatch — a singleton holding a reference to a request-scoped object — is discovered when the request-scoped object is garbage collected or when you notice stale data. Some containers detect this, but not all, and not always.
- The graph exists only in the container's memory, not in the source code. Reading the codebase, you cannot easily determine what implements a given interface, or which objects share a lifetime.

Lyric's reflection ban (D006) makes runtime DI containers impossible anyway — there is no `Type.GetMethods()` to call, no proxy class generation at startup. The `wire` block is not a workaround; it is the right design given Lyric's constraints.

## §11.2 Interfaces

Before seeing the wire block, you need interfaces, because wires are built on them. An interface in Lyric declares a set of operations without an implementation:

```lyric
pub interface AccountRepository {
  async func findById(id: in AccountId): Account?
  async func saveAll(accounts: in slice[Account]): Unit
}

pub interface Clock {
  func now(): Instant
}
```

An implementation is declared with `impl`:

```lyric
impl AccountRepository for PostgresAccountRepository {
  async func findById(id: in AccountId): Account? {
    // ... query the database ...
  }

  async func saveAll(accounts: in slice[Account]): Unit {
    // ... write to the database ...
  }
}
```

The type `PostgresAccountRepository` must provide every method declared in `AccountRepository`, with matching signatures. The compiler enforces this.

One detail worth knowing: if you have a synchronous function that satisfies an `async`-declared interface method, the compiler lifts it automatically (D031). A test stub that returns a pre-built value does not need to write `Task.fromValue(...)` boilerplate — `func findById(...): Account?` satisfies `async func findById(...): Account?`. The lift is zero-cost on the synchronous path.

::: note
**Note:** Interfaces appear here in Chapter 11 because the wire block is their primary use case. They also work as ordinary polymorphism outside of wires — a function can accept an `AccountRepository` parameter directly, without a wire — but the DI context is where they matter most.
:::

## §11.3 The wire block

A `wire` block declares a dependency graph. Here is the production wire from the banking example:

```lyric
// composition.l
package App

wire ProductionApp {
  @provided config: AppConfig
  @provided cancellationToken: CancellationToken

  singleton clock: Clock = SystemClock.make()
  singleton db: DatabasePool = DatabasePool.make(config.dbUrl, config.dbPoolSize)
  singleton redis: RedisClient = RedisClient.make(config.redisUrl)

  scoped[Request] dbConnection: DatabaseConnection = db.acquire()
  scoped[Request] requestId: RequestId = RequestId.generate()

  bind AccountRepository -> PostgresAccountRepository.make(dbConnection)
  bind IdempotencyStore -> RedisIdempotencyStore.make(redis)
  bind Clock -> clock

  singleton transferService: TransferService =
      TransferService.make(AccountRepository, IdempotencyStore, Clock)

  expose transferService
}
```

Each declaration kind has a distinct meaning.

**`@provided`** names a value that comes from outside the wire. These become parameters to the generated bootstrap function. You supply them when the application starts: `config` from your configuration loader, `cancellationToken` from your host.

**`singleton`** constructs a value once per wire instance and caches it. `db` is constructed once and reused by everything that depends on it. Singletons are appropriate for stateless helpers, connection pools, and services that hold no per-request state.

**`scoped[X]`** constructs a value once per scope of type `X`. `scoped[Request] dbConnection` means a new `DatabaseConnection` is acquired for each incoming HTTP request, and released when the request scope ends. Built-in scopes are `[Request]`, `[Transaction]`, and `[Session]`. You can declare your own (see §11.6).

**`bind I -> impl`** registers `impl` as the resolution of interface `I` within this wire. When `TransferService.make` is called with `AccountRepository` as an argument, the wire substitutes `PostgresAccountRepository.make(dbConnection)`. The `bind` line is the only place this substitution is declared.

**`expose`** makes a value accessible from outside the wire instance. Unexposed values are internal to the wire — callers cannot reach them directly.

The compiler checks four things at compile time:

1. **All dependencies are satisfied.** If `TransferService.make` requires an `AccountRepository` and there is no `bind AccountRepository -> ...` line, the wire fails to compile with a specific error naming the unsatisfied dependency.
2. **No cycles.** If A depends on B and B depends on A, the compiler reports the full cycle path and refuses to compile.
3. **No lifetime violations.** A `singleton` cannot depend on a `scoped[X]` value. A wider-lifetime value cannot hold a reference to a narrower-lifetime one. This is the captive-dependency bug that Spring users have been burned by for years — in Lyric, it is a compile error.
4. **All `bind` targets implement the declared interface.** `bind AccountRepository -> PostgresAccountRepository.make(dbConnection)` requires that the return type of `PostgresAccountRepository.make(dbConnection)` satisfies `AccountRepository`. The compiler checks the impl, not just the name.

::: sidebar
**Why compile-time DI?** The most common DI bugs — a missing binding, a singleton depending on a request-scoped object, the wrong implementation registered — are all detectable with a complete description of the graph. Runtime containers detect them at startup, or worse, at first use of the object. A wire block that does not compile never ships a broken configuration.

The tradeoff is that the wire is static: you cannot add or swap bindings at runtime without recompiling. For the services Lyric targets — long-running backend services where configuration is a deployment concern, not a runtime concern — this is the right trade. D008 records the full reasoning.
:::

## §11.4 What the compiler generates

The wire block compiles to a module with a `bootstrap` function and accessor properties for each exposed value. You use it like this:

```lyric
// Program entry point
func main(): Unit {
  val config = AppConfig.load(RawConfig.readFromEnvironment()).unwrap()
  val app = ProductionApp.bootstrap(config, CancellationToken.none())
  // app.transferService is the resolved TransferService
  HttpServer.run(app.transferService, config.port)
}
```

`ProductionApp.bootstrap` takes the `@provided` values as arguments and returns a wire instance. The wire instance has a field for each `expose`d value. Every singleton has already been constructed; every `bind` has been resolved. The body of `bootstrap` is straight-line factory code — no reflection, no dynamic dispatch, no graph traversal at runtime.

For `scoped` values, the wire generates scope entry and exit calls that the host integration framework invokes per scope boundary. Within an active `[Request]` scope, `dbConnection` is available; outside one, accessing it is a compile error.

## §11.5 Multiple wires

A program can declare multiple wires. The most common pattern is a production wire and a test wire that substitutes stub implementations:

```lyric
// transfer_test.l
@test_module
package TransferService

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
  expose accounts    // tests inspect the recording
}

test "successful transfer credits the destination" {
  val alice = makeAccount(id = "A", balance = 1_000_00)
  val bob   = makeAccount(id = "B", balance = 0)
  val now   = Instant.fromIso8601("2026-04-29T00:00:00Z").unwrap()

  val w = TestWire.bootstrap(alice, bob, now)
  val key = IdempotencyKey.tryFrom("op-1").unwrap()
  val amount = Amount.make(Cents.tryFrom(100_00).unwrap()).unwrap()

  val receipt = await transfer(w.svc, alice.id, bob.id, amount, key)
  expect(receipt.isOk)
  expect(w.accounts.recorded("saveAll").length == 1)
}
```

The test wire is just another `wire` block — there is no special syntax for tests. It lives in a `@test_module` package and is invisible to the production build.

The stub builders (`AccountRepositoryStub`, `IdempotencyStoreStub`, `ClockStub`) are generated by `@stubbable` annotations on the interfaces. Chapter 15 covers `@stubbable` and the stub API in detail. For now, the key point is that the stubs are statically typed: if you change the signature of `findById` in `AccountRepository`, the `.returning` call in the test wire fails to compile. There is no runtime `MethodNotFoundException`, no string-based method matching, no dynamic proxy.

Multiple wires can coexist in the same package — production, test, integration, staging — and each is independently checked. They may share interfaces but not instances.

## §11.6 Scope kinds

Built-in scopes are `[Request]`, `[Transaction]`, and `[Session]`. You can declare additional scope kinds:

```lyric
scope_kind Tenant
```

This declares `Tenant` as a scope kind that can be used in `scoped[Tenant]` declarations within any wire in the package.

Scopes are entered and exited via host integration. An HTTP framework integrates `[Request]` automatically: at the start of each request, the framework enters the request scope; at the end, it exits it and releases all `scoped[Request]` resources. `[Transaction]` is managed by database integrations the same way.

For custom scope kinds like `Tenant`, you control entry and exit explicitly in the host code that manages your application's scope boundaries. The compiler knows what is scoped to `Tenant` and ensures that code outside an active `Tenant` scope cannot reach `scoped[Tenant]` values.

Scope state propagates across `await` boundaries via .NET's `AsyncLocal<T>`. When a `scoped[Request]` value is resolved inside an async function, the active scope is the one that was current when the request started — even if several `await` expressions have intervened.

## Exercises

1. Create a `wire` with a missing binding: declare a `singleton` for a service that depends on an interface, but do not add a `bind` entry for that interface. Build the project and read the compile error. It should name the unsatisfied dependency precisely.

2. Introduce a lifetime violation: declare a `singleton` that depends on a `scoped[Request]` value. What error does the compiler produce? What does it tell you about which value has the wrong scope?

3. Create a cycle: declare service A that depends on service B, and service B that depends on service A. The compiler should report the cycle as a path. Fix it by introducing an interface that breaks the direct dependency.

4. Write a `TestWire` for a service with three interface dependencies. Implement each dependency as a simple hand-rolled struct — a record with the right fields — that satisfies the interface without using stub builders. Bootstrap the wire in a test and call the service.

5. Declare a custom `scope_kind Batch` and add a `scoped[Batch]` value to a wire. What does the compiler require you to provide at the scope entry site? Try accessing the scoped value from outside an active `Batch` scope and observe the error.
