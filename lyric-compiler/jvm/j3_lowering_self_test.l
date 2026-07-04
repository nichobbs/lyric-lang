//! j3_lowering_self_test.l — J3 (docs/44 §5) regression test: codegen dispatch
//! for the lowering capabilities that already existed in `jvm/lowering.l` but
//! were unreachable, plus `defer` and module-level `val` (#2666, epic #2663).
//!
//! Covers, asserting every runtime value on `--target jvm`:
//!   - M-3 opaque   : `Counter(value = …)` construction + `$value()`-accessor
//!                    field read round-trip (dispatch → `lowerOpaqueType`).
//!   - M-3 protected: record-shaped class with field-args ctor + lock-wrapped
//!                    instance entries; bare-name field reads/writes resolve
//!                    through `selfClass`, entry calls resolve precisely.
//!   - M-3 wire     : `AppWire.bootstrap()` runs the DI bindings;
//!                    `AppWire.svc()` returns the exposed singleton; a
//!                    multi-field constructor referencing an earlier binding
//!                    from a nested (non-top-level) expression position,
//!                    bootstrapped via a `@provided` param (#5013/#5015/#5020).
//!   - M-2 defer    : the deferred block runs on a normal fall-off AND on an
//!                    early `return`, on every path, without clobbering the
//!                    captured return value.
//!   - m-2 module-`val`: a module-level `val` is a `static final` field read via
//!                    `getstatic` from any function in the package.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`) and
//! runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.J3LoweringSelfTest

import Std.Core
import Std.Testing

// ── m-2: module-level val ─────────────────────────────────────────────────────
val theAnswer: Int = 42

val greeting: String = "hello"

// #2853: an *unannotated* module `val` whose init is a function call.  Before the
// fix, `collectFileVals` typed it `java/lang/Object` (D-guess) while the emitted
// field carried the call's real return type (`I`), so a bare read's `getstatic`
// descriptor mismatched the field and class load failed with `NoSuchFieldError`.
func computeAnswer(): Int {
  return 6 * 7
}

val derivedAnswer = computeAnswer()

// #2853: an *unannotated* module `val` whose init is a non-literal returning a
// record.  Same descriptor-mismatch failure mode (`Object` guess vs the real
// `LJvm/J3LoweringSelfTest/Gadget;` field) before the fix.
record Gadget {
  weight: Int
}

func makeGadget(): Gadget {
  return Gadget(weight = 99)
}

val theGadget = makeGadget()

// #2853: an *unannotated* F32 module `val`.  `inferValType` typed every float
// literal `JDouble` (`D`), but `1.5f32` lowers to `JFloat` (`F`) — the field is
// `F`, so a bare `getstatic …:D` read mismatched and failed class load.
val unitScale = 1.5f32

// ── M-3: opaque type ──────────────────────────────────────────────────────────
opaque type Amount {
  cents: Int
}

func amountCents(a: in Amount): Int {
  return a.cents
}

// ── M-3: protected type ───────────────────────────────────────────────────────
protected type Counter {
  var count: Int
  entry increment() {
    count = count + 1
  }
  entry add(n: in Int) {
    count = count + n
  }
  entry get(): Int {
    return count
  }
}

// ── M-3: wire block ───────────────────────────────────────────────────────────
record Widget {
  size: Int
}

wire WidgetWire {
  singleton widget: Widget = Widget(size = 17)
  expose widget
}

// #5013/#5015/#5020: a wire binding whose constructor (a) has 2+ fields (so
// bootstrap()'s max_stack must exceed the old hardcoded `3`, #5015), (b)
// references an *earlier* binding from a *nested* expression position rather
// than as the bare top-level init (#5013 — `contents = widget`, not
// `contents: Widget = widget`), and (c) is bootstrapped via a `@provided`
// param whose registered call-site descriptor previously always claimed zero
// args regardless of `@provided` members (#5020).
record Box {
  label: String
  contents: Widget
}

wire BoxWire {
  @provided prefix: String
  singleton widget: Widget = Widget(size = 17)
  singleton box: Box = Box(label = prefix, contents = widget)
  expose widget
  expose box
}

// ── M-2: defer ────────────────────────────────────────────────────────────────
// Returns the value captured at the (early or normal) return point; the deferred
// block bumps the observer counter on whichever exit path is taken (it must run
// exactly once and must not change the already-captured return value).
func deferReturns(early: in Bool, obs: in Counter): Int {
  var x = 1
  defer {
    obs.increment()
  }
  x = x + 1
  if early {
    return x
  }
  x = x + 10
  return x
}

// #2852: a `defer` inside a loop body must replay on the `break` iteration too.
// `obs` is bumped once per iteration via the in-loop defer; the loop `break`s
// once `i` reaches `stopAt`, so the deferred block must run `stopAt + 1` times
// (iterations 0..stopAt inclusive, the last ending in the break).  Validates the
// `SBreak` replay path and `loopDeferDepth` push/pop.
func deferBreaks(stopAt: in Int, obs: in Counter): Unit {
  var i = 0
  while i < 100 {
    defer {
      obs.increment()
    }
    if i == stopAt {
      break
    }
    i = i + 1
  }
}

// #2852: a `defer` inside a loop body must replay on every `continue` iteration.
// The loop runs `iters` times; on even `i` it `continue`s before the tail, on odd
// `i` it falls off the body — either way the in-loop defer bumps `obs` once per
// iteration.  Validates the `SContinue` replay path and `loopDeferDepth` push/pop.
func deferContinues(iters: in Int, obs: in Counter): Unit {
  var i = 0
  while i < iters {
    defer {
      obs.increment()
    }
    i = i + 1
    if (i - 1) % 2 == 0 {
      continue
    }
  }
}

// #2854: `for`/`do` `break`/`continue` now replay pending defers.
// #2858: `do {}` with `break`/`return` no longer panics codegen (pre-fix the
// `ELambda` panic fired because `lowerLambda` was absent; J2b closures fixed it).
// Also pins that `for` over a List (Iterable path) counts correctly (#2858
// array-for path; full typed-element support requires J4 generic unboxing).
func countListElems(xs: in List[Int]): Int {
  var n = 0
  for _ in xs {
    n = n + 1
  }
  return n
}

func countToN(n: in Int): Int {
  var i = 0
  do {
    if i >= n {
      break
    }
    i = i + 1
  }
  return i
}

func countUpReturn(limit: in Int): Int {
  var i = 0
  do {
    if i >= limit {
      return i
    }
    i = i + 1
  }
  return i
}

// #2856: a generator body that reads a module-`val` must resolve it (real
// `getstatic`), not silently lower to `null`.  Before the fix the generator ctx
// carried an empty `moduleVals`, so `theAnswer` resolved to `LAconstNull` (and
// `runBody` failed to even verify — "Expecting to find integer on stack").  The
// assertion runs *inside* the `for` body: a typed local escaping a
// `for`-over-generator loop hits a separate, pre-existing slot-type VerifyError
// (tracked under docs/44 J-loops; not this fix), so the test consumes `v` only
// as an Object here.  `obs` records that the body ran for each yield.
async func answersGen(n: Int): Int {
  var i = 0
  while i < n {
    yield theAnswer
    i = i + 1
  }
}

func consumeAnswers(n: in Int, obs: in Counter): Unit {
  for v in answersGen(n) {
    assertEqual(toString(v), "42", "generator yielded the module val, not null")
    obs.increment()
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "module-level val is read via getstatic" {
  assertEqualInt(theAnswer, 42, "theAnswer")
  assertEqual(greeting, "hello", "greeting")
}

test "unannotated non-literal module val (call) loads and reads (#2853)" {
  assertEqualInt(derivedAnswer, 42, "derivedAnswer = computeAnswer()")
}

test "unannotated non-literal module val (record) loads and reads (#2853)" {
  assertEqualInt(theGadget.weight, 99, "theGadget.weight")
}

test "unannotated F32 module val loads with the F descriptor (#2853)" {
  assertTrue(unitScale == 1.5f32, "unitScale == 1.5f32")
}

test "opaque type round-trips construction and field read" {
  val a = Amount(cents = 250)
  assertEqualInt(a.cents, 250, "direct field read")
  assertEqualInt(amountCents(a), 250, "field read via accessor function")
}

test "protected type entries mutate and read state" {
  val c = Counter(count = 0)
  c.increment()
  c.increment()
  c.increment()
  assertEqualInt(c.get(), 3, "three increments")
  c.add(10)
  assertEqualInt(c.get(), 13, "add 10")
}

test "wire block resolves the exposed singleton" {
  WidgetWire.bootstrap()
  val w = WidgetWire.widget()
  assertEqualInt(w.size, 17, "exposed widget size")
}

test "wire block: @provided bootstrap arg + nested cross-binding reference + multi-field constructor (#5013/#5015/#5020)" {
  BoxWire.bootstrap("hi")
  val w = BoxWire.widget()
  val b = BoxWire.box()
  assertEqualInt(w.size, 17, "widget singleton unaffected by the sibling binding")
  assertEqual(b.label, "hi", "@provided param reaches a nested binding's constructor argument")
  assertEqualInt(
    b.contents.size,
    17,
    "earlier binding referenced from a nested constructor-argument position resolves via getstatic, not null"
  )
}

test "defer runs on a normal fall-off exit" {
  val obs = Counter(count = 0)
  val r = deferReturns(false, obs)
  assertEqualInt(r, 12, "normal-path return value (1+1+10)")
  assertEqualInt(obs.get(), 1, "deferred block ran once on fall-off")
}

test "defer runs on an early return exit" {
  val obs = Counter(count = 0)
  val r = deferReturns(true, obs)
  assertEqualInt(r, 2, "early-return value (1+1)")
  assertEqualInt(obs.get(), 1, "deferred block ran once on early return")
}

test "defer in loop replays on the break iteration (#2852)" {
  val obs = Counter(count = 0)
  deferBreaks(3, obs)
  assertEqualInt(obs.get(), 4, "defer ran on iterations 0..3 incl. the break")
}

test "defer in loop replays on every continue iteration (#2852)" {
  val obs = Counter(count = 0)
  deferContinues(5, obs)
  assertEqualInt(obs.get(), 5, "defer ran once per iteration incl. continue paths")
}

test "generator body reads a module val, not null (#2856)" {
  val obs = Counter(count = 0)
  consumeAnswers(3, obs)
  assertEqualInt(obs.get(), 3, "generator yielded 3 times, each value == theAnswer")
}

test "for-over-List iterates each element correctly (#2858)" {
  assertEqualInt(countListElems([1, 2, 3, 4, 5]), 5, "count 5 elems via for-over-List")
  assertEqualInt(countListElems([10, 20, 30]), 3, "count 3 elems via for-over-List")
}

test "do-loop with break exits at the right iteration (#2858)" {
  assertEqualInt(countToN(5), 5, "do-loop breaks when i reaches 5")
  assertEqualInt(countToN(0), 0, "do-loop breaks immediately when limit is 0")
}

test "do-loop with return exits at the right iteration (#2858)" {
  assertEqualInt(countUpReturn(3), 3, "do-loop returns when i reaches 3")
}
