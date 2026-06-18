module Lyric.Parser.Tests.AdditionalTypeExprTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let t, diags = parseTypeFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    t

let tests =
    testList "additional type-expression forms" [

        // ----- nullable composition -----

        test "nullable on slice" {
            let t = parseClean "slice[Int]?"
            match t.Kind with
            | TNullable { Kind = TSlice _ } -> ()
            | other -> failtestf "expected TNullable TSlice, got %A" other
        }

        test "nullable on generic application" {
            let t = parseClean "Map[Int, String]?"
            match t.Kind with
            | TNullable { Kind = TGenericApp _ } -> ()
            | other -> failtestf "expected TNullable TGenericApp, got %A" other
        }

        test "double nullable is not allowed implicitly — '??' is a different token" {
            // T?? would be `T` `??` — not a sensible type. The parser
            // should report an error after the type.
            let _, diags = parseTypeFromString "Int??"
            // Either a P0050 expected-a-type for the trailing `?`, or
            // P0064 unexpected-tokens-after-type. We require at least
            // one diagnostic.
            Expect.isNonEmpty diags "expected diagnostic"
        }

        // ----- generic application edge cases -----

        test "generic with one arg uses TGenericApp not TSlice" {
            let t = parseClean "Box[Int]"
            match t.Kind with
            | TGenericApp(head, [_]) ->
                Expect.equal head.Segments ["Box"] "head"
            | other -> failtestf "expected TGenericApp, got %A" other
        }

        test "nested generic application" {
            let t = parseClean "Result[slice[Int], Error]"
            match t.Kind with
            | TGenericApp(_, args) ->
                Expect.equal args.Length 2 "two args"
                match args.[0] with
                | TAType { Kind = TSlice _ } -> ()
                | other -> failtestf "first arg: %A" other
            | other -> failtestf "expected TGenericApp, got %A" other
        }

        test "function returning function" {
            let t = parseClean "(Int) -> (String) -> Bool"
            match t.Kind with
            | TFunction([_], { Kind = TFunction([_], _) }) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "function with multiple parameters and tuple result" {
            let t = parseClean "(Int, String) -> (Bool, Bool)"
            match t.Kind with
            | TFunction([_; _], { Kind = TTuple _ }) -> ()
            | other -> failtestf "shape: %A" other
        }

        // ----- range refinement compositions -----

        test "refined type inside a tuple" {
            let t = parseClean "(Int range 0 ..= 10, String)"
            match t.Kind with
            | TTuple [a; _] ->
                match a.Kind with
                | TRefined _ -> ()
                | other -> failtestf "first: %A" other
            | other -> failtestf "expected TTuple, got %A" other
        }

        test "tuple with nullable element" {
            let t = parseClean "(Int?, String)"
            match t.Kind with
            | TTuple [a; _] ->
                match a.Kind with
                | TNullable _ -> ()
                | other -> failtestf "first: %A" other
            | other -> failtestf "expected TTuple, got %A" other
        }

        // ----- error positions -----

        test "trailing garbage after type produces P0064" {
            let _, diags = parseTypeFromString "Int @"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0064" "P0064 reported"
        }
    ]
