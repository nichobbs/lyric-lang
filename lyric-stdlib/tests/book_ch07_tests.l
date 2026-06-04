// book_ch07_tests.l — Chapter 7: Error Handling
//
// Verifies: Result/Option creation, pattern matching, mapResultErr,
// unwrapResult, and the assertPanics helper.
package Book.Ch07.Tests

import Std.Core
import Std.Testing
import Std.Parse

// ---------------------------------------------------------------------------
// §7.1 Result[T, E]
// ---------------------------------------------------------------------------

union TransferError {
  case InsufficientFunds
  case AccountNotFound(id: Int)
  case SameAccount
}

func simulateTransfer(
    fromBalance: Int,
    fromId: Int,
    toId: Int,
    amount: Int
): Result[Int, TransferError] {
  if fromId == toId     { return Err(error = SameAccount) }
  if fromBalance < amount { return Err(error = InsufficientFunds) }
  return Ok(value = fromBalance - amount)
}

func testResultConstruction(): Unit {
  val ok: Result[Int, String] = Ok(value = 42)
  assertTrue(isOk(ok), "Ok is Ok")
  assertTrue(not isErr(ok), "Ok is not Err")
  assertEqualInt(unwrapResultOr(ok, 0), 42, "unwrapResultOr Ok")

  val err: Result[Int, String] = Err(error = "bad")
  assertTrue(isErr(err), "Err is Err")
  assertTrue(not isOk(err), "Err is not Ok")
  assertEqualInt(unwrapResultOr(err, 99), 99, "unwrapResultOr Err default")
}

func testResultMatching(): Unit {
  val r = simulateTransfer(100, 1, 2, 50)
  match r {
    case Ok(newBalance)             -> assertEqualInt(newBalance, 50, "transfer success")
    case Err(InsufficientFunds)     -> assertTrue(false, "unexpected InsufficientFunds")
    case Err(AccountNotFound(id))   -> assertTrue(false, "unexpected AccountNotFound")
    case Err(SameAccount)           -> assertTrue(false, "unexpected SameAccount")
  }

  val r2 = simulateTransfer(30, 1, 2, 50)
  match r2 {
    case Ok(_)                  -> assertTrue(false, "should be InsufficientFunds")
    case Err(InsufficientFunds) -> assertTrue(true, "InsufficientFunds raised correctly")
    case Err(AccountNotFound(_)) -> assertTrue(false, "wrong error type")
    case Err(SameAccount)       -> assertTrue(false, "wrong error type")
  }

  val r3 = simulateTransfer(100, 5, 5, 10)
  match r3 {
    case Ok(_)                   -> assertTrue(false, "should be SameAccount")
    case Err(InsufficientFunds)  -> assertTrue(false, "wrong error type")
    case Err(AccountNotFound(_)) -> assertTrue(false, "wrong error type")
    case Err(SameAccount)        -> assertTrue(true, "SameAccount raised correctly")
  }
}

// ---------------------------------------------------------------------------
// §7.2 Error propagation (explicit match form)
// ---------------------------------------------------------------------------

func parsePositiveInt(raw: String): Result[Int, String] {
  val parsed = tryParseInt(raw)
  if isErr(parsed) { return Err(error = "bad number: ${raw}") }
  val n = unwrapResult(parsed)
  if n <= 0 { return Err(error = "out of range: ${toString(n)}") }
  return Ok(value = n)
}

func testPropagation(): Unit {
  val ok = parsePositiveInt("42")
  assertTrue(isOk(ok), "parsePositiveInt ok")
  assertEqualInt(unwrapResult(ok), 42, "parsePositiveInt value")

  val badNum = parsePositiveInt("xyz")
  assertTrue(isErr(badNum), "parsePositiveInt bad number")

  val outOfRange = parsePositiveInt("-5")
  assertTrue(isErr(outOfRange), "parsePositiveInt out of range")
}

// ---------------------------------------------------------------------------
// §7.3 mapResultErr — error type conversion at boundaries
// ---------------------------------------------------------------------------

func parseAndProcess(raw: String): Result[Int, String] {
  val parsed = mapResultErr(tryParseInt(raw), { _ -> "parse error" })
  if isErr(parsed) { return parsed }
  val n = unwrapResult(parsed)
  if n < 0 { return Err(error = "processing failed") }
  return Ok(value = n * 2)
}

func testMapResultErr(): Unit {
  val ok = parseAndProcess("21")
  assertTrue(isOk(ok), "parseAndProcess ok")
  assertEqualInt(unwrapResult(ok), 42, "value doubled")

  val errConvert = parseAndProcess("abc")
  assertTrue(isErr(errConvert), "parse error converted")
}

// ---------------------------------------------------------------------------
// §7.4 Option[T]
// ---------------------------------------------------------------------------

func findFirst(xs: in slice[Int], pred: in (Int) -> Bool): Option[Int] {
  for x in xs {
    if pred(x) { return Some(value = x) }
  }
  return None
}

func testOptionHandling(): Unit {
  val found = findFirst([1, 3, 5, 6, 7], { x: Int -> x % 2 == 0 })
  assertTrue(isSome(found), "findFirst found even")
  assertEqualInt(unwrapOr(found, 0), 6, "first even is 6")

  val notFound = findFirst([1, 3, 5], { x: Int -> x % 2 == 0 })
  assertTrue(isNone(notFound), "no even found")
  assertEqualInt(unwrapOr(notFound, 0), 0, "unwrapOr default 0")
}

func testNilCoalescing(): Unit {
  val name: Option[String] = Some(value = "Alice")
  val noName: Option[String] = None

  assertEqual(unwrapOr(name, "anonymous"), "Alice", "unwrapOr with Some")
  assertEqual(unwrapOr(noName, "anonymous"), "anonymous", "unwrapOr with None")
}

// ---------------------------------------------------------------------------
// §7.5 unwrapResult (only for compile-time constants)
// ---------------------------------------------------------------------------

func testUnwrapResult(): Unit {
  val r: Result[Int, String] = Ok(value = 99)
  assertEqualInt(unwrapResult(r), 99, "unwrapResult on Ok")
}

// ---------------------------------------------------------------------------
// §7.6 Bug vs Error distinction
// ---------------------------------------------------------------------------

func testBugVsError(): Unit {
  assertPanics("unwrapResult on Err panics", { -> unwrapResult(Err(error = "trigger bug")) })
}

func main(): Unit {
  testResultConstruction()
  testResultMatching()
  testPropagation()
  testMapResultErr()
  testOptionHandling()
  testNilCoalescing()
  testUnwrapResult()
  testBugVsError()
  println("book_ch07: ok")
}
