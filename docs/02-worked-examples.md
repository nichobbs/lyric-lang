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

## Example 6: 3-D vector math with custom operator overloading

Demonstrates `impl Add for Vec3` and `impl Sub for Vec3` per decision-log entry D029. Shows how a user-defined record (not a numeric distinct type) can opt into binary operators by implementing the closed numeric trait set.

```
// vec3.l
@runtime_checked
package Vec3

pub record Vec3 @valueType {
  x: Double
  y: Double
  z: Double
}

impl Add for Vec3 {
  func add(self: in Vec3, other: in Vec3): Vec3 {
    return Vec3(x = self.x + other.x, y = self.y + other.y, z = self.z + other.z)
  }
}

impl Sub for Vec3 {
  func sub(self: in Vec3, other: in Vec3): Vec3 {
    return Vec3(x = self.x - other.x, y = self.y - other.y, z = self.z - other.z)
  }
}

pub func dot(a: in Vec3, b: in Vec3): Double {
  return a.x * b.x + a.y * b.y + a.z * b.z
}

pub func scale(v: in Vec3, k: in Double): Vec3 {
  return Vec3(x = v.x * k, y = v.y * k, z = v.z * k)
}

pub func length(v: in Vec3): Double
  ensures: result >= 0.0
{
  return Double.sqrt(dot(v, v))
}
```

Once the impls are in place, the operators are usable directly:

```
// usage.l
import Vec3.{Vec3, scale, length}

func translate(point: in Vec3, by: in Vec3): Vec3 {
  return point + by                        // resolves to Add::add
}

func displacement(from: in Vec3, to: in Vec3): Double {
  return length(to - from)                 // resolves to Sub::sub then length
}
```

Per D029, the algebra is conventionally numeric: `Vec3 + Vec3 -> Vec3`, same-type. Lyric does not enforce associativity or distributivity; it enforces the *signature* shape. The decision log calls out that any `+`-with-string-concatenation-style abuse is socially discouraged but not mechanically blocked.

---

## Example 7: Test wire with `@stubbable` interfaces

Demonstrates multiple wires (a production wire and a test wire) and `@stubbable`-derived stub builders, replacing the runtime mocking frameworks Lyric does not support. Builds on Example 1's `transfer` service.

```
// repositories.l
@runtime_checked
package Repositories

import Account.{Account, AccountId}
import TransferService.{IdempotencyKey, TransferReceipt}
import Time.Instant

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

`@stubbable` directs the compiler to emit a stub builder per interface. The builders surface as `<InterfaceName>Stub` types with `.returning { ... }`, `.recording()`, and `.failing { ... }` helpers (see language reference §10).

```
// transfer_test.l
@test_module
package TransferService

import Account.{Account, AccountId, AccountRepository}
import Money.{Amount, Cents}
import TransferService.{TransferService, transfer, IdempotencyKey, IdempotencyStore, Clock}
import Time.Instant
import Repositories.{AccountRepositoryStub, IdempotencyStoreStub, ClockStub}

wire TestWire {
  @provided alice: Account
  @provided bob: Account
  @provided fixedNow: Instant

  singleton accounts: AccountRepository =
      AccountRepositoryStub.recording()
          .returning { it.findById(alice.id) -> Some(alice)
                      ; it.findById(bob.id)   -> Some(bob) }

  singleton idempotency: IdempotencyStore =
      IdempotencyStoreStub.recording()
          .returning { it.lookup(_) -> None }

  singleton clock: Clock =
      ClockStub.returning { it.now() -> fixedNow }

  singleton svc: TransferService = TransferService.make(accounts, idempotency, clock)
  expose svc
  expose accounts          // tests inspect the recording
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

Notes:

- The test wire is just another `wire` block — no special syntax for tests.
- `@stubbable`-generated stubs are statically typed: a signature change to `AccountRepository` produces a *compile error* in `transfer_test.l`, not a runtime failure.
- No reflection, no proxy classes, no DynamicMock — the stubs are AOT-compatible.
- `recording()` is one helper per language reference §10.4; it captures every call so tests can assert on call counts and arguments.

---

## Example 8: `@axiom` extern boundary for filesystem I/O

Demonstrates an `extern package` declaration with `@axiom`. The block describes a contract the compiler will *trust*; the proof system uses these contracts as facts when verifying callers, but does not check them. This is the gateway between Lyric and the .NET BCL.

```
// system_io.l
@axiom("System.IO.File operations conform to the .NET BCL contract")
extern package System.IO {

  pub exposed type File @derive(opaqueHandle)

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

The `@axiom` annotation declares that the contracts are assumed by the prover, not derived. The language reference §6.5 explains the social cost: every line of an axiom block is reviewable in a PR diff, and accumulates in the `<package>.lyric-contract` artifact for downstream auditing.

A `@runtime_checked` wrapper that re-establishes the language's safety contracts:

```
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

pub func readText(path: in String): Result[String, FsError]
  requires: path.length > 0
{
  return readBytes(path).map { bytes -> String.fromUtf8(bytes).unwrap() }
}
```

The `try { ... } catch Bug as b` form is the *robustness boundary* per language reference §8.2: the compiler emits a warning if `Bug` is caught in normal code, but warning-disabled here because this *is* the boundary. Downstream packages call `Fs.readBytes(...)` and get `Result`-typed errors, with no `Bug` propagation crossing the wrapper.

---

## Example 9: Projection cycle handled with `@projectionBoundary`

Demonstrates D026: when the `@projectable` graph cycles, the compiler requires an explicit cut. Here `User` references its `Team`, and `Team` references its `members` — the projection would otherwise recurse infinitely.

```
// directory.l
@runtime_checked
package Directory

pub opaque type UserId @projectable {
  value: Guid
}

pub opaque type TeamId @projectable {
  value: Guid
}

pub opaque type Team @projectable {
  id: TeamId
  name: String
  // The cycle is broken here: TeamView contains members as
  // slice[UserId], not slice[UserView].
  members: slice[User] @projectionBoundary(asId)
}

pub opaque type User @projectable {
  id: UserId
  email: String
  // Symmetric cut: UserView's team field projects as TeamId.
  team: Team? @projectionBoundary(asId)
}
```

The compiler-emitted views become:

```
exposed record UserView @derive(Json) {
  id: Guid                    // UserId.toView()
  email: String
  teamId: Guid?               // Team.id.value, not the full TeamView
}

exposed record TeamView @derive(Json) {
  id: Guid                    // TeamId.toView()
  name: String
  memberIds: slice[Guid]      // each User.id.value, not slice[UserView]
}
```

Without the `@projectionBoundary` markers, the compiler would emit a precise error pointing at both `Team.members` and `User.team`, naming the cycle and refusing to default to a silent shape.

The reverse projections (`UserView.tryInto`, `TeamView.tryInto`) cannot reconstruct the full graph from IDs alone — that is the user's job, by querying the repository for the referenced entities. The compiler emits *fallible* `tryInto` overloads that take the resolved counterparties as additional arguments:

```
pub func TeamView.tryInto(self: in TeamView, members: in slice[User])
  : Result[Team, ContractViolation]
```

This is intentional: the cycle-cut sacrifices automatic round-trip in exchange for a finite serialised shape, and the type system makes the trade visible.

---

## Example 10: Binary search tree with proven invariants

Demonstrates a recursive `@proof_required` data structure with a non-trivial invariant — every node's left subtree contains only smaller keys, every right subtree only larger — and a proof obligation on `insert` that the BST property is preserved. Shows quantifiers over inductive structure and the bounds of the decidable fragment (§11 of contract semantics).

```
// bst.l
@proof_required
package Bst

generic[K] pub union Tree
  where K: Compare
{
  case Leaf
  case Node(left: Tree[K], key: K, right: Tree[K])
}

generic[K] pub func contains(t: in Tree[K], k: in K): Bool
  where K: Compare
{
  return match t {
    case Leaf -> false
    case Node(l, key, r) ->
      if k == key then true
      else if k < key then contains(l, k)
      else contains(r, k)
  }
}

generic[K] @pure pub func keys(t: in Tree[K]): slice[K]
  where K: Compare
{
  return match t {
    case Leaf -> []
    case Node(l, key, r) -> keys(l).append(key).concat(keys(r))
  }
}

generic[K] @pure pub func isBst(t: in Tree[K]): Bool
  where K: Compare
{
  return match t {
    case Leaf -> true
    case Node(l, key, r) ->
      isBst(l) and isBst(r) and
      forall (lk: K) where keys(l).contains(lk) implies lk < key and
      forall (rk: K) where keys(r).contains(rk) implies rk > key
  }
}

generic[K] pub func insert(t: in Tree[K], k: in K): Tree[K]
  where K: Compare
  requires: isBst(t)
  ensures:  isBst(result)
  ensures:  contains(result, k)
  ensures:  forall (other: K) where contains(t, other) implies contains(result, other)
{
  return match t {
    case Leaf -> Node(Leaf, k, Leaf)
    case Node(l, key, r) ->
      if k == key then t
      else if k < key then Node(insert(l, k), key, r)
      else Node(l, key, insert(r, k))
  }
}
```

The conservation property — every key already present remains present — falls within the decidable fragment because the recursion terminates on the inductive structure of `Tree[K]` and the quantifiers range over a finite slice. Z3 discharges these obligations in milliseconds for `K: Int` or any other primitive with a built-in theory.

The same code with `K: String` may push the solver into `unknown` because string-ordering reasoning lives outside the decidable fragment for free quantifiers. Per `08-contract-semantics.md` §11, the verifier reports such cases as unverified obligations rather than producing a wrong proof; the user can either narrow the obligation or shift the package to `@runtime_checked`.

---

## Example 11: `old(_)` and history-aware contracts

Demonstrates `old(...)` in `ensures:` clauses — the snapshot mechanism that lets postconditions refer to the function's pre-state. Builds an immutable stack with contracts that talk about both the pre- and post-states.

```
// stack.l
@proof_required
package Stack

generic[T] pub opaque type Stack {
  items: slice[T]
}

generic[T] pub func empty(): Stack[T]
  ensures: result.items.length == 0
{
  return Stack(items = [])
}

generic[T] pub func depth(s: in Stack[T]): Nat
  ensures: result == s.items.length
{
  return s.items.length
}

generic[T] pub func push(s: in Stack[T], x: in T): Stack[T]
  ensures: result.items.length == old(s.items.length) + 1
  ensures: result.items[old(s.items.length)] == x
  ensures: forall (i: Nat) where i < old(s.items.length)
              implies result.items[i] == old(s.items[i])
{
  return Stack(items = s.items.append(x))
}

generic[T] pub func pop(s: in Stack[T]): Result[(T, Stack[T]), StackError]
  requires: s.items.length > 0
  ensures: result.isOk implies {
    val (top, rest) = result.value
    rest.items.length == old(s.items.length) - 1 and
    top == old(s.items[s.items.length - 1]) and
    forall (i: Nat) where i < rest.items.length
              implies rest.items[i] == old(s.items[i])
  }
{
  val n = s.items.length
  return Ok((s.items[n - 1], Stack(items = s.items.slice(0, n - 1))))
}

pub union StackError { case Empty }
```

Per `08-contract-semantics.md` §5.2, `old(s.items.length)` is captured immediately after `requires:` succeeds and held in a generated frame slot. The runtime cost is paid only for the values the contract actually reads — `old(s.items.length)` is a single `Nat` snapshot, not a deep copy of the slice. Inside the `ensures:`, every reference to `old(...)` reads the snapshot, never the post-state.

A version of `push` that *forgets* to mention `old` —

```
ensures: result.items.length == s.items.length + 1     // wrong!
```

— would misuse `s.items.length`: by the time the postcondition runs, the parameter has not changed (it is `in`, after all) so this happens to work, but the *intent* is the pre-state. Authors writing more aggressive contracts (e.g. on `inout`-mutable structures) must use `old` explicitly; the contract validator does not insert it for them.

---

## What these examples demonstrate

1. **Range subtypes work end-to-end.** `Cents`, `Nat range 1 ..= 100`, `Double range 0.1 ..= 1_000_000.0` all participate in normal expressions, with conversion only at boundaries.

2. **Opaque types preserve invariants without runtime cost.** Once an `AppConfig` exists, its fields are valid by construction. Downstream code doesn't re-validate.

3. **Contracts are debuggable.** A failing `ensures` on `Transfer.execute` produces a counterexample input — much more useful than a stack trace.

4. **DI is explicit but compact.** The wire block is the only place dependencies are wired; service code only sees interfaces.

5. **Error handling is structural.** Every error-returning function declares so in its return type; `?` propagates; matches are exhaustive. There's no hidden control flow.

6. **Concurrency primitives match the problem.** `protected type` for shared state, `scope { ... }` for parallel tasks, `async`/`await` for sequencing. No raw locks anywhere.

7. **The boundary between domain and infrastructure is enforced.** `@proof_required` modules can't accidentally call into Redis. `exposed` records can't accidentally hide invariants. The discipline is structural, not cultural.

8. **Operator overloading is opt-in and bounded.** `impl Add for Vec3` is admissible (D029); `impl SomethingWeird for X` is not. Math-shaped types read like math; non-math types stay disciplined.

9. **Test infrastructure is part of the language.** `@stubbable` plus a second `wire` block replaces mocking frameworks, with statically-typed stubs and zero runtime reflection.

10. **`@axiom` makes the FFI boundary visible.** Every interaction with .NET BCL or external libraries is explicit, contract-bearing, and listed in the package's contract metadata.

11. **Cyclic data shapes require explicit cuts.** D026's `@projectionBoundary` annotation surfaces the trade-off (lose round-trip, gain finite shape) at the type declaration where reviewers can see it.

12. **Inductive proofs work in the decidable fragment.** Tree invariants, sortedness, set conservation: Z3 discharges these directly when the underlying types are primitives. Beyond the fragment, the verifier is honest about it.

13. **`old(_)` snapshots capture intent.** Pre/post-state contracts read clearly and cost only what they read; the snapshot mechanism is per-frame and per-expression, not whole-state.
