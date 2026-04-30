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

        testCase "[derives Add]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivAdd" """
package DerivAdd

type Cents = Long range 0 ..= 1000000 derives Add, Sub

func main(): Unit {
  val a = Cents.from(150)
  val b = Cents.from(75)
  val c = a + b
  println(c.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "225" "derives Add"

        testCase "[derives Sub]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivSub" """
package DerivSub

type Cents = Long range 0 ..= 1000000 derives Add, Sub

func main(): Unit {
  val a = Cents.from(500)
  val b = Cents.from(125)
  val c = a - b
  println(c.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "375" "derives Sub"

        testCase "[derives Compare]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivCmp" """
package DerivCmp

type Score = Int range 0 ..= 100 derives Compare

func main(): Unit {
  val a = Score.from(40)
  val b = Score.from(70)
  println(a < b)
  println(a > b)
  println(a == b)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "True\nFalse\nFalse" "derives Compare"

        testCase "[derives Add chained]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivChain" """
package DerivChain

type Cents = Long range 0 ..= 1000000 derives Add, Sub

func main(): Unit {
  val total = Cents.from(100) + Cents.from(50) + Cents.from(25)
  println(total.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "175" "chained derives Add"

        testCase "[derives Equals]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivEq" """
package DerivEq

type UserId = Int derives Equals

func main(): Unit {
  val a = UserId.from(7)
  val b = UserId.from(7)
  val c = UserId.from(8)
  println(a.equals(b))
  println(a.equals(c))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "True\nFalse" "derives Equals"

        testCase "[derives Hash]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivHash" """
package DerivHash

type UserId = Int derives Hash

func main(): Unit {
  val a = UserId.from(42)
  val b = UserId.from(42)
  println(a.hash() == b.hash())
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "True" "derives Hash"

        testCase "[derives Default]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DerivDef" """
package DerivDef

type Counter = Int derives Default

func main(): Unit {
  val c = Counter.default()
  println(c.value)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "0" "derives Default"

        testCase "[inherent toInt]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ToIntA" """
package ToIntA

type UserId = Int

func main(): Unit {
  val u = UserId.from(123)
  println(u.toInt())
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "123" "toInt projection"

        testCase "[inherent toLong]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ToLongA" """
package ToLongA

type Cents = Long range 0 ..= 1000000

func main(): Unit {
  val c = Cents.from(5000)
  println(c.toLong())
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "5000" "toLong projection"

        // ---- tryFrom returning Result[Self, String] -------------------

        testCase "[range subtype tryFrom Ok branch]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "TryFromOk" """
package TryFromOk
import Std.Core

type Score = Int range 0 ..= 100

func main(): Unit {
  val r = Score.tryFrom(42)
  match r {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(-1)
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "42" "tryFrom Ok"

        testCase "[range subtype tryFrom Err branch]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "TryFromErr" """
package TryFromErr
import Std.Core

type Score = Int range 0 ..= 100

func main(): Unit {
  val r = Score.tryFrom(150)
  match r {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(e)
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.stringContains
                (stdout.TrimEnd()) "out of range" "tryFrom Err carries message"

        testCase "[range subtype tryFrom boundary inclusive]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "TryFromBoundary" """
package TryFromBoundary
import Std.Core

type Score = Int range 0 ..= 100

func main(): Unit {
  match Score.tryFrom(0) {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(-1)
  }
  match Score.tryFrom(100) {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(-1)
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "0\n100" "boundary values are Ok"

        testCase "[range subtype tryFrom half-open excludes upper]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "TryFromHalfOpen" """
package TryFromHalfOpen
import Std.Core

type Bucket = Int range 0 ..< 10

func main(): Unit {
  match Bucket.tryFrom(9) {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(-1)
  }
  match Bucket.tryFrom(10) {
    case Ok(v)  -> println(v.value)
    case Err(e) -> println(-1)
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "9\n-1" "9 in, 10 excluded"

        testCase "[range subtype on Long has tryFrom too]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "TryFromLong" """
package TryFromLong
import Std.Core

type Cents = Long range 0 ..= 1_000_000

func main(): Unit {
  match Cents.tryFrom(5000) {
    case Ok(c)  -> println(c.value)
    case Err(e) -> println(-1)
  }
  match Cents.tryFrom(2_000_000) {
    case Ok(c)  -> println(c.value)
    case Err(e) -> println(-1)
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "5000\n-1" "tryFrom on Long"
    ]
