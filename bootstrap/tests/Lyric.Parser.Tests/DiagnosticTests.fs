module Lyric.Parser.Tests.DiagnosticTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseWithDiags (src: string) =
    let r = parse (prelude + src)
    r.Diagnostics

let private codes (diags: Diagnostic list) =
    diags |> List.map (fun d -> d.Code)

let tests =
    testList "parser diagnostics and recovery" [

        // ----- type-side diagnostics -----

        test "missing closing bracket on slice produces P0061" {
            let _, diags = parseTypeFromString "slice[Int"
            Expect.contains (codes diags) "P0061" "P0061"
        }

        test "missing closing bracket on array produces P0061" {
            let _, diags = parseTypeFromString "array[16, Byte"
            Expect.contains (codes diags) "P0061" "P0061"
        }

        test "missing comma between size and element in array produces P0062" {
            let _, diags = parseTypeFromString "array[16 Byte]"
            Expect.contains (codes diags) "P0062" "P0062"
        }

        test "missing closing paren on parens type produces P0063" {
            let _, diags = parseTypeFromString "(Int"
            Expect.contains (codes diags) "P0063" "P0063"
        }

        // ----- expression-side diagnostics -----

        test "missing closing paren on call produces P0080" {
            let _, diags = parseExprFromString "f(a, b"
            Expect.contains (codes diags) "P0080" "P0080"
        }

        test "missing identifier after `.` produces P0081" {
            let _, diags = parseExprFromString "obj."
            Expect.contains (codes diags) "P0081" "P0081"
        }

        test "missing closing bracket on index produces P0083" {
            let _, diags = parseExprFromString "xs[0"
            Expect.contains (codes diags) "P0083" "P0083"
        }

        test "missing closing bracket on list literal produces P0192" {
            let _, diags = parseExprFromString "[1, 2"
            Expect.contains (codes diags) "P0192" "P0192"
        }

        test "missing close-paren on parenthesised expression produces P0051" {
            let _, diags = parseExprFromString "(a"
            Expect.contains (codes diags) "P0051" "P0051"
        }

        // ----- statement-side diagnostics -----

        test "missing 'in' in for-loop produces P0221" {
            let diags = parseWithDiags "func f(): Int { for x xs { } ; return 0 }"
            Expect.contains (codes diags) "P0221" "P0221"
        }

        // ----- file-head -----

        test "missing identifier after package produces P0010" {
            let r = parse "package"
            Expect.contains (codes r.Diagnostics) "P0010" "P0010"
        }

        // ----- pattern-side -----

        test "garbage where a pattern is expected produces P0075" {
            let _, diags = parsePatternFromString "{"
            Expect.contains (codes diags) "P0075" "P0075"
        }

        // ----- impl-side -----

        test "missing 'for' in impl produces P0180" {
            let diags = parseWithDiags "impl I X { func f(): Int = 0 }"
            Expect.contains (codes diags) "P0180" "P0180"
        }

        // ----- enum can't be generic -----

        test "generic on enum produces P0100" {
            let diags = parseWithDiags "generic[T] enum E { case A }"
            Expect.contains (codes diags) "P0100" "P0100"
        }

        // ----- recovery: parser doesn't infinite-loop on malformed input -----

        test "unterminated record body still terminates parsing" {
            // This previously could spin in the member-loop without
            // forceAdvanceIfStuck — we just check that parsing
            // returns a finite ParseResult.
            let r = parse (prelude + "record P {\n  x: Int\n  y: ")
            Expect.isNonEmpty r.Diagnostics "expected diagnostics"
        }

        test "garbage at top level after a valid item still parses what it can" {
            let r = parse (prelude + "pub type X = Int\n42\npub type Y = Long\n")
            // P0040 reported for the lone 42 …
            Expect.contains (codes r.Diagnostics) "P0040" "P0040"
            // … and both type items are recognised.
            let typedItems =
                r.File.Items
                |> List.filter (fun i ->
                    match i.Kind with IDistinctType _ -> true | _ -> false)
            Expect.equal typedItems.Length 2 "two distinct types"
        }
    ]
