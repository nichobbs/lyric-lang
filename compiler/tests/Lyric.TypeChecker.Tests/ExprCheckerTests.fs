module Lyric.TypeChecker.Tests.ExprCheckerTests

open Expecto
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private codes (r: CheckResult) =
    r.Diagnostics |> List.map (fun d -> d.Code)

let private noT (r: CheckResult) =
    r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "T")

let tests =
    testList "expression checker" [

        test "literal types infer" {
            let src = """
package Demo
func one(): Int = 1
func t():   Bool = true
func s():   String = "x"
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no diagnostics"
        }

        test "parameter reference resolves to declared type" {
            let src = """
package Demo
func id(x: Int): Int = x
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "x: Int returns Int"
        }

        test "wrong return type emits T0070" {
            let src = """
package Demo
func bad(): Int = true
"""
            let r = checkSource src
            Expect.contains (codes r) "T0070" "Bool body for Int return"
        }

        test "addition of compatible primitives" {
            let src = """
package Demo
func add(x: Int, y: Int): Int = x + y
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no diagnostics on Int+Int"
        }

        test "comparison returns Bool" {
            let src = """
package Demo
func eq(x: Int, y: Int): Bool = x == y
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "Int == Int : Bool"
        }

        test "wrong-arity call emits T0040" {
            let src = """
package Demo
func add(x: Int, y: Int): Int = x + y
func main(): Int = add(1)
"""
            let r = checkSource src
            Expect.contains (codes r) "T0040" "expected 2 args, got 1"
        }

        test "argument type mismatch emits T0041" {
            let src = """
package Demo
func id(x: Int): Int = x
func main(): Int = id(true)
"""
            let r = checkSource src
            Expect.contains (codes r) "T0041" "Bool arg into Int"
        }

        test "logical operator demands Bool operands" {
            let src = """
package Demo
func bad(): Bool = 1 and true
"""
            let r = checkSource src
            Expect.contains (codes r) "T0053" "Int as logical operand"
        }

        test "if-condition must be Bool" {
            let src = """
package Demo
func bad(): Int = if 1 then 1 else 2
"""
            let r = checkSource src
            Expect.contains (codes r) "T0021" "Int as if condition"
        }

        test "match scrutinee accepts any type" {
            let src = """
package Demo
func toInt(o: Int): Int = match o { case _ -> 0 }
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "match checks"
        }

        test "tuple expression has tuple type" {
            let src = """
package Demo
func pair(x: Int, b: Bool): (Int, Bool) = (x, b)
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "tuple checks"
        }

        test "list literal element types must agree" {
            let src = """
package Demo
func bad(): slice[Int] = [1, true, 3]
"""
            let r = checkSource src
            Expect.contains (codes r) "T0020" "Bool element among Ints"
        }
    ]
