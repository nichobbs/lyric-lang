module Lyric.Cli.Tests.ManifestTests

open Expecto
open Lyric.Cli.Manifest

let private parseOk (text: string) : Manifest =
    match parseText text with
    | Ok m -> m
    | Error e -> failwithf "expected Ok, got %A" e

let tests =
    testList "Lyric.Cli.Manifest" [

        testCase "minimal manifest parses" <| fun () ->
            let m = parseOk """
[package]
name = "MyPackage"
version = "0.1.0"
"""
            Expect.equal m.Package.Name "MyPackage" "name"
            Expect.equal m.Package.Version "0.1.0" "version"
            Expect.isEmpty m.Package.Authors "authors default empty"
            Expect.equal m.Dependencies [] "no deps"

        testCase "package metadata round-trip" <| fun () ->
            let m = parseOk """
[package]
name = "Lyric.Json"
version = "0.5.2"
description = "JSON utilities"
authors = ["alice", "bob"]
license = "MIT"
repository = "https://example.com/repo"
"""
            Expect.equal m.Package.Description (Some "JSON utilities") "description"
            Expect.equal m.Package.Authors ["alice"; "bob"] "authors"
            Expect.equal m.Package.License (Some "MIT") "license"
            Expect.equal m.Package.Repository (Some "https://example.com/repo") "repo"

        testCase "dependencies sorted by name" <| fun () ->
            let m = parseOk """
[package]
name = "Foo"
version = "1.0.0"

[dependencies]
"Zeta" = "9.9.9"
"Alpha" = "1.0.0"
"Beta" = "2.0.0"
"""
            Expect.equal (m.Dependencies |> List.map (fun d -> d.Name))
                ["Alpha"; "Beta"; "Zeta"]
                "deps sorted lexicographically"
            Expect.equal (m.Dependencies |> List.map (fun d -> d.Version))
                ["1.0.0"; "2.0.0"; "9.9.9"]
                "versions follow"

        testCase "build section optional" <| fun () ->
            let m = parseOk """
[package]
name = "X"
version = "0.0.1"

[build]
sources = ["src/main.l", "src/util.l"]
out = "dist"
"""
            Expect.equal m.Build.Sources (Some ["src/main.l"; "src/util.l"]) "sources"
            Expect.equal m.Build.OutputDir (Some "dist") "out"

        testCase "string escapes work" <| fun () ->
            let m = parseOk """
[package]
name = "X"
version = "0.0.1"
description = "line\nbreak"
"""
            Expect.equal m.Package.Description (Some "line\nbreak") "escape"

        testCase "comments are ignored" <| fun () ->
            let m = parseOk """
# top-level comment
[package]
name = "X"   # trailing
version = "0.0.1"
# trailing block
"""
            Expect.equal m.Package.Name "X" "name preserved"

        testCase "missing name surfaces structured error" <| fun () ->
            let r = parseText """
[package]
version = "0.0.1"
"""
            match r with
            | Error (MissingField (sec, key)) ->
                Expect.equal sec "package" "section"
                Expect.equal key "name" "key"
            | _ -> failwithf "expected MissingField, got %A" r

        testCase "wrong type surfaces structured error" <| fun () ->
            let r = parseText """
[package]
name = 42
version = "0.0.1"
"""
            match r with
            | Error (InvalidFieldType (_, "name", _)) -> ()
            | _ -> failwithf "expected InvalidFieldType for name, got %A" r

        testCase "unterminated string surfaces parse error" <| fun () ->
            let r = parseText """
[package]
name = "X
version = "0.0.1"
"""
            match r with
            | Error (ParseError _) -> ()
            | _ -> failwithf "expected ParseError, got %A" r

        testCase "duplicate keys rejected" <| fun () ->
            let r = parseText """
[package]
name = "X"
name = "Y"
version = "0.0.1"
"""
            match r with
            | Error (ParseError _) -> ()
            | _ -> failwithf "expected ParseError, got %A" r
    ]
