//! propagate_hoist_self_test.l — dedicated regression test for the `?`
//! operand-position hoist in `Lyric.Propagate` (#6448).
//!
//! `?` in a method-call argument (the receiver is a stacked operand ahead of
//! it) or a non-first argument of a free call desugars — via the pre-existing
//! `e?` -> `match ... case Err(x) -> { return Err(x) }` rewrite — into an
//! expression-position early return that fires with operands already pushed
//! on the evaluation stack: `InvalidProgramException` on MSIL, inconsistent
//! stackmap frames on JVM.  `Lyric.Propagate`'s statement-level hoist
//! (mirroring `Lyric.AwaitHoist`, #5606) rewrites these shapes into hoisted
//! `val` bindings BEFORE the match rewrite, so the early return lands as a
//! safe statement-level initializer on both targets.
//!
//! Every helper below both LOGS an ordering marker and returns a value, so a
//! hoist that silently reorders operands (not just miscomputes one) fails a
//! `log` assertion even when the final numeric result looks plausible —
//! mirroring `await_hoist_self_test.l`'s evaluation-order methodology.
//!
//! Run in CI via native `lyric test` on BOTH targets (model:
//! `bitwise_self_test.l` / `await_hoist_self_test.l`): `--target dotnet`
//! compiles in-process through `Msil.Bridge` (the load-bearing target — this
//! is where the reported crash happened); `--target jvm` compiles in-process
//! through `Jvm.Bridge` (`compileToJarBundled`) and runs under `java` (the
//! reported stackmap-frame VerifyError target).  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.PropagateHoistSelfTest

import Std.Collections
import Std.Core
import Std.Testing

record Item {
  name: String
}

// ── Ordering helpers ─────────────────────────────────────────────────────────
func mark(log: in List[String], tag: in String, value: in Int): Int {
  log.add(tag)
  value
}

func markOk(log: in List[String], tag: in String, value: in Int): Result[Int, String] {
  log.add(tag)
  Ok(value)
}

func markErr(log: in List[String], tag: in String, label: in String): Result[Int, String] {
  log.add(tag)
  Err(label)
}

func joinLog(log: in List[String]): String {
  var s = ""
  var i = 0
  while i < log.count {
    if i > 0 {
      s = s + ","
    }
    s = s + log[i]
    i = i + 1
  }
  s
}

// ── Method-call argument: receiver is a stacked operand ──────────────────────
// items.add(decodeItem("good")?) — the #6448 repro shape.
func decodeItem(s: in String): Result[Item, String] {
  if s == "good" {
    Ok(Item(name = s))
  } else {
    Err("bad item: " + s)
  }
}

func collectOne(s: in String): Result[List[Item], String] {
  val items: List[Item] = newList()
  items.add(decodeItem(s)?)
  Ok(items)
}

test "method-call arg ?: Ok path adds the unwrapped value" {
  val r = collectOne("good")
  match r {
    case Ok(xs) -> {
      assertEqualInt(xs.count, 1, "one item added")
      assertEqual(xs[0].name, "good", "unwrapped value flows through")
    }
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "method-call arg ?: Err path early-returns and never adds" {
  val r = collectOne("bad")
  match r {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> assertEqual(e, "bad item: bad", "the propagated Err surfaces")
  }
}

// Method-call receiver logs before the hoisted `?` argument (UFCS desugars
// `recv.m(arg)` to `m(recv, arg)` — the receiver is evaluated first).  The
// receiver itself is a non-trivial expression (a call, not a bare name) so
// its own evaluation is independently observable in `log`.
record Acc {
  items: List[String]

  func addToAcc(self: in Acc, v: in String): Int {
    self.items.add(v)
    self.items.count
  }
}

func markAcc(log: in List[String], tag: in String, items: in List[String]): Acc {
  log.add(tag)
  Acc(items = items)
}

func methodReceiverOrder(log: in List[String], items: in List[String]): Result[Int, String] {
  Ok(markAcc(log, "recv", items).addToAcc(toString(markOk(log, "arg", 7)?)))
}

test "method-call receiver evaluates before the hoisted ? argument" {
  val log: List[String] = newList()
  val items: List[String] = newList()
  val r = methodReceiverOrder(log, items)
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 1, "one item added to the accumulator")
  assertEqual(joinLog(log), "recv,arg", "receiver logs before the ?-bearing argument")
  assertEqual(items[0], "7", "the unwrapped value flows into the receiver's method call")
}

// ── Second argument of a free call: only-and-first-arg was already safe,
//    a non-first arg was the reported gap. ───────────────────────────────────
func addOne(a: in Int, b: in Int): Int {
  a + b
}

func secondFreeArg(log: in List[String]): Result[Int, String] {
  Ok(addOne(mark(log, "a", 41), markOk(log, "b", 1)?))
}

test "second argument of a free call: ? hoists, siblings keep order" {
  val log: List[String] = newList()
  val r = secondFreeArg(log)
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 42, "41 + 1 = 42")
  assertEqual(joinLog(log), "a,b", "left-to-right order preserved around the hoist")
}

func secondFreeArgErr(log: in List[String]): Result[Int, String] {
  Ok(addOne(41, markErr(log, "b", "nope")?))
}

test "second argument of a free call: Err short-circuits" {
  val log: List[String] = newList()
  val r = secondFreeArgErr(log)
  assertEqual((match r { case Ok(_) -> "ok"; case Err(e) -> e }), "nope", "the second-arg Err propagates")
}

// ── Nested `?`: f(g()?)? ──────────────────────────────────────────────────────
func parseId(s: in String): Result[Int, String] {
  if s == "7" {
    Ok(7)
  } else {
    Err("bad id: " + s)
  }
}

func describeId(id: in Int): Result[String, String] {
  if id > 0 {
    Ok("id-" + toString(id))
  } else {
    Err("non-positive id")
  }
}

func nestedProp(s: in String): Result[String, String] {
  Ok(describeId(parseId(s)?)?)
}

test "nested ?: f(g()?)? unwraps through both layers" {
  assertEqual((match nestedProp("7") { case Ok(v) -> v; case Err(_) -> "ERR" }), "id-7", "both ?s unwrap")
  assertEqual((match nestedProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }), "bad id: x", "inner ? propagates first")
}

// Nested ? as a method-call argument: items.add(describeId(parseId(s)?)?) —
// combines the method-call-argument hazard with the nested-? hazard.
func collectDescribed(s: in String): Result[List[String], String] {
  val results: List[String] = newList()
  results.add(describeId(parseId(s)?)?)
  Ok(results)
}

test "nested ? inside a method-call argument" {
  val r = collectDescribed("7")
  match r {
    case Ok(xs) -> assertEqual(xs[0], "id-7", "both ?s unwrap inside the call argument")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  val e = collectDescribed("x")
  assertEqual((match e { case Ok(_) -> "OK"; case Err(msg) -> msg }), "bad id: x", "the inner ? still short-circuits")
}

// ── ? in a binop operand ──────────────────────────────────────────────────────
func binopProp(log: in List[String]): Result[Int, String] {
  Ok(mark(log, "lhs", 10) + markOk(log, "rhs", 5)?)
}

test "? in a binop RHS operand" {
  val log: List[String] = newList()
  val r = binopProp(log)
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 15, "10 + 5 = 15")
  assertEqual(joinLog(log), "lhs,rhs", "lhs evaluates before the hoisted rhs ?")
}

// ── ? in a constructor argument ───────────────────────────────────────────────
func nameFromId(id: in String): Result[String, String] {
  if id == "9" {
    Ok("item-9")
  } else {
    Err("bad name id: " + id)
  }
}

func ctorArgProp(id: in String): Result[Item, String] {
  Ok(Item(name = nameFromId(id)?))
}

test "? in a constructor argument" {
  assertEqual(
    (match ctorArgProp("9") { case Ok(it) -> it.name; case Err(_) -> "ERR" }),
    "item-9",
    "unwrapped value flows into the record field"
  )
  assertEqual(
    (match ctorArgProp("0") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad name id: 0",
    "ctor-arg ? still propagates"
  )
}

// ── ? in a string interpolation segment ───────────────────────────────────────
func interpProp(id: in String): Result[String, String] {
  Ok("name=${nameFromId(id)?}!")
}

test "? in a string interpolation segment" {
  assertEqual(
    (match interpProp("9") { case Ok(s) -> s; case Err(_) -> "ERR" }),
    "name=item-9!",
    "interpolated ? unwraps"
  )
  assertEqual(
    (match interpProp("0") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad name id: 0",
    "interpolation ? still propagates"
  )
}

// ── ? in a while-loop condition ───────────────────────────────────────────────
// A bare `while call()?` (the whole condition IS the `?`) needs no hoist at
// all — the operand stack is already empty at the top of every iteration,
// exactly like `val x = e?`.  The hazard is a `?` NESTED inside the
// condition's own operand position — here, the second argument of a free
// call — which re-evaluates every iteration, so the hoisted binding must
// live INSIDE the loop, not just once before it (the
// `loop { <hoisted>; if cond { body } else { break } }` rewrite).
func loopCheck(log: in List[String], i: in Int, limit: in Int): Result[Bool, String] {
  log.add("cond" + toString(i))
  Ok(i < limit)
}

func combineCond(guardVal: in Int, ok: in Bool): Bool {
  ok
}

func whileCondProp(log: in List[String], limit: in Int): Result[Int, String] {
  var i = 0
  var total = 0
  while combineCond(mark(log, "guard", 0), loopCheck(log, i, limit)?) {
    total = total + i
    i = i + 1
  }
  Ok(total)
}

test "? nested in a while-loop condition re-evaluates every iteration" {
  val log: List[String] = newList()
  val r = whileCondProp(log, 3)
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 3, "0 + 1 + 2 = 3")
  assertEqual(
    joinLog(log),
    "guard,cond0,guard,cond1,guard,cond2,guard,cond3",
    "the hoisted binding re-evaluates once per iteration, in order, including the final false check"
  )
}

// ── Still-working shapes: pinned as non-regressions ───────────────────────────
// `val x = e?` as a whole statement — never needed hoisting.
func valInitProp(s: in String): Result[Int, String] {
  val v = parseId(s)?
  Ok(v * 2)
}

test "val-init ?: unchanged shape still works" {
  assertEqualInt((match valInitProp("7") { case Ok(v) -> v; case Err(_) -> -1 }), 14, "7 * 2 = 14")
  assertEqual(
    (match valInitProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "val-init ? still propagates"
  )
}

// First (and only) argument of a FREE call — already safe (no operand
// stacked ahead of it), must stay byte-identical (no hoist).
func firstFreeArgOnly(id: in Int): Int {
  0 - id
}

func firstFreeArgProp(s: in String): Result[Int, String] {
  Ok(firstFreeArgOnly(parseId(s)?))
}

test "first argument of a free call ?: unchanged shape still works" {
  assertEqualInt((match firstFreeArgProp("7") { case Ok(v) -> v; case Err(_) -> 999 }), -7, "0 - 7 = -7")
  assertEqual(
    (match firstFreeArgProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "first-free-arg ? still propagates"
  )
}

// ── #6456: assignment to a member/index target with a ?-bearing value ────────
// `b.value = parseId(s)?` — MSIL's lowerAssignExprMsil pushes the receiver
// (and index operands) BEFORE the value evaluates, with no spill, so the
// early return fired with a non-empty stack (InvalidProgramException). The
// hoist rebinds the target's receiver/index operands to temps in evaluation
// order, then binds the value out (phBindAssignTarget). JVM was never
// broken here (its assignment lowering already spills, #5936) but runs the
// same cases for parity.
record Cell {
  var value: Int
}

func memberAssignProp(log: in List[String], s: in String): Result[Int, String] {
  val c = Cell(value = 0)
  c.value = markOk(log, "value", 0)? + parseId(s)?
  Ok(c.value)
}

test "member-target assign ?: Ok path stores the unwrapped value" {
  val log: List[String] = newList()
  val r = memberAssignProp(log, "7")
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 7, "0 + 7 stored through the member write")
  assertEqual(joinLog(log), "value", "the value expression ran exactly once")
}

test "member-target assign ?: Err path early-returns without storing" {
  val log: List[String] = newList()
  val r = memberAssignProp(log, "x")
  assertEqual(
    (match r { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from a member-assign value"
  )
}

func indexAssignProp(s: in String): Result[Int, String] {
  val arr: List[Int] = newList()
  arr.add(0)
  arr[0] = parseId(s)?
  Ok(arr[0])
}

test "index-target assign ?: Ok path stores, Err path propagates" {
  assertEqualInt(
    (match indexAssignProp("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    7,
    "the unwrapped value lands through the index write"
  )
  assertEqual(
    (match indexAssignProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from an index-assign value"
  )
}

// Compound assignment through a member target: the receiver is stacked for
// both the read and the write, so the same hoist applies.
func memberCompoundProp(s: in String): Result[Int, String] {
  val c = Cell(value = 10)
  c.value = c.value + parseId(s)?
  Ok(c.value)
}

test "member-target compound-shaped assign ?: reads then adds through the temp" {
  assertEqualInt(
    (match memberCompoundProp("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    17,
    "10 + 7 through the member read/write"
  )
  assertEqual(
    (match memberCompoundProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from a compound member assign"
  )
}

// Evaluation-order pin: the target's receiver expression must still run
// BEFORE the hoisted value (the original member-assign order), so a
// side-effecting receiver observes the pre-value state.
func markCell(log: in List[String], tag: in String): Cell {
  log.add(tag)
  Cell(value = 0)
}

func receiverOrderProp(log: in List[String]): Result[Int, String] {
  markCell(log, "recv").value = markOk(log, "value", 3)?
  Ok(99)
}

test "member-target assign ?: receiver still evaluates before the hoisted value" {
  val log: List[String] = newList()
  val r = receiverOrderProp(log)
  assertEqualInt((match r { case Ok(v) -> v; case Err(_) -> -1 }), 99, "assignment completes")
  assertEqual(joinLog(log), "recv,value", "receiver, then value — original order preserved by the temps")
}
