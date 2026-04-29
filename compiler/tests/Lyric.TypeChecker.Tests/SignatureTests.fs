module Lyric.TypeChecker.Tests.SignatureTests

open Expecto
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private codes (r: CheckResult) =
    r.Diagnostics |> List.map (fun d -> d.Code)

let private noT (r: CheckResult) =
    r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "T")

let tests =
    testList "signature resolution" [

        test "monomorphic function resolves" {
            let src = """
package Demo
func add(x: Int, y: Int): Int = 0
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no type-checker diagnostics"
        }

        test "generic type parameters are accepted" {
            let src = """
package Demo
func id[T](x: T): T = x
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "T resolves as a type variable"
        }

        test "missing return type defaults to Unit" {
            let src = """
package Demo
func sideEffect(x: Int) = ()
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "Unit-returning function checks"
        }

        test "function param using unknown type is tolerated" {
            let src = """
package Demo
func bad(x: NotAType): Int = 0
"""
            let r = checkSource src
            // Phase 1 suppresses T0002; the unknown name is folded
            // into a TyNamed shell so the body still type-checks.
            Expect.isFalse (List.contains "T0002" (codes r))
                "T0002 suppressed in Phase 1"
        }

        test "function with mode and default" {
            let src = """
package Demo
func greet(name: in String): String = name
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "in-mode checks"
        }
    ]
