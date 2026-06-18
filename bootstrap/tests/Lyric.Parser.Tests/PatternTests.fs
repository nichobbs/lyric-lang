module Lyric.Parser.Tests.PatternTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let p, diags = parsePatternFromString src
    Expect.isEmpty diags (sprintf "expected no diagnostics for %A" src)
    p

let tests =
    testList "patterns" [

        // ----- wildcard, literal, range -----

        test "underscore wildcard" {
            let p = parseClean "_"
            match p.Kind with
            | PWildcard -> ()
            | other -> failtestf "expected PWildcard, got %A" other
        }

        test "integer literal pattern" {
            let p = parseClean "42"
            match p.Kind with
            | PLiteral (LInt(42UL, _)) -> ()
            | other -> failtestf "expected PLiteral 42, got %A" other
        }

        test "string literal pattern" {
            let p = parseClean "\"hello\""
            match p.Kind with
            | PLiteral (LString "hello") -> ()
            | other -> failtestf "expected PLiteral hello, got %A" other
        }

        test "bool literal pattern" {
            let p = parseClean "true"
            match p.Kind with
            | PLiteral (LBool true) -> ()
            | other -> failtestf "expected PLiteral true, got %A" other
        }

        test "closed range pattern" {
            let p = parseClean "0 ..= 9"
            match p.Kind with
            | PRange(lo, true, hi) ->
                match lo.Kind, hi.Kind with
                | ELiteral (LInt(0UL, _)), ELiteral (LInt(9UL, _)) -> ()
                | l, h -> failtestf "bounds: %A / %A" l h
            | other -> failtestf "expected PRange, got %A" other
        }

        test "half-open range pattern" {
            let p = parseClean "0 ..< 10"
            match p.Kind with
            | PRange(_, false, _) -> ()
            | other -> failtestf "expected PRange half-open, got %A" other
        }

        // ----- bindings -----

        test "bare identifier is a binding" {
            let p = parseClean "x"
            match p.Kind with
            | PBinding("x", None) -> ()
            | other -> failtestf "expected PBinding x None, got %A" other
        }

        test "binding with @ inner pattern" {
            let p = parseClean "x @ 42"
            match p.Kind with
            | PBinding("x", Some inner) ->
                match inner.Kind with
                | PLiteral (LInt(42UL, _)) -> ()
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected PBinding x @ ..., got %A" other
        }

        // ----- constructors -----

        test "single-segment constructor with args" {
            let p = parseClean "Some(x)"
            match p.Kind with
            | PConstructor(head, [arg]) ->
                Expect.equal head.Segments ["Some"] "head"
                match arg.Kind with
                | PBinding("x", None) -> ()
                | other -> failtestf "arg: %A" other
            | other -> failtestf "expected PConstructor Some(x), got %A" other
        }

        test "multi-arg constructor" {
            let p = parseClean "Pair(a, b)"
            match p.Kind with
            | PConstructor(head, args) ->
                Expect.equal head.Segments ["Pair"] "head"
                Expect.equal args.Length 2 "two args"
            | other -> failtestf "expected PConstructor Pair, got %A" other
        }

        test "qualified payload-less constructor" {
            // `Color.Red` — multi-segment path with no args is a
            // payload-less constructor, not a binding.
            let p = parseClean "Color.Red"
            match p.Kind with
            | PConstructor(head, []) ->
                Expect.equal head.Segments ["Color"; "Red"] "qualified ctor"
            | other -> failtestf "expected payload-less PConstructor, got %A" other
        }

        // ----- record patterns -----

        test "record pattern with named and shorthand fields" {
            let p = parseClean "Point { x = 0, y }"
            match p.Kind with
            | PRecord(head, fields, ignoreRest) ->
                Expect.equal head.Segments ["Point"] "head"
                Expect.equal fields.Length 2 "two fields"
                Expect.isFalse ignoreRest "no .."
                match fields.[0] with
                | RPFNamed("x", _, _) -> ()
                | other -> failtestf "field 0: %A" other
                match fields.[1] with
                | RPFShort("y", _) -> ()
                | other -> failtestf "field 1: %A" other
            | other -> failtestf "expected PRecord, got %A" other
        }

        test "record pattern with .. ignore-rest" {
            let p = parseClean "Point { x = 0, .. }"
            match p.Kind with
            | PRecord(_, [_], true) -> ()
            | other -> failtestf "expected PRecord with ignoreRest, got %A" other
        }

        // ----- tuple, paren -----

        test "tuple pattern" {
            let p = parseClean "(a, b)"
            match p.Kind with
            | PTuple [a; b] ->
                match a.Kind, b.Kind with
                | PBinding("a", None), PBinding("b", None) -> ()
                | _ -> failtest "tuple shape"
            | other -> failtestf "expected PTuple, got %A" other
        }

        test "paren pattern" {
            let p = parseClean "(x)"
            match p.Kind with
            | PParen inner ->
                match inner.Kind with
                | PBinding("x", None) -> ()
                | other -> failtestf "inner: %A" other
            | other -> failtestf "expected PParen, got %A" other
        }

        test "unit tuple is a 0-tuple pattern" {
            let p = parseClean "()"
            match p.Kind with
            | PTuple [] -> ()
            | other -> failtestf "expected PTuple [], got %A" other
        }

        // ----- type test -----

        test "type-test postfix" {
            let p = parseClean "x is Int"
            match p.Kind with
            | PTypeTest(inner, ty) ->
                match inner.Kind with
                | PBinding("x", None) -> ()
                | other -> failtestf "inner: %A" other
                match ty.Kind with
                | TRef path -> Expect.equal path.Segments ["Int"] "type"
                | other -> failtestf "ty: %A" other
            | other -> failtestf "expected PTypeTest, got %A" other
        }

        // ----- or-pattern -----

        test "or-pattern with two alternatives" {
            let p = parseClean "1 | 2"
            match p.Kind with
            | POr [a; b] ->
                match a.Kind, b.Kind with
                | PLiteral (LInt(1UL, _)), PLiteral (LInt(2UL, _)) -> ()
                | _ -> failtest "or-pattern shape"
            | other -> failtestf "expected POr, got %A" other
        }

        test "or-pattern with three alternatives" {
            let p = parseClean "Red | Green | Blue"
            match p.Kind with
            | POr xs -> Expect.equal xs.Length 3 "three alternatives"
            | other -> failtestf "expected POr, got %A" other
        }

        // ----- combinations -----

        test "constructor pattern with nested binding inside or" {
            let p = parseClean "Some(x) | None"
            match p.Kind with
            | POr [_; _] -> ()
            | other -> failtestf "expected POr of two, got %A" other
        }

        test "tuple of bindings" {
            let p = parseClean "(a, b, c)"
            match p.Kind with
            | PTuple xs -> Expect.equal xs.Length 3 "three"
            | other -> failtestf "expected PTuple of 3, got %A" other
        }

        test "constructor with tuple-shaped record-like nesting" {
            let p = parseClean "Pair(Some(x), None)"
            match p.Kind with
            | PConstructor(_, [a; b]) ->
                match a.Kind with
                | PConstructor(_, [_]) -> ()
                | other -> failtestf "first arg: %A" other
                match b.Kind with
                | PBinding("None", None) -> ()
                | other -> failtestf "second arg: %A" other
            | other -> failtestf "expected PConstructor, got %A" other
        }

        // ----- errors -----

        test "garbage where a pattern is expected reports a diagnostic" {
            let _, diags = parsePatternFromString "{"
            Expect.isNonEmpty diags "expected diagnostic"
        }
    ]
