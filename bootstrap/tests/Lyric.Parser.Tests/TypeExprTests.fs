module Lyric.Parser.Tests.TypeExprTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let t, diags = parseTypeFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    t

let tests =
    testList "type expressions" [

        // ----- references and paths -----

        test "single-ident type reference" {
            let t = parseClean "Int"
            match t.Kind with
            | TRef path -> Expect.equal path.Segments ["Int"] "path"
            | other -> failtestf "expected TRef, got %A" other
        }

        test "qualified type reference" {
            let t = parseClean "Money.Amount"
            match t.Kind with
            | TRef path -> Expect.equal path.Segments ["Money"; "Amount"] "path"
            | other -> failtestf "expected TRef, got %A" other
        }

        // ----- generic application -----

        test "generic type application with one type arg" {
            let t = parseClean "slice[Int]"
            match t.Kind with
            | TSlice elem ->
                match elem.Kind with
                | TRef p -> Expect.equal p.Segments ["Int"] "element"
                | other -> failtestf "expected TRef, got %A" other
            | other -> failtestf "expected TSlice, got %A" other
        }

        test "generic type application with multiple args" {
            let t = parseClean "Result[Amount, ContractViolation]"
            match t.Kind with
            | TGenericApp(head, args) ->
                Expect.equal head.Segments ["Result"] "head"
                Expect.equal args.Length 2 "two args"
            | other -> failtestf "expected TGenericApp, got %A" other
        }

        test "qualified generic application" {
            let t = parseClean "std.collections.Map[Int, String]"
            match t.Kind with
            | TGenericApp(head, args) ->
                Expect.equal head.Segments ["std"; "collections"; "Map"] "head"
                Expect.equal args.Length 2 "args"
            | other -> failtestf "expected TGenericApp, got %A" other
        }

        // ----- array form -----

        test "fixed-size array with literal size" {
            let t = parseClean "array[16, Byte]"
            match t.Kind with
            | TArray(TAValue size, elem) ->
                match size.Kind with
                | ELiteral (LInt(16UL, _)) -> ()
                | other -> failtestf "expected size 16, got %A" other
                match elem.Kind with
                | TRef p -> Expect.equal p.Segments ["Byte"] "element"
                | other -> failtestf "expected Byte, got %A" other
            | other -> failtestf "expected TArray, got %A" other
        }

        test "fixed-size array with named size" {
            let t = parseClean "array[N, T]"
            match t.Kind with
            | TArray(_, _) -> ()
            | other -> failtestf "expected TArray, got %A" other
        }

        // ----- range refinement -----

        test "range refinement on Int" {
            let t = parseClean "Int range 0 ..= 99"
            match t.Kind with
            | TRefined(under, RBClosed(lo, hi)) ->
                Expect.equal under.Segments ["Int"] "underlying"
                match lo.Kind, hi.Kind with
                | ELiteral (LInt(0UL, _)), ELiteral (LInt(99UL, _)) -> ()
                | l, h -> failtestf "bounds: %A / %A" l h
            | other -> failtestf "expected TRefined, got %A" other
        }

        test "range with underscore-separated literal" {
            let t = parseClean "Long range 0 ..= 1_000_000_000_00"
            match t.Kind with
            | TRefined(_, RBClosed(_, hi)) ->
                match hi.Kind with
                | ELiteral (LInt(100000000000UL, _)) -> ()
                | other -> failtestf "hi: %A" other
            | other -> failtestf "expected TRefined, got %A" other
        }

        test "half-open range refinement" {
            let t = parseClean "Int range 0 ..< 10"
            match t.Kind with
            | TRefined(_, RBHalfOpen(_, hi)) ->
                match hi.Kind with
                | ELiteral (LInt(10UL, _)) -> ()
                | other -> failtestf "hi: %A" other
            | other -> failtestf "expected TRefined, got %A" other
        }

        // ----- tuple, paren, unit -----

        test "unit type" {
            let t = parseClean "()"
            match t.Kind with
            | TUnit -> ()
            | other -> failtestf "expected TUnit, got %A" other
        }

        test "paren type" {
            let t = parseClean "(Int)"
            match t.Kind with
            | TParen inner ->
                match inner.Kind with
                | TRef p -> Expect.equal p.Segments ["Int"] "inner"
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected TParen, got %A" other
        }

        test "two-tuple type" {
            let t = parseClean "(Int, String)"
            match t.Kind with
            | TTuple [a; b] ->
                match a.Kind, b.Kind with
                | TRef pa, TRef pb ->
                    Expect.equal pa.Segments ["Int"] "first"
                    Expect.equal pb.Segments ["String"] "second"
                | l, r -> failtestf "%A / %A" l r
            | other -> failtestf "expected TTuple of 2, got %A" other
        }

        test "three-tuple type" {
            let t = parseClean "(A, B, C)"
            match t.Kind with
            | TTuple xs -> Expect.equal xs.Length 3 "three"
            | other -> failtestf "expected TTuple of 3, got %A" other
        }

        // ----- nullable -----

        test "nullable type" {
            let t = parseClean "Account?"
            match t.Kind with
            | TNullable inner ->
                match inner.Kind with
                | TRef p -> Expect.equal p.Segments ["Account"] "inner"
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected TNullable, got %A" other
        }

        test "nullable on tuple" {
            let t = parseClean "(Int, String)?"
            match t.Kind with
            | TNullable inner ->
                match inner.Kind with
                | TTuple [_; _] -> ()
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected TNullable, got %A" other
        }

        // ----- function types -----

        test "single-arg function type" {
            let t = parseClean "Int -> String"
            match t.Kind with
            | TFunction([param], result) ->
                match param.Kind, result.Kind with
                | TRef p, TRef r ->
                    Expect.equal p.Segments ["Int"] "param"
                    Expect.equal r.Segments ["String"] "result"
                | _ -> failtest "shape"
            | other -> failtestf "expected TFunction([_], _), got %A" other
        }

        test "two-arg function type via tuple" {
            let t = parseClean "(Int, String) -> Bool"
            match t.Kind with
            | TFunction(params', result) ->
                Expect.equal params'.Length 2 "two parameters"
                match result.Kind with
                | TRef p -> Expect.equal p.Segments ["Bool"] "result"
                | other -> failtestf "result: %A" other
            | other -> failtestf "expected TFunction, got %A" other
        }

        test "no-arg function type" {
            let t = parseClean "() -> Int"
            match t.Kind with
            | TFunction([], result) ->
                match result.Kind with
                | TRef p -> Expect.equal p.Segments ["Int"] "result"
                | other -> failtestf "result: %A" other
            | other -> failtestf "expected TFunction([], _), got %A" other
        }

        test "function type is right-associative" {
            // `Int -> Int -> Int` parses as `Int -> (Int -> Int)`.
            let t = parseClean "Int -> Int -> Int"
            match t.Kind with
            | TFunction([_], inner) ->
                match inner.Kind with
                | TFunction([_], _) -> ()
                | other -> failtestf "inner: %A" other
            | other -> failtestf "outer: %A" other
        }

        test "function with nullable parameter" {
            let t = parseClean "Account? -> Bool"
            match t.Kind with
            | TFunction([param], _) ->
                match param.Kind with
                | TNullable _ -> ()
                | other -> failtestf "param: %A" other
            | other -> failtestf "shape: %A" other
        }

        // ----- self / never -----

        test "Self type" {
            let t = parseClean "Self"
            match t.Kind with
            | TSelf -> ()
            | other -> failtestf "expected TSelf, got %A" other
        }

        test "Never type" {
            let t = parseClean "Never"
            match t.Kind with
            | TNever -> ()
            | other -> failtestf "expected TNever, got %A" other
        }

        // ----- combinations -----

        test "slice of generic" {
            let t = parseClean "slice[Result[Int, Error]]"
            match t.Kind with
            | TSlice inner ->
                match inner.Kind with
                | TGenericApp(head, _) ->
                    Expect.equal head.Segments ["Result"] "head"
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected TSlice, got %A" other
        }

        test "nullable inside tuple inside function" {
            // (Int, String?) -> Bool?
            let t = parseClean "(Int, String?) -> Bool?"
            match t.Kind with
            | TFunction([_; second], result) ->
                match second.Kind with
                | TNullable _ -> ()
                | other -> failtestf "second: %A" other
                match result.Kind with
                | TNullable _ -> ()
                | other -> failtestf "result: %A" other
            | other -> failtestf "shape: %A" other
        }

        // ----- errors -----

        test "garbage where a type is expected reports P0050" {
            let _, diags = parseTypeFromString "?"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0050" "expected-a-type"
        }
    ]
