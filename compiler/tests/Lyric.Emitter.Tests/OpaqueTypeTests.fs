/// Tests for M2.2: opaque types and `@projectable`.
///
/// Bootstrap-grade lowering: an opaque type with a body lowers to a
/// sealed CLR class (the same shape used for records).  Visibility is
/// not enforced because we still compile a single package; the
/// boundary check arrives once cross-package compilation lands.
///
/// `@projectable` synthesises a sibling exposed record `<Name>View`
/// containing every non-`@hidden` field plus an instance method
/// `toView(): <Name>View` on the opaque type.
module Lyric.Emitter.Tests.OpaqueTypeTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testSequenced
    <| testList "opaque types (M2.2)" [

        testCase "[opaque type round-trip]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "OpaqA" """
package OpaqA

opaque type Account {
  balance: Long
  id: Long
}

func balanceOf(a: in Account): Long {
  a.balance
}

func main(): Unit {
  val acct = Account(balance = 1000, id = 42)
  println(balanceOf(acct))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "1000" "opaque round-trip"

        testCase "[opaque field reads]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "OpaqB" """
package OpaqB

opaque type Point {
  x: Int
  y: Int
}

func main(): Unit {
  val p = Point(x = 3, y = 4)
  println(p.x)
  println(p.y)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "3\n4" "opaque fields"

        testCase "[@projectable generates view]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjA" """
package ProjA

opaque type User @projectable {
  id: Int
  age: Int
}

func main(): Unit {
  val u = User(id = 7, age = 30)
  val v = u.toView()
  println(v.id)
  println(v.age)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "7\n30" "@projectable view"

        testCase "[@projectable hides @hidden fields]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjB" """
package ProjB

opaque type User @projectable {
  id: Int
  passwordHash: Int @hidden
}

func main(): Unit {
  val u = User(id = 5, passwordHash = 999)
  val v = u.toView()
  println(v.id)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "5" "@hidden field excluded"
    ]
