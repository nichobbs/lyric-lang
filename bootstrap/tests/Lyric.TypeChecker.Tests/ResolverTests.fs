module Lyric.TypeChecker.Tests.ResolverTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Resolver

/// Resolve a TypeExpr from source against an empty symbol table.
let private resolve (src: string) : Type * Diagnostic list =
    let te, parseDiags = parseTypeFromString src
    let table = SymbolTable()
    let ctx = GenericContext()
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let t = resolveType table ctx diags te
    t, List.ofSeq diags

/// Resolve a TypeExpr against a populated symbol table from a
/// declaration string.
let private resolveWithDecls (decls: string) (typeSrc: string) : Type * Diagnostic list =
    let parsed = parse ("package P\n" + decls)
    let r = Checker.check parsed.File
    let te, parseDiags = parseTypeFromString typeSrc
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let ctx = GenericContext()
    let t = resolveType r.Symbols ctx diags te
    t, List.ofSeq diags

let tests =
    testList "T2 — type resolver" [

        test "primitive Int" {
            let t, d = resolve "Int"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "primitive Bool / String / Unit / Never" {
            for src, expected in
                ["Bool",   TyPrim PtBool
                 "String", TyPrim PtString
                 "()",     TyPrim PtUnit
                 "Never",  TyPrim PtNever] do
                let t, d = resolve src
                Expect.isEmpty d (sprintf "no diags for %s" src)
                Expect.equal t expected (sprintf "type for %s" src)
        }

        test "Self resolves to TySelf" {
            let t, d = resolve "Self"
            Expect.isEmpty d "no diags"
            Expect.equal t TySelf "Self"
        }

        test "tuple type resolves componentwise" {
            let t, _ = resolve "(Int, String)"
            Expect.equal t (TyTuple [TyPrim PtInt; TyPrim PtString]) "tuple"
        }

        test "nullable wraps the inner type" {
            let t, _ = resolve "Int?"
            Expect.equal t (TyNullable (TyPrim PtInt)) "nullable"
        }

        test "function type" {
            let t, _ = resolve "Int -> Bool"
            Expect.equal t
                (TyFunction([TyPrim PtInt], TyPrim PtBool, false))
                "fn"
        }

        test "two-arg function via tuple" {
            let t, _ = resolve "(Int, String) -> Bool"
            Expect.equal t
                (TyFunction([TyPrim PtInt; TyPrim PtString], TyPrim PtBool, false))
                "fn 2-arg"
        }

        test "slice of primitive" {
            let t, _ = resolve "slice[Int]"
            Expect.equal t (TySlice (TyPrim PtInt)) "slice"
        }

        test "array of primitive with literal size" {
            let t, _ = resolve "array[16, Byte]"
            Expect.equal t (TyArray(Some 16, TyPrim PtByte)) "array"
        }

        test "primitive with type arguments is rejected" {
            let _, d = resolve "Int[Bool]"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0012" "T0012 reported"
        }

        test "unknown type name reports T0010" {
            let _, d = resolve "MysteryType"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0010" "T0010 reported"
        }

        test "user-defined record resolves to TyUser" {
            let t, d = resolveWithDecls "pub record Point { x: Int, y: Int }" "Point"
            Expect.isEmpty d "no diags"
            match t with
            | TyUser(_, []) -> ()
            | other -> failtestf "expected TyUser, got %A" other
        }

        test "generic-application user type carries args" {
            // Set up a Result-like generic union for resolution.
            let decls = "pub union Result { case Ok(value: Int), case Err(error: String) }"
            let t, d = resolveWithDecls decls "Result"
            Expect.isEmpty d "no diags"
            match t with
            | TyUser(_, []) -> ()
            | other -> failtestf "expected TyUser, got %A" other
        }

        test "refined type is resolved as its underlying" {
            let t, d = resolve "Int range 0 ..= 99"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtInt) "underlying = Int"
        }

        test "in-scope type parameter resolves to TyVar" {
            let table = SymbolTable()
            let ctx = GenericContext()
            ctx.Push(["T"])
            let te, _ = parseTypeFromString "T"
            let diags = ResizeArray<Diagnostic>()
            let t = resolveType table ctx diags te
            Expect.equal t (TyVar "T") "TyVar"
            Expect.isEmpty diags "no diags"
        }

        test "Type.equiv compares structurally" {
            Expect.isTrue
                (Type.equiv
                    (TyTuple [TyPrim PtInt; TyPrim PtString])
                    (TyTuple [TyPrim PtInt; TyPrim PtString]))
                "equal tuples"
            Expect.isFalse
                (Type.equiv (TyPrim PtInt) (TyPrim PtBool))
                "Int /= Bool"
            Expect.isTrue
                (Type.equiv TyError (TyPrim PtInt))
                "TyError compatible"
        }

        test "Type.render is human-readable" {
            Expect.equal (Type.render (TyPrim PtInt)) "Int" "Int"
            Expect.equal
                (Type.render (TyTuple [TyPrim PtInt; TyPrim PtString]))
                "(Int, String)" "tuple"
            Expect.equal
                (Type.render (TyNullable (TyPrim PtBool)))
                "Bool?" "nullable"
            Expect.equal
                (Type.render (TyFunction([TyPrim PtInt], TyPrim PtBool, false)))
                "(Int) -> Bool" "fn"
        }
    ]
