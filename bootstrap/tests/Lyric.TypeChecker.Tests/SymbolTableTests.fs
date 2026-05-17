module Lyric.TypeChecker.Tests.SymbolTableTests

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

let private symNames (r: CheckResult) : string list =
    r.Symbols.All() |> Seq.map (fun s -> s.Name) |> Seq.toList |> List.sort

let tests =
    testList "T1 — symbol table" [

        test "every type-shaped item registers a single symbol" {
            let src =
                """
                pub record Point { x: Int, y: Int }
                pub union Shape { case Circle(r: Double), case Square(side: Double) }
                pub enum Color { case Red, case Green }
                pub opaque type AccountId
                pub type UserId = Long
                alias Distance = Long
                """
            let r = parseAndCheck src
            Expect.isEmpty r.Diagnostics "no diagnostics"
            // Type-shaped items + variant cases of Shape and Color.
            // Shape has 2 cases, Color has 2 cases.
            let names = symNames r
            Expect.contains names "Point"      "Point"
            Expect.contains names "Shape"      "Shape"
            Expect.contains names "Circle"     "Circle case"
            Expect.contains names "Square"     "Square case"
            Expect.contains names "Color"      "Color"
            Expect.contains names "Red"        "Red case"
            Expect.contains names "Green"      "Green case"
            Expect.contains names "AccountId"  "AccountId"
            Expect.contains names "UserId"     "UserId"
            Expect.contains names "Distance"   "Distance"
        }

        test "duplicate type name is reported as T0001" {
            let src =
                """
                pub record A { x: Int }
                pub record A { y: Int }
                """
            let r = (parse ("package P\n" + src)).File |> check
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "T0001" "duplicate-name diagnostic"
        }

        test "duplicate value name is reported as T0001" {
            let src =
                """
                pub func foo(): Int = 1
                pub func foo(): Int = 2
                """
            let r = (parse ("package P\n" + src)).File |> check
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "T0001" "duplicate-name diagnostic"
        }

        test "type and value sharing a name do not collide" {
            // A record `Foo` and a value `foo` are in different name
            // classes — both are admissible in the same package.
            let src =
                """
                pub record Foo { x: Int }
                pub func foo(): Int = 1
                """
            let r = parseAndCheck src
            Expect.isEmpty r.Diagnostics "no collision"
        }

        test "function symbol is recorded with DKFunc" {
            let src = "pub func g(x: in Int): Int = x"
            let r = parseAndCheck src
            match r.Symbols.TryFindOne("g") with
            | Some { Kind = DKFunc _ } -> ()
            | other -> failtestf "expected DKFunc symbol for g, got %A" other
        }

        test "union case is recorded with DKUnionCase" {
            let src = "pub union U { case A, case B(x: Int) }"
            let r = parseAndCheck src
            match r.Symbols.TryFindOne("A") with
            | Some { Kind = DKUnionCase(_, _) } -> ()
            | other -> failtestf "expected DKUnionCase for A, got %A" other
        }

        test "type symbols expose a TypeId" {
            let src = "pub record P { x: Int }"
            let r = parseAndCheck src
            let p = r.Symbols.TryFindOne("P") |> Option.get
            match Symbol.typeIdOpt p with
            | Some (TypeId id) -> Expect.isGreaterThan id 0 "TypeId allocated"
            | None -> failtest "expected typeId on P"
        }

        test "every distinct type gets a fresh TypeId" {
            let src =
                """
                pub record A { x: Int }
                pub record B { y: Int }
                pub record C { z: Int }
                """
            let r = parseAndCheck src
            let ids =
                ["A"; "B"; "C"]
                |> List.choose (fun name ->
                    r.Symbols.TryFindOne(name) |> Option.bind Symbol.typeIdOpt)
            Expect.equal ids.Length 3 "three TypeIds"
            Expect.equal (ids |> List.distinct |> List.length) 3 "all distinct"
        }

        // ----- D046 config blocks -----

        test "config block registers a symbol" {
            let src = """config Settings { port: Int = 8080 }"""
            let r = parseAndCheck src
            Expect.isEmpty r.Diagnostics "no diagnostics on minimal config"
            Expect.isSome (r.Symbols.TryFindOne("Settings"))
                "Settings symbol registered"
        }

        test "config field disallowed type triggers G0009" {
            let src = """config Settings { weight: Double = 1.0 }"""
            let r = (parse ("package P\n" + src)).File |> check
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "G0009"
                "Double rejected (allow-list is Bool/Int/String in v1)"
        }

        test "config field with composite type rejected" {
            let src = """config Settings { items: List[String] = [] }"""
            let r = (parse ("package P\n" + src)).File |> check
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "G0009" "List[String] rejected in v1"
        }

        test "config field name duplicate triggers G0013" {
            let src = """config Settings {
                port: Int = 8080
                port: Int = 9090
            }"""
            let r = (parse ("package P\n" + src)).File |> check
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "G0013" "duplicate field name"
        }

        test "Bool / Int / String all accepted" {
            let src = """config Settings {
                debug: Bool = false
                port:  Int = 8080
                host:  String = "0.0.0.0"
            }"""
            let r = parseAndCheck src
            Expect.isEmpty r.Diagnostics "all v1 types accepted"
        }

        // ----- D047 aspect blocks -----

        test "aspect block registers a symbol" {
            let src = """aspect Logging {
                matches: name like "handle*"
                around(args) -> ret { proceed(args) }
            }"""
            let r = parseAndCheck src
            Expect.isSome (r.Symbols.TryFindOne("Logging"))
                "aspect symbol registered"
        }
    ]
