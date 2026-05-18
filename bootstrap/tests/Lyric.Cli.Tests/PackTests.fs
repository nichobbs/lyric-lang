module Lyric.Cli.Tests.PackTests

open System.IO
open Expecto
open Lyric.Cli
open Lyric.Cli.Manifest
open Lyric.Cli.Pack

let private mkManifest (deps: (string * string) list) : Manifest =
    { Package =
        { Name        = "Lyric.SmokeTest"
          Version     = "0.1.0"
          Description = Some "smoke"
          Authors     = ["alice"]
          License     = Some "MIT"
          Repository  = None }
      Build =
        { Sources   = None
          OutputDir = None }
      Dependencies =
        deps |> List.map (fun (n, v) -> { Name = n; Version = v; LocalPath = None })
      Project  = None
      Nuget    = None
      Maven    = None
      Features = None }

let private withTempDir (action: string -> 'a) : 'a =
    let dir = Path.Combine(Path.GetTempPath(),
                            "lyric-pack-test-" + System.Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    try action dir
    finally
        try Directory.Delete(dir, true) with _ -> ()

let private getXml (r: Result<string, string>) =
    match r with
    | Ok xml  -> xml
    | Error e -> failwithf "Expected Ok but got Error: %s" e

let private baseToml = """
[package]
name = "Lyric.SmokeTest"
version = "0.1.0"
description = "smoke"
authors = ["alice"]
license = "MIT"
"""

let tests =
    testList "Lyric.Cli.Pack" [

        testCase "publishCsproj declares TargetFramework net10.0" <| fun () ->
            let xml = getXml (SelfHostedPack.publishCsproj baseToml "/tmp/fake.dll")
            Expect.stringContains xml "<TargetFramework>net10.0</TargetFramework>"
                "publish csproj targets net10.0"

        testCase "publishCsproj embeds dll under lib/net10.0/" <| fun () ->
            let xml = getXml (SelfHostedPack.publishCsproj baseToml "/tmp/foo/bar.dll")
            Expect.stringContains xml "PackagePath=\"lib/net10.0/bar.dll\""
                "package path inside lib/net10.0/"
            Expect.stringContains xml "Pack=\"true\""
                "marked as packable item"

        testCase "publishCsproj forwards dependencies" <| fun () ->
            let toml = """
[package]
name = "Lyric.SmokeTest"
version = "0.1.0"

[dependencies]
"Lyric.Json" = "1.0.0"
"Lyric.Time" = "2.3.4"
"""
            let xml = getXml (SelfHostedPack.publishCsproj toml "/tmp/fake.dll")
            Expect.stringContains xml "Include=\"Lyric.Json\""
                "first dep"
            Expect.stringContains xml "Version=\"2.3.4\""
                "second dep version"

        testCase "publishCsproj sets PackageId / Version" <| fun () ->
            let xml = getXml (SelfHostedPack.publishCsproj baseToml "/tmp/fake.dll")
            Expect.stringContains xml "<PackageId>Lyric.SmokeTest</PackageId>" "id"
            Expect.stringContains xml "<Version>0.1.0</Version>" "version"

        testCase "publishCsproj omits empty optional metadata" <| fun () ->
            let toml = """
[package]
name = "X"
version = "0.0.1"
"""
            let xml = getXml (SelfHostedPack.publishCsproj toml "/tmp/fake.dll")
            Expect.isFalse (xml.Contains "<Authors>") "no authors element"
            Expect.isFalse (xml.Contains "<Description>") "no description"

        testCase "restoreCsproj omits dll embedding" <| fun () ->
            let toml = """
[package]
name = "Lyric.SmokeTest"
version = "0.1.0"

[dependencies]
"Lyric.Foo" = "1.0.0"
"""
            let xml = getXml (SelfHostedPack.restoreCsproj toml)
            Expect.isFalse (xml.Contains "PackagePath") "no PackagePath"
            Expect.stringContains xml "Include=\"Lyric.Foo\"" "deps included"

        testCase "restoreCsproj forwards [nuget] entries" <| fun () ->
            let toml = """
[package]
name = "Lyric.SmokeTest"
version = "0.1.0"

[dependencies]
"Lyric.Foo" = "1.0.0"

[nuget]
"Newtonsoft.Json" = "13.0.3"
Polly = "8.0.0"
"""
            let xml = getXml (SelfHostedPack.restoreCsproj toml)
            Expect.stringContains xml "Include=\"Newtonsoft.Json\""
                "first NuGet ref present"
            Expect.stringContains xml "Version=\"13.0.3\""
                "first NuGet version"
            Expect.stringContains xml "Include=\"Polly\""
                "second NuGet ref present"
            Expect.stringContains xml "Include=\"Lyric.Foo\""
                "Lyric deps still flow through"

        testCase "restoreCsproj uses [nuget.options] target when set" <| fun () ->
            let toml = """
[package]
name = "X"
version = "0.0.1"

[nuget]
Polly = "8.0.0"

[nuget.options]
target = "net9.0"
"""
            let xml = getXml (SelfHostedPack.restoreCsproj toml)
            Expect.stringContains xml "<TargetFramework>net9.0</TargetFramework>"
                "target overridden to net9.0"

        testCase "restoreCsproj defaults TFM to net10.0 without [nuget]" <| fun () ->
            let xml = getXml (SelfHostedPack.restoreCsproj baseToml)
            Expect.stringContains xml "<TargetFramework>net10.0</TargetFramework>"
                "default TFM net10.0"

        testCase "runPack errors when prebuilt DLL missing" <| fun () ->
            withTempDir <| fun dir ->
                let m = mkManifest []
                let result = runPack m dir "/this/does/not/exist.dll" dir true
                match result with
                | Error msg ->
                    Expect.stringContains msg "not found" "missing-DLL message"
                | Ok _ -> failwith "expected Error"

        testCase "scratch project dir is per-package" <| fun () ->
            withTempDir <| fun dir ->
                let m = mkManifest []
                let s1 = scratchProjectDir m dir "pack"
                let s2 = scratchProjectDir m dir "restore"
                Expect.notEqual s1 s2 "pack vs restore separate"
                Expect.stringContains s1 "Lyric.SmokeTest" "name embedded"
                Expect.stringContains s1 ".lyric" "under .lyric/"

        testCase "default pack output dir is pkg/ when manifest doesn't override" <| fun () ->
            let m = mkManifest []
            let dir = defaultPackOutputDir m "/repo"
            Expect.equal dir (Path.Combine("/repo", "pkg")) "pkg/ default"

        testCase "custom out dir from manifest is honored" <| fun () ->
            let m =
                { mkManifest [] with
                    Build = { Sources = None; OutputDir = Some "dist" } }
            let dir = defaultPackOutputDir m "/repo"
            Expect.equal dir (Path.Combine("/repo", "dist")) "custom dist/"

        testCase "default DLL path resolves to bin/<name>.dll" <| fun () ->
            let m = mkManifest []
            let p = defaultDllPath m "/repo"
            Expect.equal p (Path.Combine("/repo", "bin", "Lyric.SmokeTest.dll"))
                "bin/<sanitised>.dll convention"
    ]
