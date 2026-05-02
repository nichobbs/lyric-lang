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

        test "Type.render for tuples and arrays" {
            Expect.equal
                (Type.render (TyTuple [TyPrim PtInt; TyPrim PtBool]))
                "(Int, Bool)" "binary tuple"
            Expect.equal
                (Type.render (TyTuple []))
                "()" "empty tuple"
            Expect.equal
                (Type.render (TyArray(Some 4, TyPrim PtChar)))
                "array[4, Char]" "fixed-size array"
            Expect.equal
                (Type.render (TyArray(None, TyPrim PtByte)))
                "array[?, Byte]" "size-elided array"
        }

        test "Type.render for self / type variables / error" {
            Expect.equal (Type.render TySelf) "Self" "Self"
            Expect.equal (Type.render (TyVar "T")) "T" "TyVar"
            Expect.equal (Type.render TyError) "<error>" "TyError"
        }

        test "Type.equiv on tuples and arrays" {
            Expect.isTrue
                (Type.equiv
                    (TyTuple [TyPrim PtInt; TyPrim PtBool])
                    (TyTuple [TyPrim PtInt; TyPrim PtBool]))
                "tuples of same shape are equiv"
            Expect.isFalse
                (Type.equiv
                    (TyTuple [TyPrim PtInt])
                    (TyTuple [TyPrim PtInt; TyPrim PtBool]))
                "tuples of different arity are not equiv"
            Expect.isTrue
                (Type.equiv
                    (TyArray(Some 3, TyPrim PtInt))
                    (TyArray(Some 3, TyPrim PtInt)))
                "arrays of same size+element are equiv"
            Expect.isFalse
                (Type.equiv
                    (TyArray(Some 3, TyPrim PtInt))
                    (TyArray(Some 4, TyPrim PtInt)))
                "arrays of different sizes are not equiv"
        }

        test "Type.equiv: TyVar matches anything (no real unification yet)" {
            Expect.isTrue
                (Type.equiv (TyVar "T") (TyPrim PtInt))
                "TyVar T equiv Int (treated like TyError)"
            Expect.isTrue
                (Type.equiv (TyVar "A") (TyVar "B"))
                "TyVar A equiv TyVar B"
        }

        test "Type.primFromString round-trip" {
            for p in
                [ PtBool; PtByte; PtInt; PtLong
                  PtUInt; PtULong; PtNat; PtFloat
                  PtDouble; PtChar; PtString; PtUnit; PtNever ] do
                let s = Type.primName p
                let back = Type.primFromString s
                Expect.equal back (Some p) (sprintf "%s round-trips" s)
            Expect.isNone (Type.primFromString "NotAPrim")
                "unknown name returns None"
        }
    ]
