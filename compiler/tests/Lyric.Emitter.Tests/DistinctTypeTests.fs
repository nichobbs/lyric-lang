/// Tests for M2.1: distinct types and range subtypes.
///
/// `type Foo = Int` lowers to a CLR value type (struct) with a single
/// `Value` field. `type Score = Int range 0..=100` adds a bounds check
/// inside the static `From(x)` factory.  The test programs use
/// `TypeName.from(x)` for construction and `.value` for projection.
module Lyric.Emitter.Tests.DistinctTypeTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testSequenced
    <| testList "distinct types (M2.1)" [

        testCase "[distinct type round-trip]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DistA" """
package DistA

type UserId = Int

func makeId(n: in Int): UserId {
  UserId.from(n)
}

func getId(id: in UserId): Int {
  id.value
}

func main(): Unit {
  val id = makeId(42)
  println(getId(id))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "42" "distinct type round-trip"

        testCase "[distinct type Long]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DistB" """
package DistB

type OrderId = Long

func main(): Unit {
  val id = OrderId.from(99)
  println(id.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "99" "Long distinct type"

        testCase "[range subtype in-range succeeds]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "RangeA" """
package RangeA

type Score = Int range 0 ..= 100

func main(): Unit {
  val s = Score.from(75)
  println(s.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "75" "in-range construction"

        testCase "[range subtype boundary values]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "RangeB" """
package RangeB

type Score = Int range 0 ..= 100

func main(): Unit {
  val lo = Score.from(0)
  val hi = Score.from(100)
  println(lo.value)
  println(hi.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "0\n100" "boundary values"

        testCase "[range subtype out-of-range panics]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "RangeC" """
package RangeC

type Score = Int range 0 ..= 100

func main(): Unit {
  val s = Score.from(200)
  println(s.value)
}
"""
            Expect.notEqual exitCode 0 (sprintf "non-zero exit on range violation (stderr=%s)" stderr)

        testCase "[distinct type in function parameter]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DistC" """
package DistC

type AccountId = Long

func describe(id: in AccountId): Unit {
  println(id.value)
}

func main(): Unit {
  val id = AccountId.from(12345)
  describe(id)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "12345" "distinct in param"
    ]
