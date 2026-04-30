module Lyric.TypeChecker.Tests.ExprCheckerTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker
open Lyric.TypeChecker.ExprChecker

/// Infer the type of a single expression against an empty scope and
/// the package-level symbols / signatures from a checked source file.
let private inferIn (decls: string) (exprSrc: string) : Type * Diagnostic list =
    let parsed = parse ("package P\n" + decls)
    let r = check parsed.File
    let e, parseDiags = parseExprFromString exprSrc
    let scope = Scope()
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let t = inferExpr scope r.Symbols r.Signatures diags e
    t, List.ofSeq diags

/// Infer with no surrounding declarations.
let private inferOnly (exprSrc: string) =
    inferIn "" exprSrc

let tests =
    testList "T4 — expression type inference" [

        // ----- literals -----

        test "integer literal default Int" {
            let t, _ = inferOnly "42"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "integer literal with i64 suffix is Long" {
            let t, _ = inferOnly "100i64"
            Expect.equal t (TyPrim PtLong) "Long"
        }

        test "float literal default Double" {
            let t, _ = inferOnly "3.14"
            Expect.equal t (TyPrim PtDouble) "Double"
        }

        test "float with f32 is Float" {
            let t, _ = inferOnly "3.14f32"
            Expect.equal t (TyPrim PtFloat) "Float"
        }

        test "string / bool / unit literals" {
            let t1, _ = inferOnly "\"hello\""
            Expect.equal t1 (TyPrim PtString) "String"
            let t2, _ = inferOnly "true"
            Expect.equal t2 (TyPrim PtBool) "Bool"
            let t3, _ = inferOnly "()"
            Expect.equal t3 (TyPrim PtUnit) "Unit"
        }

        // ----- arithmetic / comparison / logical -----

        test "addition of two Ints" {
            let t, d = inferOnly "1 + 2"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "comparison returns Bool" {
            let t, d = inferOnly "1 < 2"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtBool) "Bool"
        }

        test "logical and returns Bool" {
            let t, d = inferOnly "true and false"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtBool) "Bool"
        }

        test "implies returns Bool" {
            let t, d = inferOnly "true implies false"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtBool) "Bool"
        }

        test "type mismatch in arithmetic reports T0031" {
            let _, d = inferOnly "1 + true"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0031" "type mismatch"
        }

        test "non-numeric arithmetic LHS reports T0030" {
            let _, d = inferOnly "true + false"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0030" "non-numeric"
        }

        test "comparison of incompatible types reports T0033" {
            let _, d = inferOnly "1 < true"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0033" "ordered mismatch"
        }

        test "logical operator with non-Bool reports T0034" {
            let _, d = inferOnly "1 and 2"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0034" "logical non-Bool"
        }

        // ----- prefix -----

        test "unary minus preserves numeric type" {
            let t, d = inferOnly "-5"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "not on Bool returns Bool" {
            let t, d = inferOnly "not true"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtBool) "Bool"
        }

        test "not on non-Bool reports T0037" {
            let _, d = inferOnly "not 1"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0037" "not on non-Bool"
        }

        // ----- tuples / lists -----

        test "tuple type" {
            let t, _ = inferOnly "(1, true)"
            Expect.equal t (TyTuple [TyPrim PtInt; TyPrim PtBool]) "tuple"
        }

        test "list literal of Ints" {
            let t, _ = inferOnly "[1, 2, 3]"
            Expect.equal t (TySlice (TyPrim PtInt)) "slice[Int]"
        }

        test "list with mismatched element types reports T0041" {
            let _, d = inferOnly "[1, true]"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0041" "heterogeneous list"
        }

        // ----- paths -----

        test "unknown name reports T0020" {
            let _, d = inferOnly "mystery"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0020" "unknown name"
        }

        test "function name resolves to its function type" {
            let decls = "pub func square(x: in Int): Int = x * x"
            let t, _ = inferIn decls "square"
            Expect.equal t
                (TyFunction([TyPrim PtInt], TyPrim PtInt, false))
                "fn type"
        }

        test "function call returns the declared return type" {
            let decls = "pub func square(x: in Int): Int = x * x"
            let t, d = inferIn decls "square(5)"
            Expect.isEmpty d "no diags"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "function call with wrong arg count reports T0042" {
            let decls = "pub func square(x: in Int): Int = x * x"
            let _, d = inferIn decls "square(1, 2)"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0042" "arg-count mismatch"
        }

        test "function call with wrong arg type reports T0043" {
            let decls = "pub func square(x: in Int): Int = x * x"
            let _, d = inferIn decls "square(true)"
            let codes = d |> List.map (fun x -> x.Code)
            Expect.contains codes "T0043" "arg-type mismatch"
        }

        // ----- member access -----

        test "field access on a record returns the field's type" {
            let decls = """
                pub record Point { x: Int, y: Int }
                pub func mkPoint(): Point = Point(x = 1, y = 2)
            """
            let t, _ = inferIn decls "mkPoint().x"
            Expect.equal t (TyPrim PtInt) "field type"
        }

        // ----- self -----

        test "self resolves to TySelf" {
            let t, _ = inferOnly "self"
            Expect.equal t TySelf "Self"
        }

        // ----- BCL member inference -----

        test "string.length resolves to Int without diagnostic" {
            let t, ds = inferOnly "\"hello\".length"
            Expect.equal t (TyPrim PtInt) ".length is Int"
            Expect.isFalse (ds |> List.exists (fun d -> d.Code = "T0040"))
                "no T0040 for string.length"
        }

        test "string.isEmpty resolves to Bool" {
            let t, _ = inferOnly "\"hi\".isEmpty"
            Expect.equal t (TyPrim PtBool) ".isEmpty is Bool"
        }

        test "slice[Int].length resolves to Int" {
            let decls = "pub func ones(xs: in slice[Int]): Int = xs.length"
            let r =
                let parsed = parse ("package P\n" + decls)
                check parsed.File
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.isFalse (List.contains "T0040" codes)
                "slice.length must not raise T0040"
        }

        test "string.unknownMember does not raise T0040" {
            // BCL methods aren't fully enumerated in the type
            // checker; codegen takes the precise dispatch.  The
            // checker silently returns TyError instead of falsely
            // asserting the member doesn't exist.
            let _, ds = inferOnly "\"x\".trim"
            Expect.isFalse (ds |> List.exists (fun d -> d.Code = "T0040"))
                "no T0040 — codegen handles dispatch"
        }
    ]
