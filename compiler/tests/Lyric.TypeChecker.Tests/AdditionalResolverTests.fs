module Lyric.TypeChecker.Tests.AdditionalResolverTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Resolver

/// Resolve a TypeExpr against a populated symbol table from a
/// declaration block.
let private resolveWithDecls
        (decls: string)
        (typeSrc: string)
        : Type * Diagnostic list =
    let parsed = parse ("package P\n" + decls)
    let r = Checker.check parsed.File
    let te, parseDiags = parseTypeFromString typeSrc
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let ctx = GenericContext()
    let t = resolveType r.Symbols ctx diags te
    t, List.ofSeq diags

let private resolveAlone (src: string) : Type * Diagnostic list =
    let te, parseDiags = parseTypeFromString src
    let table = SymbolTable()
    let ctx = GenericContext()
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let t = resolveType table ctx diags te
    t, List.ofSeq diags

let private codes (diags: Diagnostic list) =
    diags |> List.map (fun d -> d.Code)

let tests =
    testList "T2 — additional resolver checks" [

        test "name of a function used as a type reports T0013" {
            let _, d =
                resolveWithDecls
                    "pub func myFunc(): Int = 0"
                    "myFunc"
            Expect.contains (codes d) "T0013" "T0013 reported"
        }

        test "qualified non-primitive type name reports T0014" {
            // `Std.Collections.MapImpl` (or any qualified non-primitive
            // trailing segment) isn't yet resolved cross-package; the
            // resolver flags it with T0014.
            let _, d = resolveAlone "Foo.Bar"
            Expect.contains (codes d) "T0014" "T0014 reported"
        }

        test "qualified primitive trailing segment is admitted as the primitive" {
            let t, d = resolveAlone "std.core.Int"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtInt) "qualified primitive ⇒ Int"
        }

        test "qualified primitive with type-args reports T0012" {
            let _, d = resolveAlone "std.core.Int[Bool]"
            Expect.contains (codes d) "T0012" "T0012 reported"
        }

        test "self-resolving primitive: every PtX has a string spelling" {
            for name, expected in
                [ "Byte",   TyPrim PtByte
                  "Int",    TyPrim PtInt
                  "Long",   TyPrim PtLong
                  "UInt",   TyPrim PtUInt
                  "ULong",  TyPrim PtULong
                  "Float",  TyPrim PtFloat
                  "Double", TyPrim PtDouble
                  "String", TyPrim PtString
                  "Bool",   TyPrim PtBool
                  "Char",   TyPrim PtChar ] do
                let t, d = resolveAlone name
                Expect.isEmpty d (sprintf "no diags for %s" name)
                Expect.equal t expected (sprintf "%s resolves" name)
        }

        test "TyError equiv to anything (poisoning)" {
            Expect.isTrue
                (Type.equiv TyError (TyTuple [TyPrim PtInt]))
                "TyError equiv tuple"
            Expect.isTrue
                (Type.equiv (TyPrim PtInt) TyError)
                "PtInt equiv TyError"
        }

        test "Type.render for slice / function / nullable" {
            Expect.equal (Type.render (TySlice (TyPrim PtInt))) "slice[Int]" "slice"
            Expect.equal
                (Type.render (TyNullable (TySlice (TyPrim PtString))))
                "slice[String]?" "nullable slice"
            Expect.equal
                (Type.render (TyFunction([], TyPrim PtInt, false)))
                "() -> Int" "no-arg fn"
            Expect.equal
                (Type.render (TyFunction([TyPrim PtInt; TyPrim PtBool], TyPrim PtUnit, true)))
                "async (Int, Bool) -> Unit" "async fn"
        }
    ]
