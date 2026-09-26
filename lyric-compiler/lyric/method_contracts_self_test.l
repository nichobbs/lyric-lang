//! method_contracts_self_test.l — runtime regression test for contracts on
//! record-body methods, `impl` methods, and interface methods (#7223).
//!
//! Before the fix, `Lyric.ContractElaborator` only elaborated top-level
//! `IFunc` items: `requires:` / `ensures:` on a method declared inside a
//! `record { }` body or an `impl` block were parsed and silently dropped, and
//! the clauses an interface declares on its methods were never applied to the
//! implementations.  The elaborator now lowers record-body and impl methods
//! like any other function and conjoins each interface method's clauses
//! (renamed positionally into the implementing method's parameter names) with
//! the impl's own.
//!
//! The last two cases pin the violation message (#7225): each synthesized
//! assert names the violation kind, the owning function and the clause as
//! written, instead of a bare "assertion failed".
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/method_contracts_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/method_contracts_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.MethodContractsSelfTest

import Std.Core
import Std.Testing

record Box {
  v: Int
  func scaled(self: in Box, k: in Int): Int
    requires: k > 0
    ensures: result == self.v * k
  {
    self.v * k
  }
}

interface Shape {
  func area(self: in Self, scale: in Int): Int
    requires: scale > 0
    ensures: result >= 0

  func label(self: in Self, prefix: in String): String
    requires: prefix.length > 0
}

record Square {
  side: Int
}

// Renames the interface's `scale` parameter to `s`: the inherited clause must
// follow the rename.
impl Shape for Square {
  func area(self: in Square, s: in Int): Int {
    self.side * self.side * s
  }

  func label(self: in Square, prefix: in String): String
    requires: prefix.length < 10
  {
    prefix + "square"
  }
}

record Broken {
  n: Int
}

// Violates the interface's inherited `ensures: result >= 0`.
impl Shape for Broken {
  func area(self: in Broken, scale: in Int): Int {
    0 - self.n * scale
  }

  func label(self: in Broken, prefix: in String): String {
    prefix
  }
}

func areaOf(sh: in Shape, scale: in Int): Int {
  sh.area(scale)
}

test "record method: satisfied requires/ensures returns the value" {
  val b = Box(v = 3)
  assertEqualInt(b.scaled(4), 12, "scaled(4) on v = 3")
}

test "record method: violated requires is enforced" {
  assertPanics("k = 0 violates requires: k > 0", { -> val _ = Box(v = 3).scaled(0) })
}

test "impl method: inherited requires is enforced under a renamed parameter" {
  assertEqualInt(Square(side = 2).area(3), 12, "area(3) on side 2")
  assertPanics("scale -1 violates the interface's requires", { -> val _ = Square(side = 2).area(-1) })
}

test "impl method: inherited requires is enforced through an interface-typed value" {
  assertEqualInt(areaOf(Square(side = 2), 1), 4, "dispatch through Shape")
  assertPanics("scale 0 through Shape violates requires", { -> val _ = areaOf(Square(side = 2), 0) })
}

test "impl method: inherited ensures is enforced" {
  assertPanics("negative area violates ensures: result >= 0", { -> val _ = Broken(n = 5).area(1) })
}

test "impl method: own and inherited requires are both enforced" {
  assertEqual(Square(side = 1).label("big "), "big square", "label with a valid prefix")
  assertPanics("empty prefix violates the interface's requires", { -> val _ = Square(side = 1).label("") })
  assertPanics("long prefix violates the impl's own requires", { -> val _ = Square(side = 1).label("far too long ") })
}

// Violation messages name the kind, the owning function and the clause (#7225).
test "violation message: precondition names the owner and the clause" {
  assertPanicsWith(
    "record method precondition message",
    "PreconditionViolated: Lyric.MethodContractsSelfTest.Box.scaled requires k > 0",
    { -> val _ = Box(v = 3).scaled(0) }
  )
}

test "violation message: inherited postcondition names the implementing method" {
  assertPanicsWith(
    "inherited postcondition message",
    "PostconditionViolated: Lyric.MethodContractsSelfTest.Broken.area ensures result >= 0",
    { -> val _ = Broken(n = 5).area(1) }
  )
}

// An interface default method carrying a contract, inherited un-overridden:
// `Lyric.ImplDefaults` copies it into the impl clauses and all, and the
// elaborator must not assert the same clause a second time (#7291).
record Tally {
  var n: Int
}

val evaluations: Tally = Tally(n = 0)

// Deliberately impure: it counts how many times the clause below is
// evaluated.  `@pure` is a declaration the compiler trusts, not a property
// it verifies, so the clause may call it (T0133, #7228).
@pure
func counted(ok: in Bool): Bool {
  evaluations.n = evaluations.n + 1
  ok
}

interface Greeter {
  func greet(self: in Self, name: in String): String
    requires: counted(name.length > 0)
  {
    "hello " + name
  }
}

record Plain {
  tag: Int
}

impl Greeter for Plain {
}

test "inherited default method: its precondition is evaluated exactly once per call" {
  val before = evaluations.n
  assertEqual(Plain(tag = 1).greet("ann"), "hello ann", "default method result")
  assertEqualInt(evaluations.n - before, 1, "one evaluation of the inherited requires")
  assertPanics("empty name violates the default method's requires", { -> val _ = Plain(tag = 1).greet("") })
}
