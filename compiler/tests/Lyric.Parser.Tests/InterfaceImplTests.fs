module Lyric.Parser.Tests.InterfaceImplTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private prelude = "package P\n"

let private parseClean (src: string) =
    let r = parse (prelude + src)
    Expect.isEmpty r.Diagnostics
        (sprintf "expected no diagnostics for:\n%s\nactual: %A" src r.Diagnostics)
    r.File

let private getOnlyItem (file: SourceFile) : Item =
    Expect.equal file.Items.Length 1 "exactly one item"
    file.Items.[0]

let tests =
    testList "interface and impl declarations (P6b)" [

        // ----- interfaces -----

        test "empty interface" {
            let f = parseClean "interface I {}"
            match (getOnlyItem f).Kind with
            | IInterface i ->
                Expect.equal i.Name "I" "name"
                Expect.isEmpty i.Members "no members"
            | other -> failtestf "expected IInterface, got %A" other
        }

        test "interface with one method signature (no body)" {
            let f = parseClean "pub interface Clock { func now(): Instant }"
            match (getOnlyItem f).Kind with
            | IInterface i ->
                Expect.equal i.Members.Length 1 "one member"
                match i.Members.[0] with
                | IMSig sig' ->
                    Expect.equal sig'.Name "now" "method name"
                    Expect.equal sig'.Params.Length 0 "no params"
                | other -> failtestf "expected IMSig, got %A" other
            | other -> failtestf "expected IInterface, got %A" other
        }

        test "interface with default method (has body)" {
            let f = parseClean
                        "interface Greet { func hello(): String = \"hi\" }"
            match (getOnlyItem f).Kind with
            | IInterface i ->
                match i.Members.[0] with
                | IMFunc fn -> Expect.isSome fn.Body "body present"
                | other -> failtestf "expected IMFunc, got %A" other
            | other -> failtestf "expected IInterface, got %A" other
        }

        test "interface with associated type" {
            let f = parseClean "interface Container { type Element }"
            match (getOnlyItem f).Kind with
            | IInterface i ->
                match i.Members.[0] with
                | IMAssoc a ->
                    Expect.equal a.Name "Element" "name"
                    Expect.isNone a.Default "no default"
                | other -> failtestf "expected IMAssoc, got %A" other
            | other -> failtestf "expected IInterface, got %A" other
        }

        test "interface with mixed members" {
            let src =
                """interface Repository {
                    type Id
                    async func findById(id: in Id): Self?
                    func count(): Int
                }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IInterface i ->
                Expect.equal i.Members.Length 3 "three members"
                match i.Members.[0] with
                | IMAssoc _ -> () | other -> failtestf "0: %A" other
                match i.Members.[1] with
                | IMSig s when s.IsAsync -> ()
                | other -> failtestf "1 (expected async sig): %A" other
                match i.Members.[2] with
                | IMSig _ -> () | other -> failtestf "2: %A" other
            | other -> failtestf "expected IInterface, got %A" other
        }

        test "interface with generics and where" {
            let f = parseClean
                        "generic[T] interface Box where T: Default { func value(): T }"
            match (getOnlyItem f).Kind with
            | IInterface i ->
                Expect.isSome i.Generics "generics"
                Expect.isSome i.Where "where"
            | other -> failtestf "expected IInterface, got %A" other
        }

        // ----- impls -----

        test "minimal impl" {
            let f = parseClean
                        "impl Compare for UserId { func cmp(a: in UserId, b: in UserId): Int = 0 }"
            match (getOnlyItem f).Kind with
            | IImpl i ->
                Expect.equal i.Interface.Head.Segments ["Compare"] "interface"
                match i.Target.Kind with
                | TRef p -> Expect.equal p.Segments ["UserId"] "target"
                | other -> failtestf "target: %A" other
                Expect.equal i.Members.Length 1 "one member"
            | other -> failtestf "expected IImpl, got %A" other
        }

        test "impl with associated type and method" {
            let src =
                """impl Container for List {
                    type Element = Int
                    func count(): Int = 42
                }"""
            let f = parseClean src
            match (getOnlyItem f).Kind with
            | IImpl i ->
                Expect.equal i.Members.Length 2 "two members"
                match i.Members.[0] with
                | IMplAssoc a ->
                    Expect.isSome a.Default "default present"
                | other -> failtestf "0: %A" other
                match i.Members.[1] with
                | IMplFunc fn -> Expect.equal fn.Name "count" "method"
                | other -> failtestf "1: %A" other
            | other -> failtestf "expected IImpl, got %A" other
        }

        test "impl with generics" {
            let f = parseClean
                        "impl generic[T] Add for Vec3 { func add(a: in Vec3, b: in Vec3): Vec3 = a }"
            match (getOnlyItem f).Kind with
            | IImpl i ->
                Expect.isSome i.Generics "generics"
                Expect.equal i.Interface.Head.Segments ["Add"] "interface"
            | other -> failtestf "expected IImpl, got %A" other
        }

        test "impl with parameterised interface" {
            let f = parseClean
                        "impl Repository[User, UserId] for PostgresUserRepository { func count(): Int = 0 }"
            match (getOnlyItem f).Kind with
            | IImpl i ->
                Expect.equal i.Interface.Args.Length 2 "two type args"
            | other -> failtestf "expected IImpl, got %A" other
        }

        test "impl missing 'for' reports P0180" {
            let r = parse (prelude + "impl I X { func f(): Int = 0 }")
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0180" "P0180 reported"
        }
    ]
