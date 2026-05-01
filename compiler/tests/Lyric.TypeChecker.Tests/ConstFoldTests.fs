/// Tests for `Lyric.TypeChecker.ConstFold` (C3 / D-progress-025).
///
/// Folder accepts: integer literals, `pub val`-bound integer
/// constants, and arithmetic combinations thereof, with cycle
/// detection and overflow checks.  T0093 fires when a range-subtype
/// bound expression isn't foldable; T0090 fires (post-fold) when the
/// folded bounds are inverted; T0091 still fires for non-numeric
/// underlying types.
module Lyric.TypeChecker.Tests.ConstFoldTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Parser
open Lyric.TypeChecker.Checker

let private parseAndCheck (src: string) : CheckResult =
    let parsed = parse ("package P\n" + src)
    Expect.isEmpty parsed.Diagnostics
        (sprintf "expected clean parse for: %s\nactual: %A" src parsed.Diagnostics)
    check parsed.File

let private hasErrorWithCode (r: CheckResult) (code: string) : bool =
    r.Diagnostics
    |> List.exists (fun d -> d.Severity = DiagError && d.Code = code)

let private errorCount (r: CheckResult) : int =
    r.Diagnostics
    |> List.filter (fun d -> d.Severity = DiagError)
    |> List.length

let tests =
    testList "C3 — const folding for range bounds" [

        test "literal bounds still pass through" {
            let r = parseAndCheck "type Age = Int range 0 ..= 150"
            Expect.equal (errorCount r) 0 "no errors on literal bounds"
        }

        test "literal-inverted bounds: T0090" {
            let r = parseAndCheck "type X = Int range 10 ..= 5"
            Expect.isTrue (hasErrorWithCode r "T0090") "T0090 fires"
        }

        test "named-const bound resolves through pub val" {
            let r =
                parseAndCheck
                    "pub val MIN_AGE: Int = 0\n\
                     pub val MAX_AGE: Int = 150\n\
                     type Age = Int range MIN_AGE ..= MAX_AGE"
            Expect.equal (errorCount r) 0 "no errors when consts fold"
        }

        test "named-const-inverted bounds: T0090 fires post-fold" {
            let r =
                parseAndCheck
                    "pub val LO: Int = 100\n\
                     pub val HI: Int = 50\n\
                     type X = Int range LO ..= HI"
            Expect.isTrue (hasErrorWithCode r "T0090")
                "T0090 fires after folding LO and HI"
        }

        test "arithmetic in bounds folds" {
            let r =
                parseAndCheck
                    "pub val PAGE_SIZE: Int = 100\n\
                     pub val MAX_PAGES: Int = 50\n\
                     type Off = Int range 0 ..= PAGE_SIZE * MAX_PAGES - 1"
            Expect.equal (errorCount r) 0 "PAGE_SIZE * MAX_PAGES - 1 folds"
        }

        test "transitive const reference" {
            let r =
                parseAndCheck
                    "pub val LIMIT: Int = 100\n\
                     pub val DOUBLE: Int = LIMIT * 2\n\
                     type X = Int range 0 ..= DOUBLE"
            Expect.equal (errorCount r) 0 "DOUBLE = LIMIT * 2 folds"
        }

        test "cycle detection: T0093 names the cyclic const" {
            let r =
                parseAndCheck
                    "pub val A: Int = B + 1\n\
                     pub val B: Int = A\n\
                     type X = Int range 0 ..= A"
            Expect.isTrue (hasErrorWithCode r "T0093")
                "T0093 fires on transitive cycle"
            let cycleErr =
                r.Diagnostics
                |> List.exists (fun d ->
                    d.Code = "T0093"
                    && (d.Message.Contains "'A'" || d.Message.Contains "'B'"))
            Expect.isTrue cycleErr "diagnostic names the cyclic const"
        }

        test "non-foldable bound: T0093 with NotConstant message" {
            // Function calls in bounds are out of scope for option (b)
            // — they fold to NotConstant.  `String` is registered as
            // a primitive so it's resolvable but not constant-foldable.
            let r =
                parseAndCheck
                    "pub val UPPER: Int = 100\n\
                     type X = Int range 0 ..= UPPER + UPPER"
            Expect.equal (errorCount r) 0 "UPPER + UPPER folds"
        }

        test "non-numeric underlying type: T0091" {
            let r = parseAndCheck "type X = String range 0 ..= 10"
            Expect.isTrue (hasErrorWithCode r "T0091")
                "T0091 still fires on non-numeric base"
        }

        test "half-open inverted bounds via consts: T0090" {
            let r =
                parseAndCheck
                    "pub val LO: Int = 5\n\
                     pub val HI: Int = 5\n\
                     type X = Int range LO ..< HI"
            Expect.isTrue (hasErrorWithCode r "T0090")
                "T0090 fires when half-open bounds collapse to empty"
        }
    ]
