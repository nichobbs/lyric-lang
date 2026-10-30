//! Test module examples with accurate stub and assertion syntax.
@test_module
package Examples.Tests

import Std.Core
import Std.Testing
import Std.Parse

// ─── Code under test ─────────────────────────────────────────────────────────
pub func divide(a: in Int, b: in Int): Int
  requires: b != 0
{
  return a / b
}

pub func parsePositive(raw: in String): Result[Int, String] {
  match tryParseInt(raw) {
    case Ok(n) -> {
      if n <= 0 {
        return Err(error = "must be positive")
      }
      return Ok(value = n)
    }
    case Err(_) -> return Err(error = "not a number")
  }
}

// @stubbable on an interface generates `<Name>Stub`: a record with a
// `<method>_value` field (the value the method returns) and a
// `<method>_counter` (how many times it was called) per method.
@stubbable
pub interface Clock {
  func now(): Long
}

@stubbable
pub interface Mailer {
  func send(to: in String, subject: in String): Bool
}

pub record Greeter {
  pub clock: Clock
  pub mailer: Mailer
}

pub func welcome(g: in Greeter, email: in String): Bool {
  val stamp = g.clock.now()
  return g.mailer.send(email, "Welcome at ${toString(stamp)}")
}

// ─── Basic tests ─────────────────────────────────────────────────────────────
test "divide returns correct quotient" {
  assertEqualInt(divide(10, 2), 5, "quotient")
}

test "parsePositive fails on non-numeric input" {
  val result = parsePositive("not-a-number")
  assertTrue(not isOk(result), "should be Err")
}

test "parsePositive succeeds with valid input" {
  val result = parsePositive("42")
  assertTrue(isOk(result), "should be Ok")
  assertEqualInt(unwrapResult(result), 42, "parsed value")
}

// ─── Stub configuration ──────────────────────────────────────────────────────
test "a stub returns its configured value and counts calls" {
  val clock = ClockStub(now_value = 1000)
  assertEqualInt(stubCounterGet(clock.now_counter), 0, "not called yet")
  assertEqualLong(clock.now(), 1000, "configured value")
  assertEqualLong(clock.now(), 1000, "same value again")
  assertEqualInt(stubCounterGet(clock.now_counter), 2, "called twice")
  stubCounterReset(clock.now_counter)
  assertEqualInt(stubCounterGet(clock.now_counter), 0, "reset")
}

// ─── Test wire ───────────────────────────────────────────────────────────────
wire TestWire {
  @provided fixedNow: Long
  @provided accepted: Bool
  singleton clock: ClockStub = ClockStub(now_value = fixedNow)
  singleton mailer: MailerStub = MailerStub(send_value = accepted)
  singleton greeter: Greeter = Greeter(clock = clock, mailer = mailer)
  expose greeter
  expose clock
  expose mailer
}

test "welcome sends one email and reads the clock once" {
  TestWire.bootstrap(1000, true)
  val greeter = TestWire.greeter()
  assertTrue(welcome(greeter, "amy@example.com"), "mailer accepted the message")

  assertEqualInt(stubCounterGet(TestWire.mailer().send_counter), 1, "send called once")
  assertEqualInt(stubCounterGet(TestWire.clock().now_counter), 1, "clock read once")
}

test "welcome reports a rejected message and still reads the clock" {
  TestWire.bootstrap(2000, false)
  assertTrue(not welcome(TestWire.greeter(), "bob@example.com"), "mailer rejected the message")
  assertEqualInt(stubCounterGet(TestWire.mailer().send_counter), 1, "send was attempted")
}

// ─── Bootstrap independence ──────────────────────────────────────────────────
test "each bootstrap builds fresh stubs" {
  TestWire.bootstrap(1000, true)
  val first = TestWire.mailer()
  welcome(TestWire.greeter(), "amy@example.com")
  assertEqualInt(stubCounterGet(first.send_counter), 1, "first wire saw the call")

  TestWire.bootstrap(1000, true)
  assertEqualInt(stubCounterGet(TestWire.mailer().send_counter), 0, "second wire starts at zero")
}
