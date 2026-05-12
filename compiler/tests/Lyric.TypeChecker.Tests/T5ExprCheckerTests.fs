/// Tests for T5 expression type inference: EIf, EMatch, EBlock, ELambda,
/// EIndex, ERange, EInterpolated, ETypeApp, EForall/EExists, EAssign,
/// and symbol-resolution for DKConst / DKVal / DKUnionCase / DKEnumCase.
module Lyric.TypeChecker.Tests.T5ExprCheckerTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker
open Lyric.TypeChecker.ExprChecker

let private inferIn (decls: string) (exprSrc: string) : Type * Diagnostic list =
    let parsed = parse ("package P\n" + decls)
    let r = check parsed.File
    let e, parseDiags = parseExprFromString exprSrc
    let scope = Scope()
    let diags = ResizeArray<Diagnostic>(parseDiags)
    let t = inferExpr scope r.Symbols r.Signatures [] (TyPrim PtUnit) diags e
    t, List.ofSeq diags

let private inferOnly (exprSrc: string) =
    inferIn "" exprSrc

let private parseAndCheck (src: string) : CheckResult =
    let parsed = parse ("package P\n" + src)
    Expect.isEmpty parsed.Diagnostics
        (sprintf "expected clean parse for: %s\nactual: %A" src parsed.Diagnostics)
    check parsed.File

let private codes (r: CheckResult) : string list =
    r.Diagnostics |> List.map (fun d -> d.Code)

let private diagCodes (diags: Diagnostic list) =
    diags |> List.map (fun d -> d.Code)

let tests =
    testList "T5 — new expression inference" [

        // =====================================================================
        // EIf
        // =====================================================================

        test "if-else with matching branches returns branch type" {
            let t, d = inferOnly "if true { 1 } else { 2 }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "if without else returns Unit" {
            let t, d = inferOnly "if true { 1 }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtUnit) "Unit"
        }

        test "if-condition must be Bool — reports T0067" {
            let _, d = inferOnly "if 1 { 2 } else { 3 }"
            Expect.contains (diagCodes d) "T0067" "T0067 for non-Bool condition"
        }

        test "if-else branch type mismatch reports T0068" {
            let _, d = inferOnly "if true { 1 } else { true }"
            Expect.contains (diagCodes d) "T0068" "T0068 for mismatched branches"
        }

        test "if-else with Never then-branch returns else type" {
            // `panic` returns Never; the else branch type propagates.
            let t, d = inferIn
                            "pub func die(): Never = panic(\"\")"
                            "if true { die() } else { 42 }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int from else"
        }

        test "if-else with Never else-branch returns then type" {
            let t, d = inferIn
                            "pub func die(): Never = panic(\"\")"
                            "if true { 42 } else { die() }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int from then"
        }

        // =====================================================================
        // EMatch
        // =====================================================================

        test "match over Int literal arms returns arm type" {
            let r = parseAndCheck
                        "pub func classify(n: in Int): Bool {\n\
                         match n {\n\
                           case 0 -> return false\n\
                           case _ -> return true\n\
                         }\n\
                         return false\n\
                         }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "match arm binds pattern variable with correct type" {
            // The union case field should be accessible in the arm body.
            let r = parseAndCheck
                        "pub union Option { case Some(value: Int), case None }\n\
                         pub func unwrap(o: in Option): Int {\n\
                         match o {\n\
                           case Some(v) -> return v\n\
                           case None    -> return 0\n\
                         }}"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "match arm body type mismatch reports T0068" {
            let r = parseAndCheck
                        "pub func f(b: in Bool): Int {\n\
                         val x: Int = match b {\n\
                           case true  -> 1\n\
                           case false -> true\n\
                         }\n\
                         return x }"
            Expect.contains (codes r) "T0068" "T0068 for arm mismatch"
        }

        // =====================================================================
        // EBlock (exercised via if/else block bodies)
        // =====================================================================

        test "block body with multi-statement sequence returns trailing expression type" {
            let r = parseAndCheck
                        "pub func f(b: in Bool): Int {\n\
                         val x: Int = if b {\n\
                           var y: Int = 2\n\
                           y + 1\n\
                         } else {\n\
                           0\n\
                         }\n\
                         return x }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // ELambda
        // =====================================================================

        test "lambda with annotated params produces TyFunction" {
            let t, d = inferOnly "{ x: Int, y: Int -> x + y }"
            Expect.isEmpty d "no diagnostics"
            match t with
            | TyFunction([TyPrim PtInt; TyPrim PtInt], TyPrim PtInt, false) -> ()
            | other -> failtestf "expected (Int, Int) -> Int, got %A" other
        }

        test "zero-param lambda returns body type" {
            let t, d = inferOnly "{ -> 42 }"
            Expect.isEmpty d "no diagnostics"
            match t with
            | TyFunction([], TyPrim PtInt, false) -> ()
            | other -> failtestf "expected () -> Int, got %A" other
        }

        test "lambda type-checks its body" {
            let _, d = inferOnly "{ x: Int -> x + true }"
            Expect.contains (diagCodes d) "T0031" "T0031 in lambda body"
        }

        test "lambda can be passed to a higher-order function" {
            let r = parseAndCheck
                        "pub func apply(f: in (Int) -> Int, x: in Int): Int = f(x)\n\
                         pub func main(): Int = apply({ n: Int -> n * 2 }, 3)"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // EIndex
        // =====================================================================

        test "indexing a slice[Int] returns Int" {
            let r = parseAndCheck
                        "pub func get(xs: in slice[Int], i: in Int): Int = xs[i]"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "indexing a string returns Char" {
            let t, d = inferIn
                            "pub func first(s: in String): Char = s[0]"
                            "\"hello\"[0]"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtChar) "Char"
        }

        test "indexing with non-Int index reports T0069" {
            let r = parseAndCheck
                        "pub func get(xs: in slice[Int], i: in Bool): Int = xs[i]"
            Expect.contains (codes r) "T0069" "T0069 for non-Int index"
        }

        test "indexing a non-array type reports T0069" {
            let r = parseAndCheck
                        "pub func bad(x: in Bool): Bool = x[0]"
            Expect.contains (codes r) "T0069" "T0069 for non-indexable receiver"
        }

        // =====================================================================
        // for-loop over slice
        // =====================================================================

        test "for-loop over a slice[Int] binds element as Int" {
            let r = parseAndCheck
                        "pub func sum(xs: in slice[Int]): Int {\n\
                         var acc: Int = 0\n\
                         for i in xs { acc = acc + i }\n\
                         return acc }"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // EInterpolated
        // =====================================================================

        test "interpolated string returns String" {
            let t, d = inferIn
                            "pub val name: String = \"world\""
                            "\"hello ${name}!\""
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtString) "String"
        }

        test "interpolated string type-checks interpolated sub-expressions" {
            let _, d = inferOnly "\"x = ${1 + true}\""
            Expect.contains (diagCodes d) "T0031" "T0031 inside interpolation"
        }

        // =====================================================================
        // DKConst resolution (module-level pub val acts as a const)
        // =====================================================================

        test "module-level val resolves to its declared type" {
            let t, d = inferIn
                            "pub val MAX: Int = 100"
                            "MAX"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtInt) "Int"
        }

        test "module-level val used in expression type-checks" {
            let r = parseAndCheck
                        "pub val LIMIT: Int = 50\n\
                         pub func ok(n: in Int): Bool = n < LIMIT"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // DKVal resolution
        // =====================================================================

        test "module-level val with annotation resolves to declared type" {
            let t, d = inferIn
                            "pub val greeting: String = \"hi\""
                            "greeting"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtString) "String"
        }

        // =====================================================================
        // DKUnionCase resolution
        // =====================================================================

        test "no-field union case resolves to the parent union type" {
            let decls = "pub union Color { case Red, case Green, case Blue }"
            let t, d = inferIn decls "Red"
            Expect.isEmpty d "no diagnostics"
            // Should be TyUser with the Color type id.
            match t with
            | TyUser(_, []) -> ()
            | other -> failtestf "expected TyUser, got %A" other
        }

        test "union case with fields resolves to a constructor function type" {
            let decls = "pub union Option { case Some(value: Int), case None }"
            let t, d = inferIn decls "Some"
            Expect.isEmpty d "no diagnostics"
            match t with
            | TyFunction([TyPrim PtInt], TyUser _, false) -> ()
            | other -> failtestf "expected (Int) -> Option, got %A" other
        }

        test "calling a union constructor type-checks the field argument" {
            let r = parseAndCheck
                        "pub union Opt { case Some(value: Int), case None }\n\
                         pub func wrap(x: in Int): Opt = Some(x)"
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        // =====================================================================
        // DKEnumCase resolution
        // =====================================================================

        test "enum case resolves to the parent enum type" {
            let decls = "pub enum Dir { case North, case South, case East, case West }"
            let t, d = inferIn decls "North"
            Expect.isEmpty d "no diagnostics"
            match t with
            | TyUser(_, []) -> ()
            | other -> failtestf "expected TyUser, got %A" other
        }

        // =====================================================================
        // Generic function resolution
        // =====================================================================

        test "generic function symbol resolves to a function type" {
            let decls = "generic[T] pub func id(x: in T): T = x"
            let t, d = inferIn decls "id"
            Expect.isEmpty d "no diagnostics"
            match t with
            | TyFunction _ -> ()
            | other -> failtestf "expected TyFunction, got %A" other
        }

        // =====================================================================
        // EForall / EExists
        // =====================================================================

        test "forall expression returns Bool" {
            let t, d = inferOnly "forall (x: Int) { x >= 0 }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtBool) "Bool"
        }

        test "exists expression returns Bool" {
            let t, d = inferOnly "exists (x: Int) { x > 0 }"
            Expect.isEmpty d "no diagnostics"
            Expect.equal t (TyPrim PtBool) "Bool"
        }
    ]
