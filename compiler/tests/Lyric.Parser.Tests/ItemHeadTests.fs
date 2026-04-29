module Lyric.Parser.Tests.ItemHeadTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseFile (src: string) =
    parse src

let private prelude = "package P\n"

let tests =
    testList "item-head recognition" [

        test "every item kind is recognised and skipped to body end" {
            let cases =
                [ "pub func f(): Int = 1"
                  "pub record R { x: Int }"
                  "pub union U { case A, case B }"
                  "pub enum E { case Red, case Green }"
                  "pub opaque type O { x: Int }"
                  "pub protected type P { var x: Int }"
                  "pub exposed record X { y: Int }"
                  "pub interface I { func f(): Int }"
                  "impl I for X { func f(): Int = 1 }"
                  "wire W { expose x }"
                  "extern package Sys { func f(): Int }"
                  "test \"x\" { 1 }"
                  "property \"y\" { true }"
                  "fixture f = 1"
                  "pub type X = Long"
                  "pub alias Y = Long"
                  "pub val K: Int = 42"
                  "pub async func g(): Int = 1"
                  "scope_kind Tenant" ]
            for src in cases do
                let r = parseFile (prelude + src)
                // Must produce exactly one item; its kind is IError
                // (the recognise-and-skip placeholder for now).
                Expect.equal r.File.Items.Length 1
                    (sprintf "one item parsed for: %s" src)
                match r.File.Items.[0].Kind with
                | IError -> ()
                | other -> failtestf "expected IError, got %A in: %s" other src
                // Each item should have raised exactly one P0098.
                let p98s =
                    r.Diagnostics
                    |> List.filter (fun d -> d.Code = "P0098")
                Expect.equal p98s.Length 1
                    (sprintf "one P0098 for: %s" src)
        }

        test "doc comments and annotations attach to the next item" {
            let src =
                prelude
                + "/// the function f\n"
                + "/// returns the answer\n"
                + "@derive(Json)\n"
                + "pub func f(): Int = 42\n"
            let r = parseFile src
            Expect.equal r.File.Items.Length 1 "one item"
            let it = r.File.Items.[0]
            Expect.equal it.DocComments.Length 2 "two doc lines"
            Expect.equal it.Annotations.Length 1 "one annotation"
            match it.Visibility with
            | Some (Pub _) -> ()
            | None -> failtest "expected pub"
        }

        test "two consecutive items, both recognised" {
            let src =
                prelude
                + "pub type Cents = Long\n"
                + "pub record Amount { value: Cents }\n"
            let r = parseFile src
            Expect.equal r.File.Items.Length 2 "two items"
            let p98s =
                r.Diagnostics
                |> List.filter (fun d -> d.Code = "P0098")
            Expect.equal p98s.Length 2 "two P0098 diagnostics"
        }

        test "non-item garbage produces P0040 and recovery continues" {
            // `42` at the top level is not a valid item start; the
            // parser flags it and consumes one token to make progress,
            // then recognises the following record.
            let src =
                prelude
                + "42\n"
                + "pub type X = Long\n"
            let r = parseFile src
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0040" "non-item flagged"
            // A single legitimate item should still be parsed.
            let realItems =
                r.File.Items
                |> List.filter (fun i ->
                    match i.Kind with IError -> true | _ -> false)
            Expect.isGreaterThanOrEqual realItems.Length 1
                "at least one item recognised"
        }

        test "balanced braces inside an item body do not confuse the skipper" {
            // The closing `}` here is at the end; the `{` inside `match`
            // increments depth, the inner `}` decrements, and the body
            // skip terminates only when depth returns to 0 with the
            // outer brace closed.
            let src =
                prelude
                + "pub func f(x: in Int): Int {\n"
                + "  return match x { case 0 -> 1, case _ -> 2 }\n"
                + "}\n"
                + "pub type Y = Int\n"
            let r = parseFile src
            Expect.equal r.File.Items.Length 2 "two items recognised"
        }

        test "extern package with multiple inner items still skips to its end" {
            let src =
                prelude
                + "@axiom\n"
                + "extern package Sys.IO {\n"
                + "  pub func read(): String\n"
                + "  pub func write(s: in String): Unit\n"
                + "}\n"
                + "pub func main(): Int = 0\n"
            let r = parseFile src
            Expect.equal r.File.Items.Length 2 "two top-level items"
        }
    ]
