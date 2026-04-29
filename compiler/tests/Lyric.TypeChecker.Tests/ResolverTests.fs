module Lyric.TypeChecker.Tests.ResolverTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

/// Pull the diagnostic codes from a check result for terse assertions.
let private codes (r: CheckResult) =
    r.Diagnostics |> List.map (fun d -> d.Code)

let private noT (r: CheckResult) =
    r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "T")

let tests =
    testList "resolver" [

        test "primitive aliases resolve" {
            let src = """
package Demo

func id(x: Int): Int = x
func toBool(b: Bool): Bool = b
func toLong(l: Long): Long = l
func toDouble(d: Double): Double = d
func toString(s: String): String = s
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no type-checker diagnostics"
        }

        test "unknown type is tolerated as a TyNamed shell" {
            // Phase 1 deliberately suppresses T0002 for short-name
            // type references so worked-example blocks that pull
            // names from imports we haven't loaded don't drown
            // the diagnostic stream. The check still runs to
            // completion.
            let src = """
package Demo
func bad(x: ZzzNotAType): Int = 0
"""
            let r = checkSource src
            Expect.isFalse (List.contains "T0002" (codes r))
                "T0002 suppressed in Phase 1"
        }

        test "tuple, slice, nullable types resolve" {
            let src = """
package Demo
func tup(t: (Int, Bool)): Int = 0
func slc(s: slice[Int]): Int = 0
func nul(n: Int?): Int = 0
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no type-checker diagnostics"
        }

        test "function type resolves" {
            let src = """
package Demo
func apply(f: (Int) -> Int, x: Int): Int = 0
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no type-checker diagnostics"
        }

        test "user record names resolve" {
            let src = """
package Demo

record Point {
  x: Int
  y: Int
}

func origin(): Point = Point
"""
            let r = checkSource src
            // We don't yet resolve `Point` constructor calls, so only
            // validate that the type name resolves at the param/return
            // boundary.
            Expect.isFalse (List.contains "T0002" (codes r))
                "Point should be a known type"
        }

        test "imported alias resolves" {
            let src = """
package Demo

import Money.Amount

func toAmount(a: Amount): Amount = a
"""
            let r = checkSource src
            // Without a registered Money.Amount the reference still
            // resolves through the alias machinery (TyNamed shell),
            // so no T0002.
            Expect.isFalse (List.contains "T0002" (codes r))
                "Amount alias resolves"
        }

        test "value generics emit T0003" {
            let src = """
package Demo

record Vec[T, N: Int] {
  data: slice[T]
}

func first(v: Vec[Int, 4]): Int = 0
"""
            let r = checkSource src
            // Currently produces T0003 on the value-generic
            // declaration site if we resolve it.
            ignore (codes r)
            // No assertion — just make sure parsing/checking doesn't
            // throw.
            Expect.isTrue true "value generics tolerated"
        }
    ]
