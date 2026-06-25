//! async_sm_self_test.l — regression test for user-defined `async func`
//! IAsyncStateMachine synthesis (Phase B.0 + B.1 + promoted locals +
//! B.2+ var/while + B.3 stack-spill + Phase 4 spawn, Epic #2070).
//!
//! Phase B.0 covers async functions whose bodies contain NO EAwait nodes.
//! Phase B.1 covers async functions whose bodies contain one or more EAwait
//! nodes: real AwaitUnsafeOnCompleted suspension with a state-dispatch switch,
//! typed awaiter fields, and resume labels.
//! Promoted locals: val-bindings computed before an await point and used after
//! it are hoisted to SM fields so they survive between MoveNext invocations.
//! Phase B.2+: var bindings and while-loop await scanning.
//! Phase B.3: binop LHS stack-spill when RHS contains an await.
//! Phase 4: spawn semantics — `spawn f()` returns Task<T>; `await handle`
//! unwraps it (blocking in non-SM, Phase B suspension in SM context).
//!
//! Test callers use `await asyncXxx(...)` because the kickoff returns Task<T>
//! (or Task for void); `emitBlockingAwait` in non-SM contexts synchronously
//! resolves via GetAwaiter().GetResult().
//!
//!   lyric test lyric-compiler/lyric/async_sm_self_test.l
@test_module
package Lyric.AsyncSmSelfTest

import Std.Core
import Std.Testing

// ── Phase B.0: no awaits in body ─────────────────────────────────────────────
// Returns an Int.  No awaits in the body.
async func asyncAddOne(n: in Int): Int {
  n + 1
}

// Returns a String concatenation.
async func asyncGreet(name: in String): String {
  "Hello, " + name + "!"
}

// Void path: AsyncTaskMethodBuilder, not AsyncTaskMethodBuilder<T>.
async func asyncNoop(): Unit = ()

// Void async func with a side-effecting body (uses a local var).
async func asyncDoubleAndDiscard(n: in Int): Unit {
  val doubled = n * 2
  val _ = doubled
}

// Explicit-return paths (regression for #2256).
async func asyncReturnExplicit(n: in Int): Int {
  return n * 2
}

async func asyncReturnFromBranch(n: in Int): Int {
  if n > 0 {
    return n
  }
  0 - n
}

// ── Phase B.1: awaits in body ─────────────────────────────────────────────────
// Two sequential awaits: each chains into Phase B.0 asyncAddOne.
// asyncAddTwo(n) = n + 2
async func asyncAddTwo(n: in Int): Int {
  val a = await asyncAddOne(n)
  await asyncAddOne(a)
}

// Three sequential awaits.
// asyncAddThree(n) = n + 3
async func asyncAddThree(n: in Int): Int {
  val a = await asyncAddOne(n)
  val b = await asyncAddOne(a)
  await asyncAddOne(b)
}

// Void async func that awaits a non-void result and discards it.
async func asyncVoidChain(n: in Int): Unit {
  val _ = await asyncAddOne(n)
}

// Computes (a + b) via two awaits.
// asyncSumViaAwait(a, b) = a + b
async func asyncSumViaAwait(a: in Int, b: in Int): Int {
  val stepped = await asyncAddOne(a - 1)
  await asyncAddOne(stepped + b - 1)
}

// ── Phase B.0 tests ───────────────────────────────────────────────────────────
test "non-void async func: Int return" {
  val result = await asyncAddOne(41)
  assertEqualInt(result, 42, "asyncAddOne(41) should return 42")
}

test "non-void async func: String return" {
  val greeting = await asyncGreet("World")
  assertEqual(greeting, "Hello, World!", "asyncGreet should return the greeting string")
}

test "void async func: no-op completes without error" {
  await asyncNoop()
  assertTrue(true, "void async func returned normally")
}

test "void async func: body with local val completes without error" {
  await asyncDoubleAndDiscard(21)
  assertTrue(true, "void async func with local completed normally")
}

test "non-void async func: result matches synchronous computation" {
  val a = await asyncAddOne(0)
  val b = await asyncAddOne(a)
  val c = await asyncAddOne(b)
  assertEqualInt(c, 3, "three sequential asyncAddOne calls should give 3")
}

test "non-void async func: explicit return computes correct value" {
  val result = await asyncReturnExplicit(21)
  assertEqualInt(result, 42, "asyncReturnExplicit(21) should return 42")
}

test "non-void async func: explicit return from branch computes correct value" {
  val pos = await asyncReturnFromBranch(5)
  val neg = await asyncReturnFromBranch(-3)
  assertEqualInt(pos, 5, "asyncReturnFromBranch(5) should return 5")
  assertEqualInt(neg, 3, "asyncReturnFromBranch(-3) should return 3")
}

// ── Phase B.1 tests ───────────────────────────────────────────────────────────
test "Phase B.1: two sequential awaits produce correct result" {
  val result = await asyncAddTwo(10)
  assertEqualInt(result, 12, "asyncAddTwo(10) should return 12")
}

test "Phase B.1: asyncAddTwo at zero" {
  val result = await asyncAddTwo(0)
  assertEqualInt(result, 2, "asyncAddTwo(0) should return 2")
}

test "Phase B.1: three sequential awaits produce correct result" {
  val result = await asyncAddThree(7)
  assertEqualInt(result, 10, "asyncAddThree(7) should return 10")
}

test "Phase B.1: three sequential awaits from zero" {
  val result = await asyncAddThree(0)
  assertEqualInt(result, 3, "asyncAddThree(0) should return 3")
}

test "Phase B.1: void async func that awaits non-void completes without error" {
  await asyncVoidChain(5)
  assertTrue(true, "asyncVoidChain completed normally")
}

test "Phase B.1: composition of B.1 and B.0 functions" {
  val a = await asyncAddTwo(0)
  val b = await asyncAddOne(a)
  assertEqualInt(b, 3, "asyncAddTwo(0)=2 then asyncAddOne(2)=3")
}

test "Phase B.1: two B.1 functions composed" {
  val a = await asyncAddTwo(0)
  val b = await asyncAddThree(a)
  assertEqualInt(b, 5, "asyncAddTwo(0)=2 then asyncAddThree(2)=5")
}

test "Phase B.1: asyncSumViaAwait correctness" {
  val result = await asyncSumViaAwait(3, 4)
  assertEqualInt(result, 7, "asyncSumViaAwait(3,4) should return 7")
}

// ── Promoted locals: val-bindings that span await points ─────────────────────
// val x is defined before the await and used after it.
// asyncLocalSurvivesAwait(5): x=10, a=6, result=16
async func asyncLocalSurvivesAwait(n: in Int): Int {
  val x = n * 2
  val a = await asyncAddOne(n)
  x + a
}

// Two locals before two awaits; both must survive both suspensions.
// asyncMultiLocalSurvivesAwaits(5): x=10, y=15, a=6, b=6, result=37
async func asyncMultiLocalSurvivesAwaits(n: in Int): Int {
  val x = n * 2
  val y = n + 10
  val a = await asyncAddOne(n)
  val b = await asyncAddOne(n)
  x + y + a + b
}

// Local defined between two awaits must survive the second suspension.
// asyncLocalBetweenAwaits(5): a=6, x=18, b=6, result=24
async func asyncLocalBetweenAwaits(n: in Int): Int {
  val a = await asyncAddOne(n)
  val x = a * 3
  val b = await asyncAddOne(n)
  x + b
}

// Local defined before three awaits; must survive all three suspensions.
// asyncLocalSurvivesThreeAwaits(5): x=15, a=6, b=6, c=6, result=33
async func asyncLocalSurvivesThreeAwaits(n: in Int): Int {
  val x = n * 3
  val a = await asyncAddOne(n)
  val b = await asyncAddOne(n)
  val c = await asyncAddOne(n)
  x + a + b + c
}

// var bindings in a while loop body with an await: both i and acc must survive
// each suspension so loop state persists across MoveNext re-invocations.
// asyncSumWithLoop(3): iterations 0,1,2; v=1,2,3; acc=1,3,6; result=6
async func asyncSumWithLoop(n: in Int): Int {
  var i = 0
  var acc = 0
  while i < n {
    val v = await asyncAddOne(i)
    acc = acc + v
    i = i + 1
  }
  acc
}

test "promoted locals: val survives one await" {
  val result = await asyncLocalSurvivesAwait(5)
  assertEqualInt(result, 16, "asyncLocalSurvivesAwait(5) should return 16")
}

test "promoted locals: two vals survive two awaits" {
  val result = await asyncMultiLocalSurvivesAwaits(5)
  assertEqualInt(result, 37, "asyncMultiLocalSurvivesAwaits(5) should return 37")
}

test "promoted locals: val defined between awaits survives second await" {
  val result = await asyncLocalBetweenAwaits(5)
  assertEqualInt(result, 24, "asyncLocalBetweenAwaits(5) should return 24")
}

test "promoted locals: val survives three awaits" {
  val result = await asyncLocalSurvivesThreeAwaits(5)
  assertEqualInt(result, 33, "asyncLocalSurvivesThreeAwaits(5) should return 33")
}

test "promoted locals: var bindings in while loop survive across awaits" {
  val result = await asyncSumWithLoop(3)
  assertEqualInt(result, 6, "asyncSumWithLoop(3) should return 6")
}

test "promoted locals: var bindings in while loop with zero iterations" {
  val result = await asyncSumWithLoop(0)
  assertEqualInt(result, 0, "asyncSumWithLoop(0) should return 0")
}

// ── Phase B.3: stack-spill for awaits in expression-position operands ─────────
// When an await appears as a sub-expression of a binary op, any earlier
// operand already computed onto the eval stack must be spilled to a promoted SM
// field local before the `leave` instruction clears the stack at suspension.
// Both operands awaited in an addition (commutative; spill+reload only).
// asyncAddBothAwaited(5): (5+1) + (5+1) = 12
async func asyncAddBothAwaited(n: in Int): Int {
  (await asyncAddOne(n)) + (await asyncAddOne(n))
}

// Both operands awaited in a subtraction (non-commutative; spill + rhs-temp).
// asyncSubBothAwaited(5, 3): (5+1) - (3+1) = 2
async func asyncSubBothAwaited(a: in Int, b: in Int): Int {
  (await asyncAddOne(a)) - (await asyncAddOne(b))
}

// Both operands awaited in a less-than comparison (non-commutative).
// asyncLtBothAwaited(3, 5): (3+1) < (5+1) = true
async func asyncLtBothAwaited(a: in Int, b: in Int): Bool {
  (await asyncAddOne(a)) < (await asyncAddOne(b))
}

// Only the rhs operand awaited (lhs is a literal): tests the spill path where
// lhs has no await but rhs does.
// asyncAddRhsAwaited(5): 10 + (5+1) = 16
async func asyncAddRhsAwaited(n: in Int): Int {
  10 + (await asyncAddOne(n))
}

// String concatenation with both sides awaited (BAdd/MString promotion path).
// asyncStrConcatBothAwaited: "Hello, A!" + "Hello, B!" = "Hello, A!Hello, B!"
async func asyncStrConcatBothAwaited(): String {
  (await asyncGreet("A")) + (await asyncGreet("B"))
}

test "Phase B.3: commutative add with both operands awaited" {
  val result = await asyncAddBothAwaited(5)
  assertEqualInt(result, 12, "asyncAddBothAwaited(5) should return 12")
}

test "Phase B.3: non-commutative sub with both operands awaited" {
  val result = await asyncSubBothAwaited(5, 3)
  assertEqualInt(result, 2, "asyncSubBothAwaited(5,3) should return 2")
}

test "Phase B.3: comparison (lt) with both operands awaited" {
  val lt = await asyncLtBothAwaited(3, 5)
  val gt = await asyncLtBothAwaited(5, 3)
  assertTrue(lt, "asyncLtBothAwaited(3,5) should be true")
  assertTrue(not gt, "asyncLtBothAwaited(5,3) should be false")
}

test "Phase B.3: rhs-only await in add (lhs is literal)" {
  val result = await asyncAddRhsAwaited(5)
  assertEqualInt(result, 16, "asyncAddRhsAwaited(5) should return 16")
}

test "Phase B.3: string concat with both operands awaited" {
  val result = await asyncStrConcatBothAwaited()
  assertEqual(result, "Hello, A!Hello, B!", "asyncStrConcatBothAwaited should return concatenated greetings")
}

// ── Phase 4: spawn semantics ──────────────────────────────────────────────────
// `spawn f(args)` returns Task<T> without awaiting.  The caller can store the
// handle and `await` it later.  In non-SM context (test body), `await handle`
// goes through emitBlockingAwait on the Task<T> local.
// spawn + immediate await in expression position: `await spawn f(args)`
async func asyncSpawnImmediate(n: in Int): Int {
  await spawn asyncAddOne(n)
}

// spawn stored in local, awaited later (requires pre-scan spawnEnv tracking)
async func asyncSpawnAndStore(n: in Int): Int {
  val handle = spawn asyncAddOne(n)
  await handle
}

// Two spawns stored, both awaited (structured-concurrency starter pattern)
async func asyncSpawnTwoAndAdd(a: in Int, b: in Int): Int {
  val h1 = spawn asyncAddOne(a)
  val h2 = spawn asyncAddOne(b)
  val r1 = await h1
  val r2 = await h2
  r1 + r2
}

test "Phase 4: await spawn in expression position" {
  val result = await asyncSpawnImmediate(7)
  assertEqualInt(result, 8, "asyncSpawnImmediate(7) should return 8")
}

test "Phase 4: spawn stored in local then awaited" {
  val result = await asyncSpawnAndStore(4)
  assertEqualInt(result, 5, "asyncSpawnAndStore(4) should return 5")
}

test "Phase 4: two spawns stored then both awaited" {
  val result = await asyncSpawnTwoAndAdd(3, 6)
  assertEqualInt(result, 11, "asyncSpawnTwoAndAdd(3,6): (3+1)+(6+1) = 11")
}

// ── #2292: match with all arms returning ─────────────────────────────────────
// All match arms emit `return`, so the patch rewrites all of them.
// asyncMatchAllReturn(1): all arms return, join point is unreachable dead code.
async func asyncMatchAllReturn(n: in Int): Int {
  match n {
    case 1 -> return 10
    case _ -> return 0
  }
}

test "#2292: match with all arms returning yields the correct arm value" {
  val r1 = await asyncMatchAllReturn(1)
  val r0 = await asyncMatchAllReturn(99)
  assertEqualInt(r1, 10, "asyncMatchAllReturn(1) should return 10")
  assertEqualInt(r0, 0, "asyncMatchAllReturn(99) should return 0")
}

// ── #2292: early return followed by more statements ───────────────────────────
// `return` appears before the end; the trailing `else` branch is the implicit
// fall-off.  The `lastWasPatchedRet` tracking must not skip the trailing coerce
// for the fall-off path.
async func asyncEarlyReturn(n: in Int): Int {
  if n > 0 {
    return n * 10
  }
  n + 1
}

test "#2292: early return followed by fall-off path" {
  val r1 = await asyncEarlyReturn(5)
  val r0 = await asyncEarlyReturn(0)
  assertEqualInt(r1, 50, "asyncEarlyReturn(5) should return 50")
  assertEqualInt(r0, 1, "asyncEarlyReturn(0) should return 1")
}

// ── #2357: BMul / BDiv / BMod with both operands awaited ─────────────────────
// Non-commutative operators: the spill + rhs-temp restore pattern must produce
// the correct result for all operator variants.
async func asyncMulBothAwaited(a: in Int, b: in Int): Int {
  (await asyncAddOne(a)) * (await asyncAddOne(b))
}

async func asyncDivBothAwaited(a: in Int, b: in Int): Int {
  (await asyncAddOne(a)) / (await asyncAddOne(b))
}

async func asyncModBothAwaited(a: in Int, b: in Int): Int {
  (await asyncAddOne(a)) % (await asyncAddOne(b))
}

async func asyncGtBothAwaited(a: in Int, b: in Int): Bool {
  (await asyncAddOne(a)) > (await asyncAddOne(b))
}

async func asyncLteBothAwaited(a: in Int, b: in Int): Bool {
  (await asyncAddOne(a)) <= (await asyncAddOne(b))
}

async func asyncGteBothAwaited(a: in Int, b: in Int): Bool {
  (await asyncAddOne(a)) >= (await asyncAddOne(b))
}

test "Phase B.3: mul with both operands awaited" {
  val result = await asyncMulBothAwaited(3, 4)
  assertEqualInt(result, 20, "asyncMulBothAwaited(3,4): 4*5 = 20")
}

test "Phase B.3: div with both operands awaited (non-commutative)" {
  val result = await asyncDivBothAwaited(9, 4)
  assertEqualInt(result, 2, "asyncDivBothAwaited(9,4): 10/5 = 2")
}

test "Phase B.3: mod with both operands awaited (non-commutative)" {
  val result = await asyncModBothAwaited(9, 4)
  assertEqualInt(result, 0, "asyncModBothAwaited(9,4): 10%5 = 0")
}

test "Phase B.3: gt comparison with both operands awaited (non-commutative)" {
  val gt = await asyncGtBothAwaited(5, 3)
  val lt = await asyncGtBothAwaited(3, 5)
  assertTrue(gt, "asyncGtBothAwaited(5,3): 6>4 = true")
  assertTrue(not lt, "asyncGtBothAwaited(3,5): 4>6 = false")
}

test "Phase B.3: lte comparison with both operands awaited (non-commutative)" {
  val lte = await asyncLteBothAwaited(3, 5)
  val notlte = await asyncLteBothAwaited(5, 3)
  assertTrue(lte, "asyncLteBothAwaited(3,5): 4<=6 = true")
  assertTrue(not notlte, "asyncLteBothAwaited(5,3): 6<=4 = false")
}

test "Phase B.3: gte comparison with both operands awaited (non-commutative)" {
  val gte = await asyncGteBothAwaited(5, 3)
  val eq = await asyncGteBothAwaited(4, 4)
  val notgte = await asyncGteBothAwaited(3, 5)
  assertTrue(gte, "asyncGteBothAwaited(5,3): 6>=4 = true")
  assertTrue(eq, "asyncGteBothAwaited(4,4): 5>=5 = true")
  assertTrue(not notgte, "asyncGteBothAwaited(3,5): 4>=6 = false")
}

// ── #2367: SFor — await inside a for-in loop body ────────────────────────────
// Exercises the SFor arm added to `collectAwaitTypesStmtPB` so that the
// loop-variable promoted-local pre-scan includes awaits inside for-in bodies.
async func asyncForSum(xs: in List[Int]): Int {
  var total = 0
  for x in xs {
    val v = await asyncAddOne(x)
    total = total + v
  }
  total
}

test "#2367: SFor: await inside for-in loop body accumulates correctly" {
  val xs: List[Int] = newList()
  xs.add(1)
  xs.add(2)
  xs.add(3)
  val result = await asyncForSum(xs)
  assertEqualInt(result, 9, "sum of (x+1) for x in [1,2,3] = (2+3+4) = 9")
}

// ── #2367: SAssign — await on the RHS of an assignment ──────────────────────
// Exercises the SAssign arm added to `collectAwaitTypesStmtPB` so that a
// `var x = 0; x = await f()` pattern is correctly type-collected.
async func asyncAssignAwait(n: in Int): Int {
  var result = 0
  result = await asyncAddOne(n)
  result
}

test "#2367: SAssign: await on RHS of var reassignment" {
  val result = await asyncAssignAwait(7)
  assertEqualInt(result, 8, "asyncAssignAwait(7): var=0 then var=await(7+1) = 8")
}

// ── #2289: `return` inside a protected region (try/catch/finally) in a
// no-await async func.  SReturn inside a try region stores into retvalSlot and
// `leave`s to the SM epilogue; that slot must be the same one the epilogue
// reads for SetResult (it formerly defaulted to an MVoid `__retval`, losing the
// value and emitting invalid IL).
async func asyncTryReturn(): Int {
  try {
    return 42
  } catch Bug as _ {
    return 0
  }
}

async func asyncTryCatchReturn(x: in Int): Int {
  try {
    if x > 0 {
      panic("boom")
    }
    return 1
  } catch Bug as _ {
    return 99
  }
}

async func asyncTryFinallyReturn(): Int {
  try {
    return 5
  } finally {
    val _ = 0
  }
}

// Mixes a protected-region return (try body) with a fall-through trailing value
// after the try/catch — exercises both the retvalSlot leave path and the
// trailing-stash path in one function.
async func asyncTryTrailing(x: in Int): Int {
  try {
    if x > 0 {
      return 10
    }
  } catch Bug as _ {
    return 0
  }
  20
}

// #2736: await is OUTSIDE the try; the return is INSIDE the try.  This routes
// through the await-bearing Phase B.1 MoveNext (not the no-await Phase A path),
// which must still stash the protected-region return into retvalSlot so the
// epilogue's SetResult reads the right value.
async func asyncAwaitThenTryReturn(n: in Int): Int {
  val y = await asyncAddOne(n)
  try {
    return y
  } catch Bug as _ {
    return 0
  }
}

// Phase B variant where the try body panics so the catch-handler return is the
// live path after a preceding await.
async func asyncAwaitThenTryCatch(x: in Int): Int {
  val y = await asyncAddOne(x)
  try {
    if y > 1 {
      panic("boom")
    }
    return y
  } catch Bug as _ {
    return 99
  }
}

test "#2289: return inside try body in no-await async func" {
  val result = await asyncTryReturn()
  assertEqualInt(result, 42, "asyncTryReturn: try-body return reaches SetResult")
}

test "#2289: return inside catch handler in no-await async func" {
  assertEqualInt(await asyncTryCatchReturn(0), 1, "asyncTryCatchReturn(0): try body returns 1")
  assertEqualInt(await asyncTryCatchReturn(1), 99, "asyncTryCatchReturn(1): catch handler returns 99")
}

test "#2289: return inside try with finally in no-await async func" {
  val result = await asyncTryFinallyReturn()
  assertEqualInt(result, 5, "asyncTryFinallyReturn: finally runs, value 5 preserved")
}

test "#2289: protected-region return plus trailing fall-through value" {
  assertEqualInt(await asyncTryTrailing(1), 10, "asyncTryTrailing(1): try-region return = 10")
  assertEqualInt(await asyncTryTrailing(0), 20, "asyncTryTrailing(0): fall-through trailing value = 20")
}

test "#2736: await outside try, return inside try (Phase B)" {
  assertEqualInt(await asyncAwaitThenTryReturn(41), 42, "Phase B: await-outside + try-body return = 42")
}

test "#2736: await outside try, return from catch after panic (Phase B)" {
  assertEqualInt(await asyncAwaitThenTryCatch(0), 1, "Phase B: await then try-body return = 1")
  assertEqualInt(await asyncAwaitThenTryCatch(5), 99, "Phase B: await then catch-handler return = 99")
}

// ── #4187: SM FieldDef ordering — async func before record ───────────────────
// Regression: addPackageTokens post-Pass-2 SM field-count loop placed all SM
// FieldDef rows AFTER regular-type FieldDef rows, but lowerMPackageWithCtx
// emits TypeDefs in source order (SM classes interleaved with records).  Any
// IRecord defined AFTER an async func in source order received wrong
// cctx.fieldTokens entries → ilverify TokenResolve errors + runtime crashes.

async func smBeforeRecordHelper(n: in Int): Int {
  n + 10
}

record RecordAfterSm {
  x: Int
  y: Int
}

async func smAfterRecord(n: in Int): Int {
  n * 2
}

record SecondRecordAfterSm {
  a: Int
  b: String
}

test "#4187: record field access after SM class in source order" {
  val r = RecordAfterSm(x = 3, y = 7)
  assertEqualInt(r.x, 3, "RecordAfterSm.x = 3")
  assertEqualInt(r.y, 7, "RecordAfterSm.y = 7")
}

test "#4187: second record field access after two SM classes" {
  val s = SecondRecordAfterSm(a = 42, b = "hello")
  assertEqualInt(s.a, 42, "SecondRecordAfterSm.a = 42")
  assertEqual(s.b, "hello", "SecondRecordAfterSm.b = hello")
}

test "#4187: async func between records: record fields remain correct" {
  val r = RecordAfterSm(x = 100, y = 200)
  val s = SecondRecordAfterSm(a = r.x + r.y, b = "sum")
  assertEqualInt(s.a, 300, "sum of RecordAfterSm fields = 300")
  assertEqual(s.b, "sum", "SecondRecordAfterSm.b = sum")
}

test "#4187: SM function between records executes correctly" {
  val result = await smAfterRecord(5)
  assertEqualInt(result, 10, "smAfterRecord(5) = 10")
}

// ── #4266: SM function returning a local enum / distinct type ─────────────────
union Direction {
  case North
  case South
  case East
  case West
}

async func asyncGetDirection(n: in Int): Direction {
  if n == 0 { North } else if n == 1 { South } else if n == 2 { East } else { West }
}

async func asyncDirectionRoundTrip(n: in Int): Direction {
  val d = await asyncGetDirection(n)
  d
}

alias Distance = Int

async func asyncGetDistance(n: in Int): Distance {
  n * 100
}

async func asyncDoubleDistance(n: in Int): Distance {
  val d = await asyncGetDistance(n)
  d * 2
}

union SmallInt {
  case Zero
  case One
  case Two
  case Many
}

async func asyncToSmallInt(n: in Int): SmallInt {
  match n {
    case 0 -> Zero
    case 1 -> One
    case 2 -> Two
    case _ -> Many
  }
}

test "#4266: SM func returning local union type (no await)" {
  val d = await asyncGetDirection(0)
  assertTrue(match d { case North -> true; case _ -> false }, "asyncGetDirection(0) = North")
  val d2 = await asyncGetDirection(3)
  assertTrue(match d2 { case West -> true; case _ -> false }, "asyncGetDirection(3) = West")
}

test "#4266: SM func returning local union type (with await)" {
  val d = await asyncDirectionRoundTrip(1)
  assertTrue(match d { case South -> true; case _ -> false }, "asyncDirectionRoundTrip(1) = South")
  val d2 = await asyncDirectionRoundTrip(2)
  assertTrue(match d2 { case East -> true; case _ -> false }, "asyncDirectionRoundTrip(2) = East")
}

test "#4266: SM func returning local alias type (no await)" {
  val dist = await asyncGetDistance(3)
  assertEqualInt(dist, 300, "asyncGetDistance(3) = 300")
}

test "#4266: SM func returning local alias type (with await)" {
  val dist = await asyncDoubleDistance(4)
  assertEqualInt(dist, 800, "asyncDoubleDistance(4): 4*100*2 = 800")
}

test "#4266: SM func returning local union type: match all arms" {
  val z = await asyncToSmallInt(0)
  val o = await asyncToSmallInt(1)
  val tw = await asyncToSmallInt(2)
  val m = await asyncToSmallInt(99)
  assertTrue(match z { case Zero -> true; case _ -> false }, "asyncToSmallInt(0) = Zero")
  assertTrue(match o { case One -> true; case _ -> false }, "asyncToSmallInt(1) = One")
  assertTrue(match tw { case Two -> true; case _ -> false }, "asyncToSmallInt(2) = Two")
  assertTrue(match m { case Many -> true; case _ -> false }, "asyncToSmallInt(99) = Many")
}
