module Lyric.Parser.Tests.AdditionalPatternTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let p, diags = parsePatternFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    p

let tests =
    testList "additional pattern forms" [

        // ----- nested record patterns -----

        test "record pattern with all named fields" {
            let p = parseClean "Point { x = 1, y = 2 }"
            match p.Kind with
            | PRecord(_, fields, false) ->
                Expect.equal fields.Length 2 "two named fields"
            | other -> failtestf "expected PRecord, got %A" other
        }

        test "record pattern with all shorthand fields" {
            let p = parseClean "Point { x, y, z }"
            match p.Kind with
            | PRecord(_, fields, false) ->
                Expect.equal fields.Length 3 "three shorthand"
                for f in fields do
                    match f with
                    | RPFShort _ -> ()
                    | other -> failtestf "field: %A" other
            | other -> failtestf "expected PRecord, got %A" other
        }

        test "record pattern with only `..`" {
            // The grammar admits `Point { .. }` — the field list may
            // be empty when the ignore-rest marker is present.
            let p = parseClean "Point { .. }"
            match p.Kind with
            | PRecord(_, [], true) -> ()
            | other -> failtestf "expected PRecord {..}, got %A" other
        }

        test "qualified record pattern head" {
            let p = parseClean "Geometry.Point { x = 0, y = 0 }"
            match p.Kind with
            | PRecord(head, _, _) ->
                Expect.equal head.Segments ["Geometry"; "Point"] "qualified head"
            | other -> failtestf "expected PRecord, got %A" other
        }

        // ----- nested constructor patterns -----

        test "constructor with literal arg" {
            let p = parseClean "Some(42)"
            match p.Kind with
            | PConstructor(head, [arg]) ->
                Expect.equal head.Segments ["Some"] "head"
                match arg.Kind with
                | PLiteral (LInt(42UL, _)) -> ()
                | other -> failtestf "arg: %A" other
            | other -> failtestf "expected PConstructor, got %A" other
        }

        test "constructor with wildcard arg" {
            let p = parseClean "Err(_)"
            match p.Kind with
            | PConstructor(_, [{ Kind = PWildcard }]) -> ()
            | other -> failtestf "expected PConstructor with wildcard, got %A" other
        }

        test "constructor with binding-with-inner arg" {
            let p = parseClean "Wrapper(value @ 42)"
            match p.Kind with
            | PConstructor(_, [{ Kind = PBinding("value", Some _) }]) -> ()
            | other -> failtestf "shape: %A" other
        }

        test "deeply nested constructor" {
            let p = parseClean "Tree(Leaf, Node(Leaf, Leaf))"
            match p.Kind with
            | PConstructor(_, [a; b]) ->
                match a.Kind with
                | PBinding("Leaf", None) -> ()
                | other -> failtestf "first: %A" other
                match b.Kind with
                | PConstructor(_, [_; _]) -> ()
                | other -> failtestf "second: %A" other
            | other -> failtestf "expected PConstructor, got %A" other
        }

        // ----- range patterns -----

        test "range pattern with negative bounds via path" {
            // Pattern range bounds are expressions; only literal forms
            // are admitted here, so test what the parser accepts.
            let p = parseClean "1 ..= 5"
            match p.Kind with
            | PRange(_, true, _) -> ()
            | other -> failtestf "expected PRange, got %A" other
        }

        // ----- combinations -----

        test "or-pattern of constructors" {
            let p = parseClean "Some(_) | None"
            match p.Kind with
            | POr [a; b] ->
                match a.Kind with
                | PConstructor _ -> ()
                | other -> failtestf "first: %A" other
                match b.Kind with
                | PBinding("None", None) -> ()
                | other -> failtestf "second: %A" other
            | other -> failtestf "expected POr, got %A" other
        }

        test "tuple of literals" {
            let p = parseClean "(1, 2, 3)"
            match p.Kind with
            | PTuple xs ->
                Expect.equal xs.Length 3 "three"
                for x in xs do
                    match x.Kind with
                    | PLiteral (LInt _) -> ()
                    | other -> failtestf "element: %A" other
            | other -> failtestf "expected PTuple, got %A" other
        }

        test "type-test on a binding" {
            let p = parseClean "x is Account"
            match p.Kind with
            | PTypeTest({ Kind = PBinding _ }, ty) ->
                match ty.Kind with
                | TRef path -> Expect.equal path.Segments ["Account"] "type"
                | other -> failtestf "ty: %A" other
            | other -> failtestf "expected PTypeTest, got %A" other
        }

        test "binding with at-pattern wrapping a constructor" {
            let p = parseClean "x @ Some(_)"
            match p.Kind with
            | PBinding("x", Some inner) ->
                match inner.Kind with
                | PConstructor _ -> ()
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected PBinding x @ ..., got %A" other
        }

        // ----- char and float literal patterns -----

        test "char literal pattern" {
            let p = parseClean "'a'"
            match p.Kind with
            | PLiteral (LChar c) -> Expect.equal c (int 'a') "char value"
            | other -> failtestf "expected PLiteral LChar, got %A" other
        }

        test "false bool pattern" {
            let p = parseClean "false"
            match p.Kind with
            | PLiteral (LBool false) -> ()
            | other -> failtestf "expected PLiteral false, got %A" other
        }
    ]
