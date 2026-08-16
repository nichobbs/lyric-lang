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
//!
//! #6458 addendum: a `?` reachable only through a value-position `try`
//! expression used as a stacked call argument (`xs.add(try { e? } catch …)`)
//! is covered too — verified NOT to be a gap (see `propagate.l`'s §2b module
//! doc).
//!
//! #6471 addendum: a `try` expression with NO `?` anywhere still crashed in
//! the same stacked-operand position on both targets (confirmed via a
//! standalone `lyric run` repro — `InvalidProgramException` on MSIL,
//! `VerifyError` on JVM) because nothing gated the hoist on an `STry`'s mere
//! PRESENCE, only on a `?` found inside one.  Fixed by broadening
//! `phHasHazardStmt`'s `STry` case (renamed from `phHasPropStmt`, see
//! `propagate.l`'s §2b module doc) to report a hazard unconditionally.  The
//! previously-uncompilable shapes below are now embedded directly in this
//! shared `@test_module`, since they compile validly post-fix.
//!
//! D-progress-771 addendum: `?` inside a `protected type` `entry` body, in
//! the SAME stacked-operand position (`items.add(decode(s)?)`), was the
//! ORIGINAL pin queued by PR #6474's review — unwritable until two sibling
//! bugs found while isolating it were fixed: #6475 (MSIL — a non-tail
//! `return` reachable from inside an entry body's `if`/`match` threw
//! `InvalidProgramException`; `?`'s desugared match's Err arm, `return
//! Err(x)`, is exactly that shape) and #6479 (JVM — a protected-type `var`
//! field with a collection-typed default never ran its initializer, so
//! `items.add(...)` NPE'd on a null `items`).  #6476 (JVM `?` in an entry
//! failing codegen with "match not exhaustive") turned out NOT to reproduce
//! with well-typed code once isolated from #6475/#6479 — see D-progress-771
//! for the full writeup.  The entry-body early-return and collection-default
//! cases each fix unblocked are pinned separately, below.
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

// First (and only) argument of a FREE call.  Since #6460 this shape IS
// hoisted (a bare-name callee can't be syntactically distinguished from a
// lambda value, so the first-arg exemption was dropped) — this pins that the
// hoisted form behaves identically to the old direct form.
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

// #6464: the REAL `+=` compound-operator form (AssignOp `AssPlus`), not the
// hand-desugared `c.value = c.value + ...` shape above — `phNeedsHoistStmt`'s
// `SAssign` case is op-agnostic (it inspects `target`/`value`, never `op`),
// so `+=` on a member target rides the exact same #6456 stacked-target rule.
func memberCompoundOperatorProp(s: in String): Result[Int, String] {
  val c = Cell(value = 10)
  c.value += parseId(s)?
  Ok(c.value)
}

test "member-target += compound operator ?: Ok path adds through the temp" {
  assertEqualInt(
    (match memberCompoundOperatorProp("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    17,
    "10 += 7 through the real += operator on a member target"
  )
}

test "member-target += compound operator ?: Err path early-returns without storing" {
  assertEqual(
    (match memberCompoundOperatorProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from a += member assign"
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

// ── #6460: call through a lambda VALUE — callee reference is stacked ─────────
// `val f: (Int) -> Int = { x: Int -> ... }; f(parseId(s)?)` parses to the
// same ECall(EPath, args) shape as a free call, but invoking it pushes the
// delegate/closure reference before arguments evaluate on both targets, so
// even a first-and-only ? argument is a stacking hazard. The first-arg
// exemption was dropped entirely (any ?-bearing call argument hoists).
func lambdaCalleeProp(s: in String): Result[Int, String] {
  val f: (Int) -> Int = { x: Int -> x * 10 }
  val r = f(parseId(s)?)
  Ok(r)
}

test "lambda-value callee ?: Ok path invokes with the unwrapped value" {
  assertEqualInt(
    (match lambdaCalleeProp("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    70,
    "7 * 10 through the lambda-value call"
  )
}

test "lambda-value callee ?: Err path early-returns without invoking" {
  assertEqual(
    (match lambdaCalleeProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from a lambda-value call argument"
  )
}

// The same hazard one level up: the callee is itself a call expression
// (`pickDoubler()(parseId(s)?)`) — the invoked value lands on the stack
// before the argument evaluates, and the old qualification missed this
// shape for the same reason.
func pickDoubler(): (Int) -> Int {
  { x: Int -> x * 2 }
}

func calleeExprProp(s: in String): Result[Int, String] {
  val r = pickDoubler()(parseId(s)?)
  Ok(r)
}

test "callee-expression call ?: Ok and Err paths both behave" {
  assertEqualInt(
    (match calleeExprProp("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    14,
    "7 * 2 through the callee-expression call"
  )
  assertEqual(
    (match calleeExprProp("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the propagated Err surfaces from a callee-expression call argument"
  )
}

// ── #6463: ? inside a record-BODY (D037) method ──────────────────────────────
// rewriteItem previously had no IRecord case, so a ? inside a record-body
// method reached codegen as a raw EPropagate — an identity pass-through on
// MSIL with no Err/None check at all (silent miscompile; worst on the Err
// path, where the raw Err value flowed on as if unwrapped).
record IdParser {
  scale: Int

  func parseScaled(self: in IdParser, s: in String): Result[Int, String] {
    val v = parseId(s)?
    Ok(v * self.scale)
  }

  func collectScaled(self: in IdParser, s: in String): Result[List[Int], String] {
    val acc: List[Int] = newList()
    acc.add(parseId(s)? * self.scale)
    Ok(acc)
  }
}

test "record-body method ?: Ok path unwraps, Err path propagates (#6463)" {
  val p = IdParser(scale = 3)
  assertEqualInt(
    (match p.parseScaled("7") { case Ok(v) -> v; case Err(_) -> -1 }),
    21,
    "7 * 3 through the record-method val-init ?"
  )
  assertEqual(
    (match p.parseScaled("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the Err propagates out of a record-body method (was: silent identity pass-through)"
  )
}

test "record-body method ?: operand-position hoist applies inside the method too (#6463)" {
  val p = IdParser(scale = 2)
  val r = p.collectScaled("7")
  match r {
    case Ok(xs) -> assertEqualInt(xs[0], 14, "7 * 2 lands through the hoisted method-call arg")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  assertEqual(
    (match p.collectScaled("x") { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad id: x",
    "the Err propagates from a hoisted arg inside a record-body method"
  )
}

// ── ? in operand position inside a loop invariant expression ─────────────────
// phHasPropStmt covered SInvariant but phNeedsHoistStmt didn't, so a ? in
// operand position inside an invariant: expression was detected as present
// but never hoisted — the same crash class in one narrow shape. checkLimit
// returns Result so the ? is real; the invariant compares against the
// unwrapped value each iteration.
func checkLimit(cap: in Int): Result[Int, String] {
  Ok(cap)
}

func sumWithPropInvariant(n: in Int): Result[Int, String] {
  var i = 0
  var sum = 0
  while i < n
    invariant: sum <= checkLimit(100)?
  {
    sum = sum + i
    i = i + 1
  }
  Ok(sum)
}

test "? in operand position inside a loop invariant expression hoists" {
  assertEqualInt(
    (match sumWithPropInvariant(5) { case Ok(v) -> v; case Err(_) -> -1 }),
    10,
    "0+1+2+3+4 = 10 with the ?-bearing invariant checked per iteration"
  )
}

// ── #6458: ? reachable only through a value-position `try` expression, used
//    as a method-call argument (the reported shape) ──────────────────────────
// `xs.add(v)` stacks the receiver `xs` before the argument evaluates; the
// argument here is `try { decodeChecked(s)? } catch Bug as b { -1 }`, a
// value-producing try/catch (parsed as `EBlock([STry(...)])`, per the §2b
// module doc's #6458 note — never a bare `ETry`).  The nested `?` makes
// `phHasProp` flag the argument, so `phHoistSpine`'s generic `EBlock` rule
// binds the WHOLE try expression to a fresh `val` before the call — entering
// the try's protected region with an empty stack — exactly the fix #6458
// asked for.  `decodeChecked` never actually throws (the catch clause is
// unreachable in this test), so the `log` marker inside the try body proves
// the try's own evaluation still runs in the right place relative to `mark`.
func decodeChecked(log: in List[String], s: in String): Result[Int, String] {
  log.add("decode")
  if s == "good" {
    Ok(7)
  } else {
    Err("bad checked id: " + s)
  }
}

func collectViaTry(log: in List[String], s: in String): Result[List[Int], String] {
  val xs: List[Int] = newList()
  xs.add(try { decodeChecked(log, s)? } catch Bug as b { -1 })
  Ok(xs)
}

test "try-expression call argument: ? inside the try body hoists (#6458)" {
  val log: List[String] = newList()
  val r = collectViaTry(log, "good")
  match r {
    case Ok(xs) -> assertEqualInt(xs[0], 7, "unwrapped value flows out of the hoisted try expression")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  assertEqual(joinLog(log), "decode", "the try body still evaluates exactly once")
}

test "try-expression call argument: ? inside the try body still propagates Err (#6458)" {
  val log: List[String] = newList()
  val r = collectViaTry(log, "bad")
  assertEqual(
    (match r { case Ok(_) -> "OK"; case Err(e) -> e }),
    "bad checked id: bad",
    "the Err propagates from inside the hoisted try expression, catch clause never runs"
  )
}

// ── #6471: a value-position `try` expression with NO `?` anywhere, used in a
//    stacked operand position — the previously-uncompilable shape.  Before
//    the fix, embedding any of the cases below would crash the whole module
//    at method-load time (`InvalidProgramException` on MSIL, `VerifyError`
//    on JVM), so none of them could live in this shared `@test_module`; see
//    `propagate.l`'s §2b module doc for the standalone `lyric run` evidence
//    that motivated filing #6471 in the first place.  `phHasHazardStmt`'s
//    `STry` case now reports presence unconditionally (not gated on a
//    nested `?`), so the SAME `EBlock`-binds-the-whole-block rewrite #6458
//    already exercised now also fires here.  `riskyNoProp` never actually
//    throws when `fail` is `false` (the catch clause is unreachable), so the
//    `log` marker inside the try body proves it still evaluates exactly
//    once, in the right place relative to its sibling operands.
func riskyNoProp(log: in List[String], fail: Bool): Int {
  log.add("risky")
  if fail {
    panic("boom")
  } else {
    7
  }
}

// The issue's own shape: `xs.add(try { risky() } catch Bug as b { 0 })`.
func collectViaNoPropTry(log: in List[String], fail: Bool): List[Int] {
  val xs: List[Int] = newList()
  xs.add(try { riskyNoProp(log, fail) } catch Bug as b { -1 })
  xs
}

test "try-expression call argument, no ? anywhere: Ok path adds the try body's value (#6471)" {
  val log: List[String] = newList()
  val xs = collectViaNoPropTry(log, false)
  assertEqualInt(xs[0], 7, "the try body's own value flows out of the hoisted try expression")
  assertEqual(joinLog(log), "risky", "the try body still evaluates exactly once")
}

test "try-expression call argument, no ? anywhere: catch path adds the handler's value (#6471)" {
  val log: List[String] = newList()
  val xs = collectViaNoPropTry(log, true)
  assertEqualInt(xs[0], -1, "the catch handler's value flows out when the try body panics")
  assertEqual(joinLog(log), "risky", "the try body still runs (and panics) exactly once")
}

// Second argument of a free call: `a` must still log before the hoisted
// try's own `log.add("risky")`, exactly like the `?`-bearing case above.
func secondFreeArgNoPropTry(log: in List[String], fail: Bool): Int {
  addOne(mark(log, "a", 41), try { riskyNoProp(log, fail) } catch Bug as b { -1 })
}

test "second argument of a free call: no-? try hoists, siblings keep order (#6471)" {
  val log: List[String] = newList()
  val r = secondFreeArgNoPropTry(log, false)
  assertEqualInt(r, 48, "41 + 7 = 48")
  assertEqual(joinLog(log), "a,risky", "left-to-right order preserved around the hoisted try")
}

test "second argument of a free call: no-? try catch path keeps order (#6471)" {
  val log: List[String] = newList()
  val r = secondFreeArgNoPropTry(log, true)
  assertEqualInt(r, 40, "41 + (-1) = 40 using the catch handler's value")
  assertEqual(joinLog(log), "a,risky", "left-to-right order preserved, catch handler value used")
}

// Regular (non-short-circuit) binop RHS: the LHS is pushed unconditionally
// before the RHS evaluates, so a no-? try RHS is a stacking hazard exactly
// like a ?-bearing RHS.
func binopNoPropTry(log: in List[String], fail: Bool): Int {
  mark(log, "lhs", 10) + (try { riskyNoProp(log, fail) } catch Bug as b { -1 })
}

test "no-? try in a binop RHS operand: Ok path keeps order (#6471)" {
  val log: List[String] = newList()
  val r = binopNoPropTry(log, false)
  assertEqualInt(r, 17, "10 + 7 = 17")
  assertEqual(joinLog(log), "lhs,risky", "lhs evaluates before the hoisted try rhs")
}

test "no-? try in a binop RHS operand: catch path keeps order (#6471)" {
  val log: List[String] = newList()
  val r = binopNoPropTry(log, true)
  assertEqualInt(r, 9, "10 + (-1) = 9 using the catch handler's value")
  assertEqual(joinLog(log), "lhs,risky", "lhs still evaluates before the hoisted try rhs")
}

// Member-target assign value (#6456's rule, extended by #6471): the
// receiver is stacked ahead of the value on MSIL, so a no-? try value needs
// the same rebind-then-hoist treatment as a ?-bearing value.
func memberAssignNoPropTry(log: in List[String], fail: Bool): Int {
  val c = Cell(value = 0)
  c.value = try {
    riskyNoProp(log, fail)
  } catch Bug as b {
    -1
  }
  c.value
}

test "member-target assign: no-? try value stores through the temp, both paths (#6471)" {
  val okLog: List[String] = newList()
  assertEqualInt(memberAssignNoPropTry(okLog, false), 7, "the try body's value is stored through the member write")
  val catchLog: List[String] = newList()
  assertEqualInt(
    memberAssignNoPropTry(catchLog, true),
    -1,
    "the catch handler's value is stored through the member write"
  )
}

// ── D-progress-771: `?` inside a `protected type` entry, stacked operand
//    position — the originally-queued PR #6474 pin (#6475/#6479/#6476).
func decodeCount(s: in String): Result[Int, String] {
  if s == "good" {
    Ok(1)
  } else {
    Err("bad count: " + s)
  }
}

protected type DecodeBag {
  var items: List[Int] = newList()
  entry addDecoded(s: in String): Result[Unit, String] {
    items.add(decodeCount(s)?)
    Ok(())
  }
  entry itemCount(): Int {
    items.count
  }
}

test "? inside a protected-type entry, stacked operand position: Ok path adds and stores (#6475/#6479)" {
  val bag = DecodeBag()
  val r = bag.addDecoded("good")
  match r {
    case Ok(_) -> assertEqualInt(bag.itemCount(), 1, "the unwrapped value flows into the collection field")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "? inside a protected-type entry, stacked operand position: Err path early-returns without storing (#6475/#6479)" {
  val bag = DecodeBag()
  val r = bag.addDecoded("bad")
  match r {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> {
      assertEqual(e, "bad count: bad", "the propagated Err surfaces from inside the entry")
      assertEqualInt(bag.itemCount(), 0, "the Err path never reaches items.add")
    }
  }
}

// ── D-progress-771: entry-body non-tail `return` (#6475) — a `return`
//    reachable from inside an `if`/`match`, not the entry's own literal last
//    statement, threw `InvalidProgramException` at first call on MSIL: the
//    epilogue's fall-through detection used a raw counter of how many
//    `return`s appeared ANYWHERE in the body instead of whether the TRAILING
//    statement itself already exited.
protected type Grader {
  var total: Int = 0
  entry grade(score: in Int): Int {
    if score >= 90 {
      return 100
    }
    score
  }
  entry gradeBoth(score: in Int): Int {
    if score >= 90 {
      return 100
    } else {
      return 0
    }
  }
}

test "entry-body non-tail return: if-without-else falls through to the trailing expression (#6475)" {
  val g = Grader()
  assertEqualInt(g.grade(95), 100, "the non-tail return short-circuits")
  assertEqualInt(g.grade(50), 50, "falling through past the if reaches the trailing expression")
}

test "entry-body non-tail return: if/else where both branches return (#6475)" {
  val g = Grader()
  assertEqualInt(g.gradeBoth(95), 100, "the then-branch return")
  assertEqualInt(g.gradeBoth(50), 0, "the else-branch return")
}

// ── D-progress-771: protected-type `var` field with a collection-typed
//    default (#6479) — on JVM, the field's initializer was never run
//    (`this.items` read back `null`); MSIL was unaffected.
protected type Basket {
  var fruits: List[String] = newList()
  entry addFruit(name: in String): Unit {
    fruits.add(name)
  }
  entry fruitCount(): Int {
    fruits.count
  }
}

test "protected-type var field with a collection-typed default runs its initializer (#6479)" {
  val basket = Basket()
  assertEqualInt(basket.fruitCount(), 0, "the collection default initializes to empty, not null")
  basket.addFruit("apple")
  assertEqualInt(basket.fruitCount(), 1, "adding to the initialized collection works")
}

// ── #6485: the `self.`-spelling twin of `DecodeBag` above — the exact same
// `?` inside a protected-type entry, stacked operand position, but with the
// field accessed via the explicit `self.` receiver instead of bare-name.
// Before #6485's type-checker fix `self.field` bypassed body type-checking
// entirely (silent `TyError`), but the two spellings were always codegen-
// equivalent — this is a runtime end-to-end proof that the newly-checked
// spelling still compiles and runs identically to the bare-name form.
protected type SelfDecodeBag {
  var items: List[Int] = newList()
  entry addDecoded(s: in String): Result[Unit, String] {
    self.items.add(decodeCount(s)?)
    Ok(())
  }
  entry itemCount(): Int {
    self.items.count
  }
}

test "? inside a protected-type entry via self.field, stacked operand position: Ok path adds and stores (#6485)" {
  val bag = SelfDecodeBag()
  val r = bag.addDecoded("good")
  match r {
    case Ok(_) -> assertEqualInt(bag.itemCount(), 1, "the unwrapped value flows into the collection field via self.")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "? inside a protected-type entry via self.field, stacked operand position: Err path early-returns without storing (#6485)" {
  val bag = SelfDecodeBag()
  val r = bag.addDecoded("bad")
  match r {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(e) -> {
      assertEqual(e, "bad count: bad", "the propagated Err surfaces from inside the entry")
      assertEqualInt(bag.itemCount(), 0, "the Err path never reaches items.add")
    }
  }
}
