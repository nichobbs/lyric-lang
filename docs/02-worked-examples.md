# 02 — Worked Examples

Non-trivial Lyric programs demonstrating the language in realistic use. These programs compile against the proposed v1 feature set; they are the source of truth for "what does Lyric actually look like in practice."

## Example 1: Banking transfer service

A REST-fronted service for transferring funds between accounts, with idempotency, balance invariants, and end-to-end contract enforcement. The domain layer is `@proof_required`; the application layer is `@runtime_checked`.

### Domain — money

```
// money.l
@proof_required
package Money

pub type Cents = Long range 0 ..= 1_000_000_000_00 derives Add, Sub, Compare

pub opaque type Amount @projectable {
  value: Cents
  invariant: value > 0
}

pub func make(c: in Cents): Result[Amount, ContractViolation]
  ensures: result.isOk implies result.value.value == c
{
  return if c > 0 then Ok(Amount(value = c))
                  else Err(ContractViolation("amount must be positive"))
}

pub func valueOf(a: in Amount): Cents
  ensures: result == a.value
{
  return a.value
}
```

### Domain — accounts

```
// account.l
@proof_required
package Account

import Money.{Amount, Cents, valueOf as amountValue}

pub opaque type AccountId @projectable {
  value: Guid
}

pub opaque type Account @projectable {
  id: AccountId
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00
}

pub union AccountError {
  case InsufficientFunds
  case OverflowError
}

pub func balanceOf(a: in Account): Cents
  ensures: result == a.balance
{
  return a.balance
}

pub func debit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance - amountValue(amount)
  ensures: result.isErr implies a.balance < amountValue(amount)
{
  val v = amountValue(amount)
  if a.balance < v {
    return Err(InsufficientFunds)
  }
  return Ok(a.copy(balance = a.balance - v))
}

pub func credit(a: in Account, amount: in Amount): Result[Account, AccountError]
  ensures: result.isOk implies result.value.balance == a.balance + amountValue(amount)
{
  val v = amountValue(amount)
  if a.balance + v > 1_000_000_000_00 {
    return Err(OverflowError)
  }
  return Ok(a.copy(balance = a.balance + v))
}
```

### Domain — transfer

```
// transfer.l
@proof_required
package Transfer

import Account.{Account, AccountId, debit, credit, balanceOf}
import Money.{Amount, valueOf as amountValue}

pub union TransferError {
  case AccountNotFound(id: AccountId)
  case InsufficientFunds
  case OverflowError
  case SameAccount
}

pub func execute(
  from: in Account,
  to: in Account,
  amount: in Amount
): Result[(Account, Account), TransferError]
  requires: from.id != to.id
  ensures: result.isOk implies {
    val (newFrom, newTo) = result.value
    newFrom.balance + newTo.balance == from.balance + to.balance and
    newFrom.balance == from.balance - amountValue(amount) and
    newTo.balance == to.balance + amountValue(amount)
  }
{
  val newFrom = match debit(from, amount) {
    case Ok(a) -> a
    case Err(InsufficientFunds) -> return Err(InsufficientFunds)
    case Err(OverflowError) -> return Err(OverflowError)  // unreachable on debit
  }
  val newTo = match credit(to, amount) {
    case Ok(a) -> a
    case Err(OverflowError) -> return Err(OverflowError)
    case Err(InsufficientFunds) -> return Err(InsufficientFunds)  // unreachable on credit
  }
  return Ok((newFrom, newTo))
}
```

The conservation property — `newFrom.balance + newTo.balance == from.balance + to.balance` — is the contract worth proving. The SMT solver discharges it from the post-conditions of `debit` and `credit`.

### Application service

```
// transferService.l
@runtime_checked
package TransferService

import Account.{Account, AccountId}
import Money.Amount
import Transfer.{execute, TransferError}
import Time.Instant

pub interface AccountRepository {
  async func findById(id: in AccountId): Account?
  async func saveAll(accounts: in slice[Account]): Unit
}

pub interface IdempotencyStore {
  async func lookup(key: in IdempotencyKey): TransferReceipt?
  async func store(key: in IdempotencyKey, receipt: in TransferReceipt): Unit
}

pub interface Clock {
  func now(): Instant
}

pub opaque type IdempotencyKey @projectable {
  value: String
}

pub opaque type TransferReceipt @projectable {
  fromId: AccountId
  toId: AccountId
  amount: Amount
  at: Instant
}

pub opaque type TransferService

pub func make(
  accounts: in AccountRepository,
  idempotency: in IdempotencyStore,
  clock: in Clock
): TransferService

pub async func transfer(
  svc: in TransferService,
  fromId: in AccountId,
  toId: in AccountId,
  amount: in Amount,
  key: in IdempotencyKey
): Result[TransferReceipt, TransferError]
  requires: fromId != toId

// transferService.lbody equivalent (in unified file)
opaque type TransferService = record {
  accounts: AccountRepository
  idempotency: IdempotencyStore
  clock: Clock
}

func make(
  accounts: in AccountRepository,
  idempotency: in IdempotencyStore,
  clock: in Clock
): TransferService {
  return TransferService(accounts, idempotency, clock)
}

async func transfer(
  svc: in TransferService,
  fromId: in AccountId,
  toId: in AccountId,
  amount: in Amount,
  key: in IdempotencyKey
): Result[TransferReceipt, TransferError] {

  match await svc.idempotency.lookup(key) {
    case Some(prior) -> return Ok(prior)
    case None -> {}
  }

  val from = await svc.accounts.findById(fromId)
      ?? return Err(AccountNotFound(fromId))
  val to = await svc.accounts.findById(toId)
      ?? return Err(AccountNotFound(toId))

  val (newFrom, newTo) = execute(from, to, amount)?

  await svc.accounts.saveAll([newFrom, newTo])

  val receipt = TransferReceipt(
    fromId = fromId,
    toId = toId,
    amount = amount,
    at = svc.clock.now()
  )
  await svc.idempotency.store(key, receipt)

  return Ok(receipt)
}
```

### HTTP boundary

```
// transferHttp.l
@runtime_checked
package TransferHttp

import TransferService.{TransferService, transfer, IdempotencyKey, TransferReceipt}
import Account.AccountId
import Money.{Amount, Cents}
import Transfer.TransferError
import std.http.{HttpResponse, HttpStatus}

pub exposed record TransferRequest @derive(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
}

pub exposed record TransferResponseBody @derive(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
  at: String
}

pub async func handleTransfer(
  svc: in TransferService,
  req: in TransferRequest,
  rawIdempotencyKey: in String
): HttpResponse[TransferResponseBody] {

  val fromId = match AccountId.tryFrom(req.fromId) {
    case Ok(id) -> id
    case Err(_) -> return HttpResponse.badRequest("invalid fromId")
  }
  val toId = match AccountId.tryFrom(req.toId) {
    case Ok(id) -> id
    case Err(_) -> return HttpResponse.badRequest("invalid toId")
  }
  val cents = match Cents.tryFrom(req.amountCents) {
    case Ok(c) -> c
    case Err(_) -> return HttpResponse.badRequest("invalid amount")
  }
  val amount = match Amount.make(cents) {
    case Ok(a) -> a
    case Err(_) -> return HttpResponse.badRequest("amount must be positive")
  }
  val key = match IdempotencyKey.tryFrom(rawIdempotencyKey) {
    case Ok(k) -> k
    case Err(_) -> return HttpResponse.badRequest("missing idempotency key")
  }

  if fromId == toId {
    return HttpResponse.badRequest("cannot transfer to same account")
  }

  return match await transfer(svc, fromId, toId, amount, key) {
    case Ok(receipt) -> HttpResponse.ok(receipt.toBody())
    case Err(AccountNotFound(_)) -> HttpResponse.notFound()
    case Err(InsufficientFunds) -> HttpResponse.unprocessable("insufficient funds")
    case Err(OverflowError) -> HttpResponse.unprocessable("amount exceeds maximum")
    case Err(SameAccount) -> HttpResponse.badRequest("same account")
  }
}

func toBody(r: in TransferReceipt): TransferResponseBody {
  return TransferResponseBody(
    fromId = r.fromId.toView().value,
    toId = r.toId.toView().value,
    amountCents = r.amount.toView().value.toLong(),
    at = r.at.toIso8601()
  )
}
```

### Wire

```
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

---

## Example 2: Concurrent rate limiter

A token-bucket rate limiter shared across requests, demonstrating `protected type` with barrier conditions.

```
// rateLimiter.l
@runtime_checked
package RateLimiter

import Time.{Instant, Duration, durationBetween}

pub protected type TokenBucket {
  var tokens: Double
  var lastRefill: Instant
  let capacity: Double
  let refillPerSecond: Double

  invariant: tokens >= 0.0 and tokens <= capacity

  pub entry tryAcquire(count: in Double): Bool
    requires: count > 0.0
  {
    refill()
    if tokens >= count {
      tokens = tokens - count
      return true
    }
    return false
  }

  pub entry acquire(count: in Double, clock: in Clock): Unit
    requires: count > 0.0
    requires: count <= capacity
    when: tokens >= count or
          durationBetween(lastRefill, clock.now()) >= secondsToRefillTo(count)
  {
    refill()
    tokens = tokens - count
  }

  func refill() {
    val now = clock.now()
    val elapsed = durationBetween(lastRefill, now).seconds()
    val newTokens = tokens + elapsed * refillPerSecond
    tokens = if newTokens > capacity then capacity else newTokens
    lastRefill = now
  }

  func secondsToRefillTo(target: in Double): Duration {
    val needed = target - tokens
    return Duration.fromSeconds(needed / refillPerSecond)
  }
}

pub func make(capacity: in Double, refillPerSecond: in Double): TokenBucket
  requires: capacity > 0.0
  requires: refillPerSecond > 0.0
{
  return TokenBucket(
    tokens = capacity,
    lastRefill = SystemClock.now(),
    capacity = capacity,
    refillPerSecond = refillPerSecond
  )
}
```

The `acquire` entry blocks until enough tokens are available; the `when:` barrier is the structural form of "wait for capacity." Multiple callers contend safely without explicit locking.

**Note:** This example uses `SystemClock.now()` for simplicity in the constructor. In real code you'd inject the clock. The example is to show `protected type` semantics, not DI patterns.

---

## Example 3: Property-tested data structure

A persistent (immutable) sorted set with auto-generated property tests against contracts.

```
// sortedSet.l
@proof_required
package SortedSet

generic[T] pub opaque type SortedSet
  where T: Compare
{
  invariant: isSorted(items)
  invariant: isUnique(items)
}

generic[T] pub func empty(): SortedSet[T]
  where T: Compare
  ensures: size(result) == 0

generic[T] pub func size(s: in SortedSet[T]): Nat
  where T: Compare

generic[T] pub func contains(s: in SortedSet[T], x: in T): Bool
  where T: Compare

generic[T] pub func insert(s: in SortedSet[T], x: in T): SortedSet[T]
  where T: Compare
  ensures: contains(result, x)
  ensures: forall (y: T) where contains(s, y) implies contains(result, y)
  ensures: size(result) == (if contains(s, x) then size(s) else size(s) + 1)

generic[T] pub func remove(s: in SortedSet[T], x: in T): SortedSet[T]
  where T: Compare
  ensures: not contains(result, x)
  ensures: forall (y: T) where contains(s, y) and y != x implies contains(result, y)
  ensures: size(result) == (if contains(s, x) then size(s) - 1 else size(s))
```

Tests:

```
// sortedSet.test.l
@test_module
package SortedSet

test "empty contains nothing" {
  val s: SortedSet[Int] = empty()
  expect(size(s) == 0)
  expect(not contains(s, 0))
  expect(not contains(s, 42))
}

property "insert then contains" {
  forall (initial: SortedSet[Int], x: Int) {
    val updated = insert(initial, x)
    expect(contains(updated, x))
  }
}

property "insert is idempotent" {
  forall (initial: SortedSet[Int], x: Int) {
    val once = insert(initial, x)
    val twice = insert(once, x)
    expect(once == twice)
  }
}

property "remove undoes insert when not previously present" {
  forall (initial: SortedSet[Int], x: Int)
    where not contains(initial, x)
  {
    val inserted = insert(initial, x)
    val removed = remove(inserted, x)
    expect(removed == initial)
  }
}
```

The `forall` generators are auto-derived from the type's invariants. `SortedSet[Int]` instances are generated such that they satisfy `isSorted` and `isUnique` by construction — the generator never produces invalid inputs.

The `ensures` clauses on `insert` and `remove` are also automatically run as property tests via `lyric test --properties`. This catches divergence between specification and implementation that hand-written tests miss.

---

## Example 4: HTTP scraper with structured concurrency

Concurrent fetching with cancellation, error aggregation, and result handling. Demonstrates structured scopes and async patterns.

```
// scraper.l
@runtime_checked
package Scraper

import std.http.{HttpClient, HttpResponse}
import std.collections.Map

pub exposed record PageResult @derive(Json) {
  url: String
  statusCode: Int?
  contentLength: Int?
  error: String?
}

pub async func scrapeAll(
  client: in HttpClient,
  urls: in slice[String],
  maxConcurrent: in Nat range 1 ..= 100
): slice[PageResult] {

  val semaphore = Semaphore.make(maxConcurrent)
  var results: slice[PageResult] = []

  scope {
    var tasks: slice[Task[PageResult]] = []
    for url in urls {
      val task = spawn fetchOne(client, url, semaphore)
      tasks = tasks.append(task)
    }
    for task in tasks {
      results = results.append(await task)
    }
  }

  return results
}

async func fetchOne(
  client: in HttpClient,
  url: in String,
  semaphore: in Semaphore
): PageResult {
  await semaphore.acquire()
  defer { semaphore.release() }

  return match await client.get(url) {
    case Ok(response) -> PageResult(
      url = url,
      statusCode = Some(response.statusCode),
      contentLength = Some(response.body.lengthBytes()),
      error = None
    )
    case Err(error) -> PageResult(
      url = url,
      statusCode = None,
      contentLength = None,
      error = Some(error.message())
    )
  }
}
```

**Note:** `defer { ... }` runs on scope exit (success or failure). The `Semaphore.acquire()`/`release()` pattern is a standard library primitive; in Lyric proper you'd more commonly wrap this in a `protected type`.

If the scope is cancelled (caller's cancellation token fires), all in-flight `fetchOne` tasks are cancelled. The semaphore ensures at most `maxConcurrent` requests are in flight at any moment.

---

## Example 5: Configuration with strong typing

Demonstrates exposed records for wire-level shapes, conversion to opaque types, and `@derive(Json)` for source-generated parsing.

```
// config.l
@runtime_checked
package AppConfig

import std.time.Duration
import std.net.Url

pub exposed record RawConfig @derive(Json) {
  databaseUrl: String
  databasePoolSize: Long
  redisUrl: String
  metricsPort: Long
  requestTimeoutSeconds: Long
  rateLimitTokensPerSecond: Double
  rateLimitBurstCapacity: Double
}

pub opaque type AppConfig @projectable {
  dbUrl: Url
  dbPoolSize: Nat range 1 ..= 100
  redisUrl: Url
  metricsPort: Nat range 1 ..= 65_535
  requestTimeout: Duration
  rateLimitTokensPerSecond: Double range 0.1 ..= 1_000_000.0
  rateLimitBurstCapacity: Double range 1.0 ..= 1_000_000.0
}

pub union ConfigError {
  case InvalidUrl(field: String, value: String)
  case OutOfRange(field: String, value: String, expected: String)
  case Missing(field: String)
}

pub func load(raw: in RawConfig): Result[AppConfig, ConfigError] {
  val dbUrl = Url.tryFrom(raw.databaseUrl)
      .mapErr { _ -> InvalidUrl("databaseUrl", raw.databaseUrl) }?
  val redisUrl = Url.tryFrom(raw.redisUrl)
      .mapErr { _ -> InvalidUrl("redisUrl", raw.redisUrl) }?

  val poolSize = (Nat range 1 ..= 100).tryFrom(raw.databasePoolSize)
      .mapErr { _ -> OutOfRange("databasePoolSize", raw.databasePoolSize.toString(), "1-100") }?
  val port = (Nat range 1 ..= 65_535).tryFrom(raw.metricsPort)
      .mapErr { _ -> OutOfRange("metricsPort", raw.metricsPort.toString(), "1-65535") }?

  return Ok(AppConfig(
    dbUrl = dbUrl,
    dbPoolSize = poolSize,
    redisUrl = redisUrl,
    metricsPort = port,
    requestTimeout = Duration.fromSeconds(raw.requestTimeoutSeconds),
    rateLimitTokensPerSecond = raw.rateLimitTokensPerSecond,
    rateLimitBurstCapacity = raw.rateLimitBurstCapacity
  ))
}
```

The pattern: `RawConfig` is what `appsettings.json` deserializes to (flat, exposed, no constraints). `AppConfig` is the validated, typed, range-bound representation that flows through the rest of the application. Validation happens once, at the boundary, and produces a strongly-typed value or a precise error.

---

## What these examples demonstrate

1. **Range subtypes work end-to-end.** `Cents`, `Nat range 1 ..= 100`, `Double range 0.1 ..= 1_000_000.0` all participate in normal expressions, with conversion only at boundaries.

2. **Opaque types preserve invariants without runtime cost.** Once an `AppConfig` exists, its fields are valid by construction. Downstream code doesn't re-validate.

3. **Contracts are debuggable.** A failing `ensures` on `Transfer.execute` produces a counterexample input — much more useful than a stack trace.

4. **DI is explicit but compact.** The wire block is the only place dependencies are wired; service code only sees interfaces.

5. **Error handling is structural.** Every error-returning function declares so in its return type; `?` propagates; matches are exhaustive. There's no hidden control flow.

6. **Concurrency primitives match the problem.** `protected type` for shared state, `scope { ... }` for parallel tasks, `async`/`await` for sequencing. No raw locks anywhere.

7. **The boundary between domain and infrastructure is enforced.** `@proof_required` modules can't accidentally call into Redis. `exposed` records can't accidentally hide invariants. The discipline is structural, not cultural.
