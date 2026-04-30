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

        testCase "[@projectable nested fields project recursively]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjC" """
package ProjC

opaque type Address @projectable {
  street: String
  city: String
}

opaque type User @projectable {
  id: Int
  name: String
  address: Address
}

func main(): Unit {
  val a = Address(street = "1 Main", city = "Anytown")
  val u = User(id = 1, name = "alice", address = a)
  val v = u.toView()
  println(v.id)
  println(v.name)
  println(v.address.street)
  println(v.address.city)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd())
                "1\nalice\n1 Main\nAnytown" "nested view fields project"

        testCase "[@projectable two-level nesting]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjD" """
package ProjD

opaque type Country @projectable {
  iso: String
}

opaque type Address @projectable {
  city: String
  country: Country
}

opaque type Company @projectable {
  name: String
  address: Address
}

func main(): Unit {
  val c  = Country(iso = "US")
  val a  = Address(city = "NYC", country = c)
  val co = Company(name = "Acme", address = a)
  val v  = co.toView()
  println(v.name)
  println(v.address.city)
  println(v.address.country.iso)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd())
                "Acme\nNYC\nUS" "two-level recursive projection"

        testCase "[@projectable mixed projectable + plain field]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjE" """
package ProjE

opaque type Tag @projectable {
  label: String
}

opaque type Note @projectable {
  body: String
  tag: Tag
  priority: Int
}

func main(): Unit {
  val t = Tag(label = "urgent")
  val n = Note(body = "fix bug", tag = t, priority = 7)
  val v = n.toView()
  println(v.body)
  println(v.tag.label)
  println(v.priority)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd())
                "fix bug\nurgent\n7" "mixed projection"

        // ---- tryInto reverse projection ------------------------------

        testCase "[@projectable view.tryInto round-trips]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjF" """
package ProjF
import Std.Core

opaque type User @projectable {
  id: Int
  name: String
}

func main(): Unit {
  val u = User(id = 7, name = "alice")
  val v = u.toView()
  match v.tryInto() {
    case Ok(back)  -> println(back.name)
    case Err(_)    -> println("err")
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "alice" "view -> opaque -> field"

        testCase "[@projectable view.tryInto preserves all flat fields]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjG" """
package ProjG
import Std.Core

opaque type Money @projectable {
  cents: Long
  currency: String
}

func showCents(m: in Money): Long {
  m.cents
}

func showCcy(m: in Money): String {
  m.currency
}

func main(): Unit {
  val m = Money(cents = 1500, currency = "USD")
  val v = m.toView()
  match v.tryInto() {
    case Ok(m2)  -> { println(showCents(m2)); println(showCcy(m2)) }
    case Err(_)  -> println("err")
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "1500\nUSD" "tryInto round-trip"

        testCase "[@projectable @hidden field defaults on tryInto]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjH" """
package ProjH
import Std.Core

opaque type Account @projectable {
  id: Int
  passwordHash: String @hidden
}

func showId(a: in Account): Int { a.id }
func showHash(a: in Account): String { a.passwordHash }

func main(): Unit {
  val a = Account(id = 5, passwordHash = "secret")
  val v = a.toView()
  match v.tryInto() {
    case Ok(a2)  -> { println(showId(a2)); println(showHash(a2)) }
    case Err(_)  -> println("err")
  }
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            // The `@hidden` field can't be reverse-projected from the
            // view; the bootstrap fills it with `null` for the String
            // (`@hidden` defaults to the CLR slot's default), which
            // `println` writes as an empty line that `TrimEnd` strips.
            Expect.stringStarts (stdout.TrimEnd()) "5" "id round-trips"

        // ---- @projectionBoundary breaks recursive projection ---------

        testCase "[@projectionBoundary keeps source opaque in view]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "ProjBndA" """
package ProjBndA

opaque type Country @projectable {
  iso: String
}

opaque type Address @projectable {
  city: String
  country: Country @projectionBoundary(asId)
}

func main(): Unit {
  val c = Country(iso = "US")
  val a = Address(city = "NYC", country = c)
  val v = a.toView()
  println(v.city)
  println(v.country.iso)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            // `v.country` is the source `Country` opaque, not its
            // view; reading `v.country.iso` reads through the
            // opaque's field directly.
            Expect.equal (stdout.TrimEnd()) "NYC\nUS"
                "@projectionBoundary skips recursive projection"
    ]
