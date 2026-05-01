module Lyric.Parser.Tests.RemainingItemTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseClean (src: string) =
    let r = parse (prelude + src)
    Expect.isEmpty r.Diagnostics
        (sprintf "diagnostics for: %s\nactual: %A" src r.Diagnostics)
    r.File

let private getOnlyItem (file: SourceFile) : Item =
    Expect.equal file.Items.Length 1 "exactly one item"
    file.Items.[0]

let tests =
    testList "remaining item kinds (P8)" [

        // ----- protected type -----

        test "protected type with var field" {
            let f = parseClean "protected type Counter { var n: Int }"
            match (getOnlyItem f).Kind with
            | IProtected p ->
                Expect.equal p.Name "Counter" "name"
                Expect.equal p.Members.Length 1 "one field"
                match p.Members.[0] with
                | PMField (PFVar(name, _, _, _)) ->
                    Expect.equal name "n" "field name"
                | other -> failtestf "expected PFVar, got %A" other
            | other -> failtestf "expected IProtected, got %A" other
        }

        test "protected type with entry, when, and invariant" {
            let src = """protected type TokenBucket {
                var tokens: Double
                let capacity: Double
                invariant: tokens >= 0.0
                pub entry tryAcquire(count: in Double): Bool
                    requires: count > 0.0
                    when: tokens >= count
                {
                    return true
                }
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IProtected p ->
                Expect.equal p.Members.Length 4
                    "var + let + invariant + entry"
                let entries =
                    p.Members
                    |> List.choose (fun m ->
                        match m with PMEntry e -> Some e | _ -> None)
                Expect.equal entries.Length 1 "one entry"
                Expect.equal entries.[0].Contracts.Length 2
                    "requires + when"
            | other -> failtestf "expected IProtected, got %A" other
        }

        // ----- wire -----

        test "wire with provided, singleton, bind, expose" {
            let src = """wire ProductionApp {
                @provided config: AppConfig
                singleton clock: Clock = SystemClock.make()
                bind AccountRepository -> repo
                expose clock
            }"""
            let f = parseClean src
            // The C6 wire-block synthesiser appends a synthetic record
            // + bootstrap factory alongside the original IWire.  The
            // parser-shape assertion still consults the IWire.
            let wireItem =
                f.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IWire w -> Some w
                    | _       -> None)
            match wireItem with
            | Some w ->
                Expect.equal w.Members.Length 4 "four members"
                let kinds =
                    w.Members
                    |> List.map (fun m ->
                        match m with
                        | WMProvided _  -> "provided"
                        | WMSingleton _ -> "singleton"
                        | WMScoped _    -> "scoped"
                        | WMBind _      -> "bind"
                        | WMExpose _    -> "expose"
                        | WMLocal _     -> "local")
                Expect.equal kinds
                    ["provided"; "singleton"; "bind"; "expose"]
                    "kinds"
            | None -> failtest "no IWire item in parsed result"
        }

        test "wire with scoped binding" {
            let f = parseClean
                        "wire W { scoped[Request] dbConn: DatabaseConnection = db.acquire() }"
            let wireItem =
                f.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IWire w -> Some w
                    | _       -> None)
            match wireItem with
            | Some w ->
                match w.Members.[0] with
                | WMScoped("Request", "dbConn", _, _, _) -> ()
                | other -> failtestf "expected WMScoped, got %A" other
            | None -> failtest "no IWire item in parsed result"
        }

        // ----- extern package -----

        test "extern package with @axiom annotation and func sig" {
            // `exposed type X` (per worked example 8) is reserved
            // syntax that the §3 grammar does not currently spell
            // out; we use the equivalent `exposed record` here for a
            // clean parse.
            let src = """@axiom("trusted boundary")
            extern package System.IO {
                pub func readAllText(path: in String): String
                pub exposed record File { handle: Long }
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IExtern e ->
                Expect.equal e.Path.Segments ["System"; "IO"] "path"
                Expect.equal e.Members.Length 2 "two members"
            | other -> failtestf "expected IExtern, got %A" other
        }

        // ----- module-level val -----

        test "module-level val with type annotation" {
            let f = parseClean "pub val MAX_USERS: Int = 1_000_000"
            match (getOnlyItem f).Kind with
            | IVal v ->
                Expect.isSome v.Type "type annotation"
                match v.Init.Kind with
                | ELiteral (LInt(1000000UL, _)) -> ()
                | other -> failtestf "init: %A" other
            | other -> failtestf "expected IVal, got %A" other
        }

        test "module-level val with pattern binding" {
            let f = parseClean "val (a, b) = (1, 2)"
            match (getOnlyItem f).Kind with
            | IVal v ->
                match v.Pattern.Kind with
                | PTuple [_; _] -> ()
                | other -> failtestf "pattern: %A" other
            | other -> failtestf "expected IVal, got %A" other
        }

        // ----- scope_kind -----

        test "scope_kind declares a scope tag" {
            let f = parseClean "scope_kind Tenant"
            match (getOnlyItem f).Kind with
            | IScopeKind s ->
                Expect.equal s.Name "Tenant" "name"
            | other -> failtestf "expected IScopeKind, got %A" other
        }

        // ----- test -----

        test "test declaration with body" {
            let f = parseClean "test \"empty stack contains nothing\" { val s = empty() }"
            match (getOnlyItem f).Kind with
            | ITest t ->
                Expect.equal t.Title "empty stack contains nothing" "title"
                Expect.equal t.Body.Statements.Length 1 "one statement"
            | other -> failtestf "expected ITest, got %A" other
        }

        // ----- property -----

        test "property with forall binders" {
            let src = """property "insert then contains" forall (s: Stack, x: Int) {
                val updated = insert(s, x)
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IProperty p ->
                Expect.equal p.Title "insert then contains" "title"
                Expect.equal p.ForAll.Length 2 "two binders"
                Expect.isNone p.Where "no where"
            | other -> failtestf "expected IProperty, got %A" other
        }

        test "property with where clause" {
            let src = """property "remove undoes insert" forall (s: Stack, x: Int)
                where not contains(s, x) {
                val ins = insert(s, x)
            }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IProperty p ->
                Expect.isSome p.Where "where present"
            | other -> failtestf "expected IProperty, got %A" other
        }

        // ----- fixture -----

        test "fixture with type annotation and init" {
            let f = parseClean "fixture clock: Clock = SystemClock.make()"
            match (getOnlyItem f).Kind with
            | IFixture x ->
                Expect.equal x.Name "clock" "name"
                Expect.isSome x.Type "type"
            | other -> failtestf "expected IFixture, got %A" other
        }

        test "fixture without type annotation" {
            let f = parseClean "fixture seed = 42"
            match (getOnlyItem f).Kind with
            | IFixture x ->
                Expect.equal x.Name "seed" "name"
                Expect.isNone x.Type "no type"
            | other -> failtestf "expected IFixture, got %A" other
        }
    ]
