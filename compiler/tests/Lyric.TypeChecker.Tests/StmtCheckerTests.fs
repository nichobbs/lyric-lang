module Lyric.TypeChecker.Tests.StmtCheckerTests

open Expecto
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private codes (r: CheckResult) =
    r.Diagnostics |> List.map (fun d -> d.Code)

let private noT (r: CheckResult) =
    r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "T")

let tests =
    testList "statement checker" [

        test "val binding records the local" {
            let src = """
package Demo
func sum(x: Int, y: Int): Int {
  val total = x + y
  total
}
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "no diagnostics"
        }

        test "annotated val rejects mismatched init" {
            let src = """
package Demo
func bad(): Int {
  val x: Int = true
  x
}
"""
            let r = checkSource src
            Expect.contains (codes r) "T0060" "Bool init for Int annotation"
        }

        test "var without annotation or initializer emits T0061" {
            let src = """
package Demo
func bad(): Int {
  var x
  0
}
"""
            let r = checkSource src
            Expect.contains (codes r) "T0061" "var requires annotation or init"
        }

        test "assignment compatible types" {
            let src = """
package Demo
func ok(): Int {
  var x: Int = 0
  x = 5
  x
}
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "Int = Int compatible"
        }

        test "assignment incompatible types emits T0062" {
            let src = """
package Demo
func bad(): Int {
  var x: Int = 0
  x = true
  x
}
"""
            let r = checkSource src
            Expect.contains (codes r) "T0062" "Int := Bool"
        }

        test "return value type must match signature" {
            let src = """
package Demo
func bad(): Int {
  return true
}
"""
            let r = checkSource src
            Expect.contains (codes r) "T0064" "Bool return for Int"
        }

        test "while condition must be Bool" {
            let src = """
package Demo
func loop(): Int {
  while 1 {
    return 0
  }
  0
}
"""
            let r = checkSource src
            Expect.contains (codes r) "T0065" "Int as while condition"
        }

        test "scope hides outer locals on pop" {
            let src = """
package Demo
func nested(): Int {
  val x = 1
  scope {
    val y = 2
    val _ = y
  }
  x
}
"""
            let r = checkSource src
            Expect.isEmpty (noT r) "x stays visible, y is local to inner"
        }
    ]
