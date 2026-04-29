module Lyric.Parser.Tests.FunctionDeclTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseClean (src: string) =
    let r = parse (prelude + src)
    Expect.isEmpty r.Diagnostics
        (sprintf "expected no diagnostics for: %s\nactual: %A" src r.Diagnostics)
    r.File

let private getOnlyFunc (file: SourceFile) : FunctionDecl =
    Expect.equal file.Items.Length 1 "exactly one item"
    match file.Items.[0].Kind with
    | IFunc fn -> fn
    | other -> failtestf "expected IFunc, got %A" other

let tests =
    testList "function declarations (P6a)" [

        // ----- the simplest function -----

        test "expression-bodied function with one in-param" {
            let f = parseClean "pub func square(x: in Int): Int = x * x"
            let fn = getOnlyFunc f
            Expect.equal fn.Name "square" "name"
            Expect.equal fn.Params.Length 1 "one param"
            Expect.equal fn.Params.[0].Name "x" "param name"
            Expect.equal fn.Params.[0].Mode PMIn "param mode"
            Expect.isFalse fn.IsAsync "not async"
            match fn.Body with
            | Some (FBExpr _) -> ()
            | other -> failtestf "expected FBExpr body, got %A" other
        }

        test "function with explicit return type and contracts" {
            let f =
                parseClean
                    "func balanceOf(account: in Account): Cents requires: account != null ensures: result == account.balance = account.balance"
            let fn = getOnlyFunc f
            Expect.equal fn.Contracts.Length 2 "requires + ensures"
            match fn.Contracts.[0] with
            | CCRequires(_, _) -> ()
            | other -> failtestf "first clause: %A" other
            match fn.Contracts.[1] with
            | CCEnsures(_, _) -> ()
            | other -> failtestf "second clause: %A" other
        }

        test "function with multiple parameters of mixed modes" {
            let f =
                parseClean
                    "func divmod(n: in Int, d: in Int, q: out Int, r: out Int) = ()"
            let fn = getOnlyFunc f
            Expect.equal fn.Params.Length 4 "four params"
            Expect.equal fn.Params.[0].Mode PMIn "param 0 mode"
            Expect.equal fn.Params.[2].Mode PMOut "param 2 mode"
        }

        test "inout parameter mode" {
            let f =
                parseClean
                    "func incrementAll(xs: inout slice[Int]) = ()"
            let fn = getOnlyFunc f
            Expect.equal fn.Params.[0].Mode PMInout "inout"
            match fn.Params.[0].Type.Kind with
            | TSlice _ -> ()
            | other -> failtestf "param type: %A" other
        }

        test "async function" {
            let f =
                parseClean "pub async func loadUser(id: in Long): User = user"
            let fn = getOnlyFunc f
            Expect.isTrue fn.IsAsync "async"
            Expect.equal fn.Name "loadUser" "name"
        }

        // ----- generics + where -----

        test "generic function with constraints" {
            let f =
                parseClean
                    "generic[T] pub func identity(x: in T): T = x"
            let fn = getOnlyFunc f
            Expect.isSome fn.Generics "generics"
            Expect.equal fn.Name "identity" "name"
        }

        test "generic function with where clause" {
            let f =
                parseClean
                    "generic[T] pub func sum(xs: in slice[T]): T where T: Add = T.default"
            let fn = getOnlyFunc f
            Expect.isSome fn.Where "where present"
        }

        // ----- block body (placeholder) -----

        test "block-bodied function parses statements" {
            let f =
                parseClean
                    "func main(): Int { return 0 }"
            let fn = getOnlyFunc f
            match fn.Body with
            | Some (FBBlock blk) ->
                Expect.equal blk.Statements.Length 1 "one statement"
                match blk.Statements.[0].Kind with
                | SReturn (Some _) -> ()
                | other -> failtestf "expected SReturn, got %A" other
            | other -> failtestf "expected FBBlock, got %A" other
        }

        test "function with no return type defaults to None (Unit)" {
            let f = parseClean "func sideEffect(x: in Int) = ()"
            let fn = getOnlyFunc f
            Expect.isNone fn.Return "no explicit return type"
        }

        test "function with default parameter value" {
            let f =
                parseClean
                    "func greet(name: in String = \"world\"): Unit = ()"
            let fn = getOnlyFunc f
            Expect.isSome fn.Params.[0].Default "default present"
        }

        // ----- diagnostic paths -----

        test "missing parameter mode reports P0160" {
            let r = parse (prelude + "func f(x: Int): Int = x")
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0160" "P0160 reported"
        }

        test "function without body parses (signature-only)" {
            // Used inside interface declarations; the parser admits a
            // bodyless function head at the top level too, though
            // semantically incorrect. The body slot is None.
            let f = parseClean "func sigOnly(x: in Int): Int"
            let fn = getOnlyFunc f
            Expect.isNone fn.Body "no body"
        }
    ]
