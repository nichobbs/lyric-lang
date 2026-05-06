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

        // [project] is the Phase 5 §M5.1 stage 2c.2 entry point per
        // `docs/20-project-as-dll.md` §3 — absent for legacy
        // single-package manifests, present when the user wants
        // project-as-DLL bundling.
        testCase "project section absent by default" <| fun () ->
            let m = parseOk """
[package]
name = "MyPackage"
version = "0.1.0"
"""
            Expect.equal m.Project None "no [project] -> Project = None"

        testCase "project section parses with defaults" <| fun () ->
            let m = parseOk """
[package]
name = "MyApp"
version = "0.1.0"

[project]
name = "MyApp"
"""
            match m.Project with
            | None -> failtest "expected Some Project"
            | Some p ->
                Expect.equal p.Name "MyApp" "project name"
                Expect.equal p.Output PerPackage
                    "output defaults to per-package"
                Expect.equal p.OutputAssembly None "no output_assembly"
                Expect.isEmpty p.Packages "[project.packages] empty"

        testCase "project output mode round-trips" <| fun () ->
            let mSingle = parseOk """
[package]
name = "X"
version = "0.0.1"

[project]
name = "X"
output = "single"
output_assembly = "Bundle.dll"
"""
            let mPP = parseOk """
[package]
name = "X"
version = "0.0.1"

[project]
name = "X"
output = "per-package"
"""
            Expect.equal mSingle.Project.Value.Output Single "single"
            Expect.equal mSingle.Project.Value.OutputAssembly
                (Some "Bundle.dll") "output_assembly"
            Expect.equal mPP.Project.Value.Output PerPackage "per-package"

        testCase "invalid project output mode rejected" <| fun () ->
            let r = parseText """
[package]
name = "X"
version = "0.0.1"

[project]
name = "X"
output = "weird"
"""
            match r with
            | Error (InvalidFieldType ("project", "output", _)) -> ()
            | _ -> failwithf "expected InvalidFieldType, got %A" r

        // [nuget] + [nuget.options] are the Phase 5 §M5.1 stage 2d
        // entry points per `docs/21-nuget-linking.md` §2 — absent for
        // legacy manifests, present when the user wants to consume
        // arbitrary NuGet packages.
        testCase "nuget section absent by default" <| fun () ->
            let m = parseOk """
[package]
name = "MyPackage"
version = "0.1.0"
"""
            Expect.equal m.Nuget None "no [nuget] -> Nuget = None"

        testCase "nuget packages parse and sort by id" <| fun () ->
            let m = parseOk """
[package]
name = "MyApp"
version = "0.1.0"

[nuget]
"Newtonsoft.Json" = "13.0.3"
"System.Text.Json" = "9.0.0"
"Npgsql" = "8.0.0"
"""
            match m.Nuget with
            | None -> failtest "expected Some Nuget"
            | Some n ->
                Expect.equal (n.Packages |> List.map (fun p -> p.Id))
                    ["Newtonsoft.Json"; "Npgsql"; "System.Text.Json"]
                    "nuget ids sorted lexicographically"
                Expect.equal (n.Packages |> List.map (fun p -> p.Version))
                    ["13.0.3"; "8.0.0"; "9.0.0"]
                    "versions follow"
                Expect.isFalse n.Options.AllowNative
                    "allow_native defaults to false"
                Expect.equal n.Options.Target None "target defaults to None"

        testCase "nuget.options round-trip" <| fun () ->
            let m = parseOk """
[package]
name = "MyApp"
version = "0.1.0"

[nuget]
"Polly" = "8.0.0"

[nuget.options]
allow_native = true
target = "net10.0"
"""
            match m.Nuget with
            | None -> failtest "expected Some Nuget"
            | Some n ->
                Expect.isTrue n.Options.AllowNative "allow_native"
                Expect.equal n.Options.Target (Some "net10.0") "target"

        testCase "nuget.options without [nuget] still surfaces section" <| fun () ->
            // Edge case: the user has no NuGet deps yet but pre-sets
            // options for when they add some.  Section should be
            // present so the build flow can honour them.
            let m = parseOk """
[package]
name = "MyApp"
version = "0.1.0"

[nuget.options]
allow_native = true
"""
            match m.Nuget with
            | None -> failtest "expected Some Nuget"
            | Some n ->
                Expect.isEmpty n.Packages "no packages yet"
                Expect.isTrue n.Options.AllowNative "options applied"

        testCase "nuget version must be a string" <| fun () ->
            let r = parseText """
[package]
name = "X"
version = "0.0.1"

[nuget]
"BadPackage" = 42
"""
            match r with
            | Error (InvalidFieldType ("nuget", "BadPackage", _)) -> ()
            | _ ->
                failwithf "expected InvalidFieldType for nuget.BadPackage, got %A" r

        testCase "nuget.options.allow_native must be bool" <| fun () ->
            let r = parseText """
[package]
name = "X"
version = "0.0.1"

[nuget.options]
allow_native = "yes"
"""
            match r with
            | Error (InvalidFieldType ("nuget.options", "allow_native", _)) -> ()
            | _ ->
                failwithf
                    "expected InvalidFieldType for nuget.options.allow_native, got %A"
                    r

        testCase "[project.packages] map sorted by name" <| fun () ->
            let m = parseOk """
[package]
name = "MyApp"
version = "0.1.0"

[project]
name = "MyApp"
output = "single"

[project.packages]
"MyApp.Web"  = "src/web"
"MyApp.Core" = "src/core"
"MyApp.Db"   = "src/db"
"""
            match m.Project with
            | None -> failtest "expected Some Project"
            | Some p ->
                Expect.equal (p.Packages |> List.map fst)
                    ["MyApp.Core"; "MyApp.Db"; "MyApp.Web"]
                    "packages sorted by name"
                Expect.equal (p.Packages |> List.map snd)
                    ["src/core"; "src/db"; "src/web"]
                    "package source dirs"
    ]
