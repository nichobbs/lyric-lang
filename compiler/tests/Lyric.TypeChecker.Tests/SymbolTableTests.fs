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
    ]
