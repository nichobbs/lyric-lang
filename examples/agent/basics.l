//! Canonical Lyric examples. Pattern-match from these.
package Examples
import Std.Core
import Std.String
import Std.Collections

// ─── Domain types ──────────────────────────────────────────────────────────

type UserId  = Long derives Compare, Hash, Equals
type OrderId = Long derives Compare, Hash, Equals
type Cents   = Long range 0 ..= 100_000_000_000 derives Add, Sub, Compare

// ─── Records ────────────────────────────────────────────────────────────────

pub record User {
  pub id: UserId
  pub name: String
  pub email: String
}

pub record Order {
  pub id: OrderId
  pub userId: UserId
  pub totalCents: Cents
}

// ─── Unions ─────────────────────────────────────────────────────────────────

pub union AppError {
  case NotFound(message: String)
  case Unauthorised
  case ValidationError(field: String, message: String)
  case DbError(message: String)
}

// ─── Opaque type with invariant ─────────────────────────────────────────────

pub opaque type Email {
  val raw: String
  invariant: raw.contains("@") and raw.length > 3

  pub func from(s: in String): Result[Email, AppError] {
    if not s.contains("@") {
      return Err(AppError.ValidationError(field = "email", message = "must contain @"))
    }
    if s.length <= 3 {
      return Err(AppError.ValidationError(field = "email", message = "too short"))
    }
    return Ok(Email(raw = s))
  }

  pub func value(self: in Email): String = self.raw
}

// ─── Function with contracts ─────────────────────────────────────────────────

pub func divide(a: in Int, b: in Int): Int
  requires: b != 0
  ensures: result * b == a
{
  return a / b
}

// ─── Error propagation pattern ───────────────────────────────────────────────

pub func parseOrder(rawId: in String, rawTotal: in String): Result[Order, AppError] {
  val id    = tryParseLong(rawId).mapErr { _ -> AppError.ValidationError(field = "id", message = "not a number") }?
  val total = tryParseLong(rawTotal).mapErr { _ -> AppError.ValidationError(field = "total", message = "not a number") }?
  val cents = Cents.tryFrom(total).mapErr { _ -> AppError.ValidationError(field = "total", message = "must be non-negative") }?
  return Ok(Order(
    id        = OrderId.from(id),
    userId    = UserId.from(1),
    totalCents = cents
  ))
}

// ─── Pattern matching ────────────────────────────────────────────────────────

pub func describeError(err: in AppError): String {
  return match err {
    case NotFound(msg)                    -> "not found: ${msg}"
    case Unauthorised                     -> "access denied"
    case ValidationError(field, message)  -> "invalid ${field}: ${message}"
    case DbError(msg)                     -> "database error: ${msg}"
  }
}

// ─── Collection idioms ───────────────────────────────────────────────────────

pub func activeUserNames(users: in slice[User], activeIds: in Set[UserId]): slice[String] {
  return users
    .filter { u -> activeIds.contains(u.id) }
    .map { u -> u.name }
    .sortBy { name -> name }
}

// ─── Multiple return values ──────────────────────────────────────────────────

pub func minMax(xs: in slice[Int]): (Int, Int)
  requires: xs.length > 0
{
  var lo = xs[0]
  var hi = xs[0]
  for x in xs {
    if x < lo { lo = x }
    if x > hi { hi = x }
  }
  return (lo, hi)
}

// ─── Closures ────────────────────────────────────────────────────────────────

pub func makeMultiplier(factor: in Int): {Int -> Int} {
  return { x -> x * factor }
}

// ─── Entry point ─────────────────────────────────────────────────────────────

func main(): Unit {
  val double = makeMultiplier(2)
  println("double 5 = ${toString(double(5))}")

  val result = parseOrder("42", "1500")
  match result {
    case Ok(order)  -> println("order total: ${toString(order.totalCents.toLong())} cents")
    case Err(e)     -> println("error: ${describeError(e)}")
  }

  val nums = [5, 3, 8, 1, 9, 2]
  val (lo, hi) = minMax(nums)
  println("range: ${toString(lo)} to ${toString(hi)}")
}
