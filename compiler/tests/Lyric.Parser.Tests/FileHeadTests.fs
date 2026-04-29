module Lyric.Parser.Tests.FileHeadTests

open Expecto
open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.Parser.Parser

let private parseClean (src: string) =
    let r = parse src
    Expect.isEmpty r.Diagnostics (sprintf "expected no diagnostics for %A" src)
    r.File

let private parseWithDiags (src: string) =
    let r = parse src
    r.File, r.Diagnostics

let tests =
    testList "file-head parsing" [

        // ----- package -----

        test "single-segment package" {
            let f = parseClean "package Foo"
            Expect.equal f.Package.Path.Segments ["Foo"] "package path"
            Expect.isEmpty f.ModuleDoc "no module doc"
            Expect.isEmpty f.FileLevelAnnotations "no annotations"
            Expect.isEmpty f.Imports "no imports"
        }

        test "multi-segment package path" {
            let f = parseClean "package Money.Internal.Math"
            Expect.equal f.Package.Path.Segments
                ["Money"; "Internal"; "Math"] "package path"
        }

        test "missing package declaration is reported" {
            let _, diags = parseWithDiags "import Foo"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0020" "missing-package diagnostic"
        }

        test "package keyword without identifier is reported" {
            let _, diags = parseWithDiags "package"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0010" "missing-ident diagnostic"
        }

        // ----- module doc comments -----

        test "module doc comments at top of file" {
            let src = "//! the money package\n//! holds amounts and accounts\npackage Money"
            let f = parseClean src
            Expect.equal f.ModuleDoc.Length 2 "two module-doc lines"
            Expect.equal f.ModuleDoc.[0].Text "the money package" "first line"
            Expect.isTrue f.ModuleDoc.[0].IsModule "is module-doc"
        }

        // ----- file-level annotations -----

        test "single file-level annotation" {
            let f = parseClean "@runtime_checked\npackage Money"
            Expect.equal f.FileLevelAnnotations.Length 1 "one annotation"
            let a = f.FileLevelAnnotations.[0]
            Expect.equal a.Name.Segments ["runtime_checked"] "annotation name"
            Expect.isEmpty a.Args "no args"
        }

        test "annotation with bare-identifier arg" {
            let f = parseClean "@derive(Json)\npackage Foo"
            let a = f.FileLevelAnnotations.[0]
            Expect.equal a.Args.Length 1 "one arg"
            match a.Args.[0] with
            | ABare(name, _) -> Expect.equal name "Json" "bare arg"
            | _ -> failtest "expected bare-identifier arg"
        }

        test "annotation with multiple bare args" {
            let f = parseClean "@projectable(json, sql)\npackage Foo"
            let a = f.FileLevelAnnotations.[0]
            Expect.equal a.Args.Length 2 "two args"
        }

        test "annotation with keyword-style arg" {
            let f = parseClean "@projectable(version = 2)\npackage Foo"
            let a = f.FileLevelAnnotations.[0]
            match a.Args.[0] with
            | AAName("version", AVInt(2UL, _), _) -> ()
            | other -> failtestf "unexpected: %A" other
        }

        test "annotation with string-literal arg" {
            let f = parseClean "@axiom(\"trusted boundary\")\npackage Sys"
            let a = f.FileLevelAnnotations.[0]
            match a.Args.[0] with
            | ALiteral(AVString("trusted boundary", _), _) -> ()
            | other -> failtestf "unexpected: %A" other
        }

        test "two file-level annotations" {
            let f = parseClean "@runtime_checked\n@axiom\npackage Foo"
            Expect.equal f.FileLevelAnnotations.Length 2 "two annotations"
        }

        // ----- imports -----

        test "single import without group" {
            let f = parseClean "package Foo\nimport Time.Instant"
            Expect.equal f.Imports.Length 1 "one import"
            let i = f.Imports.[0]
            Expect.equal i.Path.Segments ["Time"; "Instant"] "import path"
            Expect.isFalse i.IsPubUse "not a pub use"
            Expect.isNone i.Selector "no selector"
            Expect.isNone i.Alias "no alias"
        }

        test "import with group selectors" {
            let f = parseClean "package Foo\nimport Money.{Amount, Cents}"
            let i = f.Imports.[0]
            Expect.equal i.Path.Segments ["Money"] "import path"
            match i.Selector with
            | Some (ISGroup items) ->
                Expect.equal items.Length 2 "two selectors"
                Expect.equal items.[0].Name "Amount" "first selector"
                Expect.equal items.[1].Name "Cents" "second selector"
                Expect.isNone items.[0].Alias "no alias"
            | other -> failtestf "expected ISGroup, got %A" other
        }

        test "import with selector aliases" {
            let f = parseClean "package Foo\nimport Money.{Amount, valueOf as amountValue}"
            let i = f.Imports.[0]
            match i.Selector with
            | Some (ISGroup [a; b]) ->
                Expect.equal a.Name "Amount" "first"
                Expect.isNone a.Alias "no alias on first"
                Expect.equal b.Name "valueOf" "second"
                Expect.equal b.Alias (Some "amountValue") "alias on second"
            | other -> failtestf "expected two selectors, got %A" other
        }

        test "import with path-level alias" {
            let f = parseClean "package Foo\nimport std.collections as Coll"
            let i = f.Imports.[0]
            Expect.equal i.Path.Segments ["std"; "collections"] "path"
            Expect.equal i.Alias (Some "Coll") "alias"
        }

        test "pub use is recorded as a re-export import" {
            let f = parseClean "package Foo\npub use Money.Amount"
            let i = f.Imports.[0]
            Expect.isTrue i.IsPubUse "pub use flag"
            Expect.equal i.Path.Segments ["Money"; "Amount"] "path"
        }

        test "many imports separated by newlines" {
            let src =
                "package App\n"
                + "import Money.{Amount, Cents}\n"
                + "import Time.Instant\n"
                + "import std.collections.{Map, Set}\n"
            let f = parseClean src
            Expect.equal f.Imports.Length 3 "three imports"
        }

        // ----- end of file / item placeholder -----

        test "items past imports — kinds not yet implemented produce P0098" {
            // `pub interface I { … }` is recognised by P3 (item kind
            // identified, body skipped) but not yet parsed in detail;
            // the parser surfaces P0098 to flag work-in-progress.
            let _, diags =
                parseWithDiags "package Foo\npub interface I { func f(): Int }"
            let codes = diags |> List.map (fun d -> d.Code)
            Expect.contains codes "P0098" "interface bodies remain unparsed"
        }

        test "package + imports only is clean" {
            let src =
                "@runtime_checked\n"
                + "package App\n"
                + "import Money.{Amount, Cents}\n"
                + "import Time.Instant\n"
            let r = parse src
            // No diagnostics expected: file head fully consumed, no
            // residual items.
            Expect.isEmpty r.Diagnostics "no diagnostics"
        }

        test "file with everything: doc + ann + package + imports" {
            let src =
                "//! application package\n"
                + "//! wires up the service\n"
                + "@runtime_checked\n"
                + "package App\n"
                + "import Money.{Amount}\n"
                + "import Time.Instant\n"
            let f = parseClean src
            Expect.equal f.ModuleDoc.Length 2 "2 doc lines"
            Expect.equal f.FileLevelAnnotations.Length 1 "1 annotation"
            Expect.equal f.Package.Path.Segments ["App"] "package"
            Expect.equal f.Imports.Length 2 "2 imports"
        }
    ]
