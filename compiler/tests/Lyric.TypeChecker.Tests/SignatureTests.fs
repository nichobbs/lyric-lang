module Lyric.TypeChecker.Tests.SignatureTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser
open Lyric.TypeChecker
open Lyric.TypeChecker.Checker

let private parseAndCheck (src: string) : CheckResult =
    let parsed = parse ("package P\n" + src)
    Expect.isEmpty parsed.Diagnostics
        (sprintf "expected clean parse for: %s\nactual: %A" src parsed.Diagnostics)
    check parsed.File

let private sigOf (r: CheckResult) (name: string) : ResolvedSignature =
    match Map.tryFind name r.Signatures with
    | Some s -> s
    | None   -> failtestf "expected signature for '%s'" name

let tests =
    testList "T3 — function signature resolution" [

        test "simple function: parameter and return types resolve" {
            let r = parseAndCheck "pub func square(x: in Int): Int = x * x"
            let s = sigOf r "square"
            Expect.equal s.Generics [] "no generics"
            Expect.equal s.Params.Length 1 "one param"
            Expect.equal s.Params.[0].Name "x" "param name"
            Expect.equal s.Params.[0].Mode PMIn "param mode"
            Expect.equal s.Params.[0].Type (TyPrim PtInt) "param type"
            Expect.equal s.Return (TyPrim PtInt) "return type"
            Expect.isFalse s.IsAsync "not async"
        }

        test "function with no return type defaults to Unit" {
            let r = parseAndCheck "func sideEffect(x: in Int) = ()"
            let s = sigOf r "sideEffect"
            Expect.equal s.Return (TyPrim PtUnit) "Unit return"
        }

        test "async function flag is preserved" {
            let r = parseAndCheck "pub async func loadUser(id: in Long): Int = 0"
            let s = sigOf r "loadUser"
            Expect.isTrue s.IsAsync "async"
        }

        test "generic function records generic parameter names" {
            let r = parseAndCheck "generic[T] pub func identity(x: in T): T = x"
            let s = sigOf r "identity"
            Expect.equal s.Generics ["T"] "T in generics"
            Expect.equal s.Params.[0].Type (TyVar "T") "param: TyVar T"
            Expect.equal s.Return (TyVar "T") "return: TyVar T"
        }

        test "multi-arg function with mixed primitive and tuple" {
            let r = parseAndCheck
                        "func minMax(xs: in slice[Int]): (Int, Int) = (0, 0)"
            let s = sigOf r "minMax"
            Expect.equal s.Params.[0].Type (TySlice (TyPrim PtInt)) "param"
            Expect.equal s.Return (TyTuple [TyPrim PtInt; TyPrim PtInt]) "tuple return"
        }

        test "function referencing a record type from the same package" {
            let src = """
                pub record Point { x: Int, y: Int }
                pub func makePoint(x: in Int, y: in Int): Point = Point(x = x, y = y)
            """
            let r = parseAndCheck src
            let s = sigOf r "makePoint"
            match s.Return with
            | TyUser(_, []) -> ()
            | other -> failtestf "return: %A" other
        }

        test "function with inout parameter mode" {
            let r = parseAndCheck "func incAll(xs: inout slice[Int]) = ()"
            let s = sigOf r "incAll"
            Expect.equal s.Params.[0].Mode PMInout "inout"
        }

        test "function with default-value parameter records the flag" {
            let r = parseAndCheck "func greet(name: in String = \"world\"): Unit = ()"
            let s = sigOf r "greet"
            Expect.isTrue s.Params.[0].Default "default present"
        }

        test "unknown type in parameter triggers T0010" {
            let parsed = parse "package P\nfunc f(x: in MysteryType): Int = 0"
            let r = check parsed.File
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "T0010" "T0010 reported"
        }

        test "every function in the file gets a signature entry" {
            let src = """
                pub func a(): Int = 1
                pub func b(): String = "hi"
                pub func c(): Bool = true
            """
            let r = parseAndCheck src
            Expect.equal r.Signatures.Count 3 "three signatures"
            for n in ["a"; "b"; "c"] do
                Expect.isTrue (r.Signatures.ContainsKey n) (sprintf "%s present" n)
        }

        test "where clause referencing unknown type parameter triggers T0050" {
            let parsed =
                parse "package P\ngeneric[T] func f(x: in T): T where U: Compare = x"
            let r = check parsed.File
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "T0050" "T0050 reported"
        }

        test "where clause with unknown constraint triggers T0051" {
            let parsed =
                parse "package P\ngeneric[T] func f(x: in T): T where T: Wibble = x"
            let r = check parsed.File
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "T0051" "T0051 reported"
        }

        test "where clause with valid derive marker is accepted" {
            let parsed =
                parse "package P\ngeneric[T] func f(x: in T): T where T: Compare = x"
            let r = check parsed.File
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.isFalse (List.contains "T0050" codes) "no T0050"
            Expect.isFalse (List.contains "T0051" codes) "no T0051"
        }
    ]
