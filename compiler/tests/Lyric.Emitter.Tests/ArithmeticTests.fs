module Lyric.Emitter.Tests.ArithmeticTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Build a one-shot program: `func main(): Unit { println(<expr>) }`.
let private wrap (label: string) (expr: string) : string =
    sprintf "package %s\nfunc main(): Unit { println(%s) }\n" label expr

/// Compile `wrap label expr` and assert that the resulting program
/// prints `expected` followed by a newline (Console.WriteLine adds
/// the platform-native line terminator; we trim it).
let private exprPrints (label: string) (expr: string) (expected: string) =
    test (sprintf "println(%s) prints %s" expr expected) {
        let _, stdout, stderr, exitCode = compileAndRun label (wrap label expr)
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"
    }

let tests =
    testSequenced
    <| testList "arithmetic + comparison + logical (E2)" [

        // ---- numeric literals ----
        exprPrints "lit_int"   "42"     "42"
        exprPrints "lit_neg"   "-7"     "-7"
        exprPrints "lit_long"  "100i64" "100"
        exprPrints "lit_dbl"   "3.5"    "3.5"
        exprPrints "lit_bool"  "true"   "True"
        exprPrints "lit_false" "false"  "False"

        // ---- arithmetic on Ints ----
        exprPrints "add"  "1 + 2"        "3"
        exprPrints "sub"  "10 - 3"       "7"
        exprPrints "mul"  "4 * 6"        "24"
        exprPrints "div"  "10 / 3"       "3"
        exprPrints "rem"  "10 % 3"       "1"
        exprPrints "neg"  "-(5 + 3)"     "-8"
        exprPrints "prec" "(1 + 2) * 3"  "9"
        exprPrints "left" "10 - 3 - 2"   "5"   // left-associative

        // ---- arithmetic on Doubles ----
        exprPrints "fadd" "1.5 + 2.5"    "4"
        exprPrints "fmul" "2.0 * 3.5"    "7"

        // ---- comparisons ----
        exprPrints "eq_t"  "1 == 1" "True"
        exprPrints "eq_f"  "1 == 2" "False"
        exprPrints "neq"   "1 != 2" "True"
        exprPrints "lt"    "1 < 2"  "True"
        exprPrints "lte_t" "2 <= 2" "True"
        exprPrints "gt"    "2 > 1"  "True"
        exprPrints "gte_f" "1 >= 2" "False"

        // ---- logical ----
        exprPrints "and_t"  "true and true"  "True"
        exprPrints "and_f"  "true and false" "False"
        exprPrints "or_t"   "false or true"  "True"
        exprPrints "or_f"   "false or false" "False"
        exprPrints "not_t"  "not false"      "True"
        exprPrints "not_f"  "not true"       "False"

        // ---- short-circuit: rhs is never evaluated when lhs decides ----
        // We can't easily observe non-evaluation without side effects
        // we don't have yet. Cover the structural case instead.
        exprPrints "shortc_and" "false and true"  "False"
        exprPrints "shortc_or"  "true or false"   "True"
    ]
