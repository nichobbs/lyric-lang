//! Test module examples with accurate stub and assertion syntax.
@test_module
package Examples.Tests
import Std.Core
import Std.Testing

// ─── Basic tests ─────────────────────────────────────────────────────────────

test "divide returns correct quotient" {
  val result = divide(10, 2)
  assertEqualInt(result, 5, "quotient")
}

test "parseOrder fails on non-numeric id" {
  val result = parseOrder("not-a-number", "100")
  assertTrue(not isOk(result), "should be Err")
}

test "parseOrder succeeds with valid input" {
  val result = parseOrder("42", "1500")
  assertTrue(isOk(result), "should be Ok")
  val order = unwrapResult(result)
  assertEqualInt(order.totalCents.toLong(), 1500, "total cents")
}

// ─── Stub configuration ──────────────────────────────────────────────────────

// @stubbable on the interface generates AccountRepositoryStub
// import Repositories.{AccountRepository, AccountRepositoryStub}

// Fixed return values — typed proxy, top-to-bottom matching
// val repoStub = AccountRepositoryStub.returning {
//   it.findById(alice.id) -> Some(alice)
//   it.findById(bob.id)   -> Some(bob)
//   it.findById(_)        -> None      // wildcard: any other id
// }

// Recording + fixed returns
// val repoStub = AccountRepositoryStub.recording()
//     .returning {
//       it.findById(alice.id) -> Some(alice)
//       it.findById(_)        -> None
//     }

// Failing stub
// val failingRepo = AccountRepositoryStub.failing {
//   it.saveAll(_) -> Err(DatabaseError("connection refused"))
// }

// ─── Test wire ───────────────────────────────────────────────────────────────

wire TestWire {
  @provided alice: Account
  @provided bob: Account
  @provided fixedNow: Instant

  singleton accounts: AccountRepository =
      AccountRepositoryStub.recording()
          .returning {
            it.findById(alice.id) -> Some(alice)
            it.findById(bob.id)   -> Some(bob)
            it.findById(_)        -> None
          }

  singleton mailer: EmailSender =
      EmailSenderStub.recording()
          .returning { it.send(_, _, _) -> Ok(()) }

  singleton clock: Clock =
      ClockStub.returning { it.now() -> fixedNow }

  singleton svc: UserService = UserService(
    repo   = accounts,
    mailer = mailer,
    clock  = clock
  )

  expose svc
  expose accounts
  expose mailer
}

test "createUser sends welcome email" {
  val alice    = makeAccount(id = AccountId.from(1), name = "Alice")
  val fixedNow = unwrapResult(Instant.fromIso8601("2026-01-01T00:00:00Z"))
  val w        = TestWire.bootstrap(alice, bob = alice, fixedNow = fixedNow)

  val result = await w.svc.createUser(validRequest)
  assertTrue(isOk(result), "should succeed")

  // Assert on recorded calls
  val sendCalls = w.mailer.recorded("send")
  assertEqualInt(sendCalls.length, 1, "send called once")

  // Inspect argument values (args is slice[Any] — cast required)
  val toAddr = sendCalls[0].args[0] as String
  assertEqual(toAddr, "alice@example.com")
}

test "createUser for duplicate id returns Err" {
  val alice    = makeAccount(id = AccountId.from(1), name = "Alice")
  val fixedNow = unwrapResult(Instant.fromIso8601("2026-01-01T00:00:00Z"))
  val w        = TestWire.bootstrap(alice, bob = alice, fixedNow = fixedNow)

  // alice already exists in the stub; second create should fail
  val result = await w.svc.createUser(validRequest)
  assertTrue(not isOk(result), "should fail for duplicate")

  // Verify email was never sent
  assertEqualInt(w.mailer.recorded("send").length, 0, "no email for duplicate")
}

// ─── Bootstrap independence ───────────────────────────────────────────────────

test "bootstrap instances are independent" {
  val fixedNow = unwrapResult(Instant.fromIso8601("2026-01-01T00:00:00Z"))
  val alice    = makeAccount(id = AccountId.from(1), name = "Alice")

  val w1 = TestWire.bootstrap(alice, bob = alice, fixedNow = fixedNow)
  val w2 = TestWire.bootstrap(alice, bob = alice, fixedNow = fixedNow)

  await w1.svc.createUser(validRequest)

  // w1 has one call recorded, w2 has none — stubs are independent
  assertEqualInt(w1.accounts.recorded("saveAll").length, 1, "w1 saved")
  assertEqualInt(w2.accounts.recorded("saveAll").length, 0, "w2 untouched")
}
