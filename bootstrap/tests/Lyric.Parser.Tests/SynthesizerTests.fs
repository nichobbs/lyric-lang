module Lyric.Parser.Tests.SynthesizerTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

/// Parse a complete file and assert it has no parse-time diagnostics.
let private parseClean (src: string) : SourceFile =
    let r = parse src
    Expect.isEmpty r.Diagnostics
        (sprintf "expected no parse diagnostics for: %s\nactual: %A"
            src r.Diagnostics)
    r.File

let private funcNames (file: SourceFile) : string list =
    file.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IFunc fn -> Some fn.Name
        | _ -> None)

let private recordNames (file: SourceFile) : string list =
    file.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IRecord rd -> Some rd.Name
        | IExposedRec rd -> Some rd.Name
        | _ -> None)

let private implTargets (file: SourceFile) : string list =
    file.Items
    |> List.choose (fun it ->
        match it.Kind with
        | IImpl impl ->
            match impl.Target.Kind with
            | TRef p when p.Segments.Length = 1 -> Some (List.head p.Segments)
            | _ -> None
        | _ -> None)

let tests =
    testList "parser-side synthesisers" [

        // ---------------------------------------------------------------
        // AliasRewriter — `import X as A` rewrites paths in items.
        // ---------------------------------------------------------------

        test "import-as alias rewrites a single-segment-prefixed call" {
            // Without the alias, `Coll.foo` would be a multi-segment
            // path. After rewrite, the leading `Coll.` is dropped so
            // the call is `foo()`.
            let file =
                parseClean
                    "package P\n\
                     import Std.Collections as Coll\n\
                     pub func main(): Int = Coll.foo()\n"
            // Find main and inspect its body.
            let main =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IFunc fn when fn.Name = "main" -> Some fn
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "main not found")
            match main.Body with
            | Some (FBExpr { Kind = ECall(callee, _) }) ->
                match callee.Kind with
                | EPath p ->
                    Expect.equal p.Segments ["foo"]
                        "Coll. prefix is dropped from the path"
                | EMember _ ->
                    failtest "expected a single EPath after rewrite, got EMember chain"
                | other -> failtestf "callee shape: %A" other
            | other -> failtestf "main body shape: %A" other
        }

        test "import-as alias rewrites a type reference" {
            let file =
                parseClean
                    "package P\n\
                     import Std.Collections as Coll\n\
                     pub func sum(xs: in Coll.MyList): Int = 0\n"
            let sumFn =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IFunc fn when fn.Name = "sum" -> Some fn
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "sum not found")
            match sumFn.Params.[0].Type.Kind with
            | TRef p ->
                Expect.equal p.Segments ["MyList"]
                    "Coll. prefix dropped from type ref"
            | other -> failtestf "param type kind: %A" other
        }

        test "no alias = no path rewriting" {
            let file =
                parseClean
                    "package P\n\
                     pub func main(): Int = Std.Collections.foo()\n"
            // Without an `as` clause, the parser leaves the qualified
            // path intact (it'll later resolve to a multi-segment
            // path, which the resolver flags as T0014).
            let main =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IFunc fn when fn.Name = "main" -> Some fn
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "main not found")
            match main.Body with
            | Some (FBExpr { Kind = ECall(callee, _) }) ->
                // The path `Std.Collections.foo` lowers to a member
                // chain in the AST: EMember(EMember(EPath "Std",
                // "Collections"), "foo").
                match callee.Kind with
                | EMember _ -> ()
                | other -> failtestf "callee shape: %A" other
            | other -> failtestf "main body shape: %A" other
        }

        // ---------------------------------------------------------------
        // JsonDerive — @derive(Json) records grow toJson / fromJson.
        // ---------------------------------------------------------------

        test "derive(Json) adds a Type.toJson function" {
            let file =
                parseClean
                    "package P\n\
                     @derive(Json)\n\
                     pub record Point { x: Int, y: Int }\n"
            let names = funcNames file
            Expect.contains names "Point.toJson"
                "Point.toJson is synthesised"
        }

        test "non-derive(Json) record gets no toJson" {
            let file =
                parseClean
                    "package P\n\
                     pub record Point { x: Int, y: Int }\n"
            let names = funcNames file
            Expect.isFalse (List.contains "Point.toJson" names)
                "no toJson for plain record"
        }

        test "derive(Json) on multiple records produces a toJson per type" {
            let file =
                parseClean
                    "package P\n\
                     @derive(Json)\n\
                     pub record A { v: Int }\n\
                     @derive(Json)\n\
                     pub record B { s: String }\n"
            let names = funcNames file
            Expect.contains names "A.toJson" "A.toJson"
            Expect.contains names "B.toJson" "B.toJson"
        }

        // ---------------------------------------------------------------
        // Stubbable — @stubbable interfaces grow a record + impl.
        // ---------------------------------------------------------------

        test "stubbable interface synthesises a SuffixStub record" {
            let file =
                parseClean
                    "package P\n\
                     @stubbable\n\
                     pub interface Clock {\n\
                       func now(): Int\n\
                     }\n"
            let recs = recordNames file
            Expect.contains recs "ClockStub" "ClockStub record"
            let impls = implTargets file
            Expect.contains impls "ClockStub" "impl … for ClockStub"
        }

        test "non-stubbable interface stays untouched" {
            let file =
                parseClean
                    "package P\n\
                     pub interface Clock {\n\
                       func now(): Int\n\
                     }\n"
            let recs = recordNames file
            Expect.isFalse (List.contains "ClockStub" recs)
                "no synthesised record"
        }

        test "stubbable on a generic interface is left alone (bootstrap restriction)" {
            // Per Stubbable.fs, generic interfaces are a deferred
            // feature — the synthesiser skips them silently.
            let file =
                parseClean
                    "package P\n\
                     @stubbable\n\
                     generic[T] pub interface Repo {\n\
                       func find(): T\n\
                     }\n"
            let recs = recordNames file
            Expect.isFalse (List.contains "RepoStub" recs)
                "generic stubbable does not synthesise"
        }

        // ---------------------------------------------------------------
        // Wire — `wire X { … }` synthesises a record + bootstrap factory.
        // ---------------------------------------------------------------

        test "wire synthesises both a record and a bootstrap function" {
            let file =
                parseClean
                    "package P\n\
                     wire ProductionApp {\n\
                       singleton clock: Clock = SystemClock.make()\n\
                       expose clock\n\
                     }\n"
            let recs = recordNames file
            Expect.contains recs "ProductionApp" "ProductionApp record"
            let names = funcNames file
            Expect.contains names "ProductionApp.bootstrap"
                "ProductionApp.bootstrap factory"
        }

        test "wire bootstrap parameters mirror @provided members" {
            let file =
                parseClean
                    "package P\n\
                     wire W {\n\
                       @provided cfg: AppConfig\n\
                       singleton svc: Service = Service.make(cfg)\n\
                       expose svc\n\
                     }\n"
            let bootstrap =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IFunc fn when fn.Name = "W.bootstrap" -> Some fn
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "W.bootstrap not found")
            Expect.equal bootstrap.Params.Length 1 "one provided param"
            Expect.equal bootstrap.Params.[0].Name "cfg" "param name"
            Expect.equal bootstrap.Params.[0].Mode PMIn "param mode is `in`"
        }

        test "wire singleton dependency cycle emits P0260" {
            let r =
                parse
                    "package P\n\
                     wire W {\n\
                       singleton a: A = makeA(b)\n\
                       singleton b: B = makeB(a)\n\
                       expose a\n\
                     }\n"
            let codes = r.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "P0260" "P0260 emitted on cycle"
        }

        test "wire with no expose synthesises an empty record" {
            let file =
                parseClean
                    "package P\n\
                     wire W {\n\
                       singleton clock: Clock = SystemClock.make()\n\
                     }\n"
            let recDecl =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IRecord rd when rd.Name = "W" -> Some rd
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "wire record not found")
            Expect.equal recDecl.Members.Length 0 "no exposed fields"
        }

        test "wire with multiple exposes records each as a field" {
            let file =
                parseClean
                    "package P\n\
                     wire W {\n\
                       singleton clock: Clock = SystemClock.make()\n\
                       singleton svc: Service = Service.make()\n\
                       expose clock\n\
                       expose svc\n\
                     }\n"
            let recDecl =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IRecord rd when rd.Name = "W" -> Some rd
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "wire record not found")
            Expect.equal recDecl.Members.Length 2 "two exposed fields"
        }

        test "wire bootstrap body ends in a record-construction call" {
            let file =
                parseClean
                    "package P\n\
                     wire W {\n\
                       singleton svc: Service = Service.make()\n\
                       expose svc\n\
                     }\n"
            let bootstrap =
                file.Items
                |> List.tryPick (fun it ->
                    match it.Kind with
                    | IFunc fn when fn.Name = "W.bootstrap" -> Some fn
                    | _ -> None)
                |> Option.defaultWith (fun () -> failtest "W.bootstrap not found")
            match bootstrap.Body with
            | Some (FBBlock blk) ->
                // Last statement should be SExpr of an ECall whose callee
                // is the wire-named record path.
                let last = blk.Statements |> List.last
                match last.Kind with
                | SExpr { Kind = ECall(callee, _) } ->
                    match callee.Kind with
                    | EPath p ->
                        Expect.equal p.Segments ["W"]
                            "constructs the W record"
                    | other ->
                        failtestf "expected EPath callee, got %A" other
                | other ->
                    failtestf "expected SExpr ECall, got %A" other
            | other ->
                failtestf "expected FBBlock body, got %A" other
        }
    ]
