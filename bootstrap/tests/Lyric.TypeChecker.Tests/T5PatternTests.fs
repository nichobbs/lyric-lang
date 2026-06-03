/// Tests for T5 pattern inference: PTuple with element types, PConstructor
/// with field types, POr (all alts walked), PRecord, PTypeTest, PRange,
/// and for-loop over TyRange.
module Lyric.TypeChecker.Tests.T5PatternTests

open Expecto
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private parseAndCheck (src: string) : CheckResult =
    let parsed = parse ("package P\n" + src)
    Expect.isEmpty parsed.Diagnostics
        (sprintf "expected clean parse for: %s\nactual: %A" src parsed.Diagnostics)
    check parsed.File

let private codes (r: CheckResult) : string list =
    r.Diagnostics |> List.map (fun d -> d.Code)

let tests =
    testList "T5 — pattern type inference" [

        // =====================================================================
        // PTuple: element types extracted from TyTuple scrutinee
        // =====================================================================

        test "tuple pattern binds element types correctly" {
            let r = parseAndCheck
                        "pub func f(p: in (Int, Bool)): Int {\n\
                         val (n, _) = p\n\
                         return n }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "tuple pattern — type mismatch on extracted element reports T0060" {
            let r = parseAndCheck
                        "pub func f(p: in (Int, Bool)): Unit {\n\
                         val (n, _) = p\n\
                         val s: String = n }"
            Expect.contains (codes r) "T0060" "T0060 for wrong element type"
        }

        // =====================================================================
        // PConstructor: field types from union case symbol
        // =====================================================================

        test "constructor pattern binds field with correct type" {
            let r = parseAndCheck
                        "pub union Opt { case Some(value: Int), case None }\n\
                         pub func unwrap(o: in Opt): Int {\n\
                         match o {\n\
                           case Some(v) -> return v\n\
                           case None    -> return 0\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "constructor pattern field used with wrong type reports T0060" {
            let r = parseAndCheck
                        "pub union Opt { case Some(value: Int), case None }\n\
                         pub func bad(o: in Opt): String {\n\
                         match o {\n\
                           case Some(v) -> { val s: String = v ; return s }\n\
                           case None    -> return \"\"\n\
                         }}"
            Expect.contains (codes r) "T0060" "T0060 for field type mismatch"
        }

        // =====================================================================
        // POr: all alternatives are walked for diagnostics
        // =====================================================================

        test "or-pattern: first alternative's binding is available in body" {
            let r = parseAndCheck
                        "pub func classify(n: in Int): String {\n\
                         match n {\n\
                           case 1 | 2 | 3 -> return \"small\"\n\
                           case _          -> return \"other\"\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // PRecord: field bindings from record type
        // =====================================================================

        test "record pattern short-hand binds field with record's field type" {
            let r = parseAndCheck
                        "pub record Point { x: Int, y: Int }\n\
                         pub func xCoord(p: in Point): Int {\n\
                         match p {\n\
                           case Point { x, .. } -> return x\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "record pattern named binding has correct type" {
            let r = parseAndCheck
                        "pub record Point { x: Int, y: Int }\n\
                         pub func sum(p: in Point): Int {\n\
                         match p {\n\
                           case Point { x = ax, y = ay } -> return ax + ay\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // PTypeTest: narrows to the tested type
        // =====================================================================

        test "type-test pattern in val binding narrows variable to tested type" {
            let r = parseAndCheck
                        "pub func coerce(x: in Int): Int {\n\
                         val v is Int = x\n\
                         return v }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // PRange: no bindings produced, pattern accepted cleanly
        // =====================================================================

        test "range pattern in match is accepted without diagnostics" {
            let r = parseAndCheck
                        "pub func tier(n: in Int): String {\n\
                         match n {\n\
                           case 0..=9   -> return \"low\"\n\
                           case 10..=99 -> return \"mid\"\n\
                           case _       -> return \"high\"\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // for-loop over slice[Int]
        // =====================================================================

        test "for-loop over slice[Int] type-checks the body using Int element" {
            let r = parseAndCheck
                        "pub func sum(xs: in slice[Int]): Int {\n\
                         var acc: Int = 0\n\
                         for i in xs { acc = acc + i }\n\
                         return acc }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "for-loop slice element used as non-Int type reports T0060" {
            let r = parseAndCheck
                        "pub func bad(xs: in slice[Int]): Unit {\n\
                         for i in xs {\n\
                           val s: String = i\n\
                         }}"
            Expect.contains (codes r) "T0060" "T0060 for Int-to-String binding"
        }

        // =====================================================================
        // Wildcard and binding_ patterns stay clean
        // =====================================================================

        test "wildcard pattern produces no binding" {
            let r = parseAndCheck
                        "pub func f(n: in Int): Int {\n\
                         match n {\n\
                           case _ -> return 0\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "PBinding underscore is treated as wildcard" {
            let r = parseAndCheck
                        "pub func f(n: in Int): Int {\n\
                         val _ = n\n\
                         return 0 }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }
    ]
