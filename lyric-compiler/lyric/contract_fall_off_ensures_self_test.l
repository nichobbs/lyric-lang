//! contract_fall_off_ensures_self_test.l — #7747: a `Unit` function's
//! postcondition must be checked when its body falls off the end, whatever
//! kind of statement comes last.
//!
//! The contract elaborator checks `ensures:` at every `return` and, for an
//! implicit fall-off, after a trailing expression statement.  A body whose
//! last statement was not an expression — an assignment, a loop, `defer`,
//! `scope`, `try`, a local binding — or that was empty never ran the check,
//! so `func bump(x: inout Int): Unit ensures: x == 100 { x = x + 2 }` passed
//! silently on both targets.  Protected-type invariants, which ride the same
//! path as `ensures:`, were skipped the same way for entries ending in an
//! assignment.
//!
//! Each case below has a satisfying call and a violating call; the violating
//! one must panic with `PostconditionViolated` (or `InvariantViolated`).
//!
//! Run via native `lyric test` on both targets.  Imports only `Std.*`.
//!
//!   lyric test lyric-compiler/lyric/contract_fall_off_ensures_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/contract_fall_off_ensures_self_test.l
@test_module
package Lyric.ContractFallOffEnsuresSelfTest

import Std.Core
import Std.Collections
import Std.Testing

pub record Cell {
  var n: Int
}

// ─── Trailing assignment forms ───────────────────────────────────────────────
func bump(x: inout Int, d: in Int): Unit
  ensures: x == old(x) + 1
{
  x = x + d
}

func assignPlain(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  x = v
}

func assignCompound(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  x += v
}

func assignField(c: in Cell, v: in Int): Unit
  ensures: c.n == 100
{
  c.n = v
}

func assignIndex(xs: in List[Int], v: in Int): Unit
  ensures: xs[0] == 100
{
  xs[0] = v
}

func assignOut(x: out Int, v: in Int): Unit
  ensures: x == 100
{
  x = v
}

// No return type annotation at all: still a Unit function.
func assignNoRetType(x: inout Int, v: in Int)
  ensures: x == 100
{
  x = v
}

test "trailing assignment checks ensures (#7747)" {
  var a = 99
  bump(a, 1)
  assertEqualInt(a, 100, "bump by one satisfies ensures")
  assertPanicsWith("bump by two", "PostconditionViolated", { -> var b = 98; bump(b, 2) })
  var c = 0
  assignPlain(c, 100)
  assertEqualInt(c, 100, "plain assignment")
  assertPanicsWith("plain assignment", "PostconditionViolated", { -> var d = 0; assignPlain(d, 99) })
}

test "trailing compound assignment checks ensures (#7747)" {
  var a = 90
  assignCompound(a, 10)
  assertEqualInt(a, 100, "compound assignment")
  assertPanicsWith("compound assignment", "PostconditionViolated", { -> var b = 90; assignCompound(b, 11) })
}

test "trailing field assignment checks ensures (#7747)" {
  val c = Cell(n = 0)
  assignField(c, 100)
  assertEqualInt(c.n, 100, "field assignment")
  assertPanicsWith("field assignment", "PostconditionViolated", { -> assignField(Cell(n = 0), 7) })
}

test "trailing index assignment checks ensures (#7747)" {
  val xs: List[Int] = newList()
  xs.add(0)
  assignIndex(xs, 100)
  assertEqualInt(xs[0], 100, "index assignment")
  assertPanicsWith("index assignment", "PostconditionViolated", { -> assignIndex(xs, 7) })
}

test "trailing assignment to an out parameter checks ensures (#7747)" {
  var a = 0
  assignOut(a, 100)
  assertEqualInt(a, 100, "out assignment")
  assertPanicsWith("out assignment", "PostconditionViolated", { -> var b = 0; assignOut(b, 1) })
}

test "trailing assignment without a return type checks ensures (#7747)" {
  var a = 0
  assignNoRetType(a, 100)
  assertEqualInt(a, 100, "no return type")
  assertPanicsWith("no return type", "PostconditionViolated", { -> var b = 0; assignNoRetType(b, 1) })
}

// ─── Trailing loops ──────────────────────────────────────────────────────────
func whileTo(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  while x < v {
    x = x + 1
  }
}

func forCount(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  for i in 0 ..< v {
    x = x + 1
  }
}

func loopBreak(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  do {
    x = x + 1
    if x >= v {
      break
    }
  }
}

test "trailing while loop checks ensures (#7747)" {
  var a = 0
  whileTo(a, 100)
  assertEqualInt(a, 100, "while")
  assertPanicsWith("while", "PostconditionViolated", { -> var b = 0; whileTo(b, 50) })
}

test "trailing for loop checks ensures (#7747)" {
  var a = 0
  forCount(a, 100)
  assertEqualInt(a, 100, "for")
  assertPanicsWith("for", "PostconditionViolated", { -> var b = 0; forCount(b, 3) })
}

test "trailing loop left by break checks ensures (#7747)" {
  var a = 0
  loopBreak(a, 100)
  assertEqualInt(a, 100, "loop/break")
  assertPanicsWith("loop/break", "PostconditionViolated", { -> var b = 0; loopBreak(b, 4) })
}

// ─── Trailing conditionals and matches with statement bodies ────────────────
func ifNoElse(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  if v > 0 {
    x = v
  }
}

func ifElse(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  if v > 0 {
    x = v
  } else {
    x = 0 - v
  }
}

func matchArms(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  match v {
    case 0 -> {
      x = 100
    }
    case _ -> {
      x = v
    }
  }
}

test "trailing if without else checks ensures (#7747)" {
  var a = 0
  ifNoElse(a, 100)
  assertEqualInt(a, 100, "if")
  assertPanicsWith("if, taken", "PostconditionViolated", { -> var b = 0; ifNoElse(b, 5) })
  assertPanicsWith("if, not taken", "PostconditionViolated", { -> var b = 0; ifNoElse(b, -5) })
}

test "trailing if/else with statement branches checks ensures (#7747)" {
  var a = 0
  ifElse(a, -100)
  assertEqualInt(a, 100, "else branch")
  assertPanicsWith("if/else", "PostconditionViolated", { -> var b = 0; ifElse(b, 5) })
}

test "trailing match with block arms checks ensures (#7747)" {
  var a = 0
  matchArms(a, 0)
  assertEqualInt(a, 100, "match arm 0")
  assertPanicsWith("match", "PostconditionViolated", { -> var b = 0; matchArms(b, 5) })
}

// ─── Trailing call, defer, scope, try, binding; empty body ───────────
func setTo(y: inout Int, v: in Int): Unit {
  y = v
}

func callUnit(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  setTo(x, v)
}

// The postcondition runs at the fall-off point, as at a `return`: before the
// deferred block.
func withDefer(x: inout Int, v: in Int, log: in List[Int]): Unit
  ensures: x == 100
{
  x = v
  defer {
    log.add(x)
  }
}

func inScope(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  scope {
    x = v
  }
}

func tryCatch(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  try {
    x = v
  } catch Bug as _ {
    x = 0
  }
}

func trailingBinding(x: inout Int, v: in Int): Unit
  ensures: x == 100
{
  x = v
  val _ = x + 1
}

func emptyBody(x: in Int): Unit
  ensures: x == 100
{
}

test "trailing Unit call checks ensures (#7747)" {
  var a = 0
  callUnit(a, 100)
  assertEqualInt(a, 100, "call")
  assertPanicsWith("call", "PostconditionViolated", { -> var b = 0; callUnit(b, 1) })
}

test "trailing defer checks ensures (#7747)" {
  val log: List[Int] = newList()
  var a = 0
  withDefer(a, 100, log)
  assertEqualInt(a, 100, "defer")
  assertEqualInt(log.count, 1, "the deferred block still runs")
  assertPanicsWith("defer", "PostconditionViolated", { -> var b = 0; withDefer(b, 1, log) })
}

test "trailing scope checks ensures (#7747)" {
  var a = 0
  inScope(a, 100)
  assertEqualInt(a, 100, "scope")
  assertPanicsWith("scope", "PostconditionViolated", { -> var b = 0; inScope(b, 1) })
}

test "trailing try/catch checks ensures (#7747)" {
  var a = 0
  tryCatch(a, 100)
  assertEqualInt(a, 100, "try")
  assertPanicsWith("try", "PostconditionViolated", { -> var b = 0; tryCatch(b, 1) })
}

test "trailing local binding checks ensures (#7747)" {
  var a = 0
  trailingBinding(a, 100)
  assertEqualInt(a, 100, "binding")
  assertPanicsWith("binding", "PostconditionViolated", { -> var b = 0; trailingBinding(b, 1) })
}

test "empty body checks ensures (#7747)" {
  emptyBody(100)
  assertPanicsWith("empty body", "PostconditionViolated", { -> emptyBody(1) })
}

// ─── Methods ─────────────────────────────────────────────────────────────────
pub record Counter {
  var hits: Int

  func setHits(self: in Counter, v: in Int): Unit
    ensures: self.hits == 100
  {
    self.hits = v
  }
}

pub interface Resettable {
  func resetTo(self: in Self, v: in Int): Unit
    ensures: v == 100
}

pub record Gauge {
  var level: Int
}

impl Resettable for Gauge {
  func resetTo(self: in Gauge, v: in Int): Unit {
    self.level = v
  }
}

test "record method ending in an assignment checks ensures (#7747)" {
  val c = Counter(hits = 0)
  c.setHits(100)
  assertEqualInt(c.hits, 100, "record method")
  assertPanicsWith("record method", "PostconditionViolated", { -> Counter(hits = 0).setHits(1) })
}

test "impl method ending in an assignment checks the inherited ensures (#7747)" {
  val g = Gauge(level = 0)
  g.resetTo(100)
  assertEqualInt(g.level, 100, "impl method")
  assertPanicsWith("impl method", "PostconditionViolated", { -> Gauge(level = 0).resetTo(1) })
}

// ─── Protected types ─────────────────────────────────────────────────────────
protected type Account {
  var balance: Int = 0
  invariant: balance >= 0
  entry deposit(d: in Int): Unit {
    balance = balance + d
  }
  entry setBalance(v: in Int, extra: in Int): Unit
    ensures: balance == v
  {
    balance = v + extra
  }
  func current(): Int {
    return balance
  }
}

test "protected entry ending in an assignment checks the type invariant (#7747)" {
  val acct = Account()
  acct.deposit(5)
  assertEqualInt(acct.current(), 5, "deposit")
  assertPanicsWith("deposit", "InvariantViolated", { -> Account().deposit(-5) })
}

test "protected entry ending in an assignment checks ensures (#7747)" {
  val acct = Account()
  acct.setBalance(3, 0)
  assertEqualInt(acct.current(), 3, "setBalance")
  assertPanicsWith("setBalance", "PostconditionViolated", { -> Account().setBalance(3, 1) })
}

// ─── Aspect-woven functions ──────────────────────────────────────────────────
// The wrapper the weaver builds from this advice ends in an assignment, so the
// aspect's own `ensures:` is checked at that fall-off.
aspect Audited {
  matches: name in { audited }
  ensures: args.v == 100
  around(args) -> ret {
    proceed(args)
    var calls = 0
    calls = calls + 1
  }
}

func audited(v: in Int): Unit {
}

test "aspect ensures on a wrapper whose advice ends in an assignment (#7747)" {
  audited(100)
  assertPanicsWith("aspect", "PostconditionViolated", { -> audited(1) })
}
