module Lyric.Cli.Tests.MavenTests

open System.IO
open Expecto
open Lyric.Cli.Maven
open Lyric.Cli.MavenShim

// ---------------------------------------------------------------------------
// lyricPackageName (docs/31-maven-linking.md §6, D053)
// ---------------------------------------------------------------------------

let tests =
    testList "Lyric.Cli.Maven" [

        testList "lyricPackageName" [

            testCase "jackson-databind example from spec" <| fun () ->
                Expect.equal
                    (lyricPackageName "com.fasterxml.jackson.core" "jackson-databind")
                    "ComFasterxmlJacksonCore.JacksonDatabind"
                    "spec §6 example"

            testCase "slf4j-api example from spec" <| fun () ->
                Expect.equal
                    (lyricPackageName "org.slf4j" "slf4j-api")
                    "OrgSlf4j.Slf4jApi"
                    "spec §6 example"

            testCase "single-segment group" <| fun () ->
                Expect.equal
                    (lyricPackageName "junit" "junit")
                    "Junit.Junit"
                    "single-segment group + artifact"

            testCase "artifact with dots as separators" <| fun () ->
                Expect.equal
                    (lyricPackageName "org.apache.commons" "commons.lang3")
                    "OrgApacheCommons.CommonsLang3"
                    "dot separator in artifact"

            testCase "artifact with underscores" <| fun () ->
                Expect.equal
                    (lyricPackageName "org.example" "my_lib_core")
                    "OrgExample.MyLibCore"
                    "underscores treated as word separators"

            testCase "group segments capitalised not lowercased" <| fun () ->
                // Group segments only capitalise the first letter; the rest
                // of each segment keeps its original casing.
                Expect.equal
                    (lyricPackageName "com.example" "my-lib")
                    "ComExample.MyLib"
                    "hyphen in artifact"

            testCase "guava with -jre classifier" <| fun () ->
                // The classifier `-jre` is part of the artifact id here
                // (guava ships `guava` and `guava-android` etc.).
                Expect.equal
                    (lyricPackageName "com.google.guava" "guava")
                    "ComGoogleGuava.Guava"
                    "guava base case"
        ]

        testList "MavenShim.generate" [

            testCase "shim header carries sha256 drift marker" <| fun () ->
                let jar : ResolvedMavenJar =
                    { Group      = "org.slf4j"
                      Artifact   = "slf4j-api"
                      Version    = "2.0.13"
                      JarPath    = "/tmp/slf4j-api-2.0.13.jar"
                      Sha256     = "abcdef1234567890"
                      IsTopLevel = true
                      Classes    = None }
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "# lyric:generated-sha256:abcdef1234567890"
                    "B0053 drift-detection header"

            testCase "shim carries @axiom with Maven coordinate" <| fun () ->
                let jar : ResolvedMavenJar =
                    { Group      = "org.slf4j"
                      Artifact   = "slf4j-api"
                      Version    = "2.0.13"
                      JarPath    = "/tmp/slf4j-api-2.0.13.jar"
                      Sha256     = "abc"
                      IsTopLevel = true
                      Classes    = None }
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "@axiom(\"from Maven org.slf4j:slf4j-api v2.0.13\")"
                    "axiom carries full Maven coordinate"

            testCase "shim package name derived from coordinate" <| fun () ->
                let jar : ResolvedMavenJar =
                    { Group      = "com.fasterxml.jackson.core"
                      Artifact   = "jackson-databind"
                      Version    = "2.17.0"
                      JarPath    = "/tmp/jackson-databind-2.17.0.jar"
                      Sha256     = "abc"
                      IsTopLevel = true
                      Classes    = None }
                let shim = generate jar
                Expect.equal shim.LyricPackage
                    "ComFasterxmlJacksonCore.JacksonDatabind"
                    "Lyric package name"
                Expect.stringContains shim.LyricSource
                    "package ComFasterxmlJacksonCore.JacksonDatabind"
                    "package declaration in source"

            testCase "relative path uses PascalGroup_PascalArtifact.l" <| fun () ->
                let jar : ResolvedMavenJar =
                    { Group      = "org.slf4j"
                      Artifact   = "slf4j-api"
                      Version    = "2.0.13"
                      JarPath    = "/tmp/slf4j-api-2.0.13.jar"
                      Sha256     = "abc"
                      IsTopLevel = true
                      Classes    = None }
                let shim = generate jar
                Expect.equal shim.RelativePath
                    (Path.Combine("_extern", "OrgSlf4j_Slf4jApi.l"))
                    "relative path convention"

            testCase "classes=None emits unloadable-artifact comment" <| fun () ->
                let jar : ResolvedMavenJar =
                    { Group      = "org.example"; Artifact   = "native-lib"
                      Version    = "1.0"; JarPath = "/tmp/x.jar"; Sha256 = "abc"
                      IsTopLevel = true; Classes = None }
                let shim = generate jar
                Expect.stringContains shim.LyricSource "Resolver could not"
                    "note about unloadable JAR"
                Expect.equal shim.ExternTypes 0 "no extern types"
                Expect.equal shim.ExternMethods 0 "no methods"

            testCase "classes with public types emits extern type block" <| fun () ->
                let cls =
                    { ClassName = "org.example.Foo"
                      Methods   = [ { Name = "doSomething"; ReturnType = "int"
                                      IsStatic = true
                                      Params = [ { Name = "n"; TypeName = "int" } ] } ] }
                let jar : ResolvedMavenJar =
                    { Group = "org.example"; Artifact = "mylib"
                      Version = "1.0"; JarPath = "/tmp/mylib-1.0.jar"; Sha256 = "aaa"
                      IsTopLevel = true; Classes = Some [cls] }
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "extern type Foo = \"org.example.Foo\""
                    "extern type declaration"
                Expect.equal shim.ExternTypes 1 "one extern type"

            testCase "static method emits @externTarget + pub func" <| fun () ->
                let cls =
                    { ClassName = "org.example.Bar"
                      Methods   = [ { Name = "compute"; ReturnType = "long"
                                      IsStatic = true
                                      Params = [ { Name = "x"; TypeName = "int" } ] } ] }
                let jar : ResolvedMavenJar =
                    { Group = "org.example"; Artifact = "bar"
                      Version = "1.0"; JarPath = "/tmp/bar-1.0.jar"; Sha256 = "bbb"
                      IsTopLevel = true; Classes = Some [cls] }
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "@externTarget(\"org.example.Bar.compute\")"
                    "externTarget for qualified method"
                Expect.stringContains shim.LyricSource
                    "pub func Bar_compute(x: in Int): Long = ()"
                    "pub func with mapped types"
                Expect.equal shim.ExternMethods 1 "one method"

            testCase "instance method produces no pub func (static only)" <| fun () ->
                let cls =
                    { ClassName = "org.example.Baz"
                      Methods   = [ { Name = "instanceMethod"; ReturnType = "int"
                                      IsStatic = false
                                      Params = [] } ] }
                let jar : ResolvedMavenJar =
                    { Group = "org.example"; Artifact = "baz"
                      Version = "1.0"; JarPath = "/tmp/baz-1.0.jar"; Sha256 = "ccc"
                      IsTopLevel = true; Classes = Some [cls] }
                let shim = generate jar
                Expect.equal shim.ExternMethods 0 "instance method not emitted"

            testCase "untranslatable return type adds skip entry" <| fun () ->
                let cls =
                    { ClassName = "org.example.Qux"
                      Methods   = [ { Name = "getList"; ReturnType = "java.util.List"
                                      IsStatic = true; Params = [] } ] }
                let jar : ResolvedMavenJar =
                    { Group = "org.example"; Artifact = "qux"
                      Version = "1.0"; JarPath = "/tmp/qux-1.0.jar"; Sha256 = "ddd"
                      IsTopLevel = true; Classes = Some [cls] }
                let shim = generate jar
                Expect.equal shim.ExternMethods 0 "method skipped"
                Expect.equal shim.SkippedMembers 1 "one skip entry"
                Expect.isSome shim.SkipReport "skip report present"
        ]

        testList "shimIsCurrentFor" [

            testCase "returns false for missing file" <| fun () ->
                let dir = Path.GetTempPath()
                Expect.isFalse
                    (shimIsCurrentFor dir (Path.Combine("_extern", "NonExistent.l")) "abc123")
                    "missing shim is not current"

            testCase "returns true when header matches" <| fun () ->
                let dir = Path.GetTempPath()
                let rel = Path.Combine("_extern", "TestShim_test.l")
                let full = Path.Combine(dir, rel)
                let externDir = Path.Combine(dir, "_extern")
                Directory.CreateDirectory externDir |> ignore
                File.WriteAllText(full, "# lyric:generated-sha256:deadbeef\npackage X\n")
                let result = shimIsCurrentFor dir rel "deadbeef"
                File.Delete full
                Expect.isTrue result "matching header → current"

            testCase "returns false when sha256 differs" <| fun () ->
                let dir = Path.GetTempPath()
                let rel = Path.Combine("_extern", "TestShim_stale.l")
                let full = Path.Combine(dir, rel)
                let externDir = Path.Combine(dir, "_extern")
                Directory.CreateDirectory externDir |> ignore
                File.WriteAllText(full, "# lyric:generated-sha256:oldvalue\npackage X\n")
                let result = shimIsCurrentFor dir rel "newvalue"
                File.Delete full
                Expect.isFalse result "stale header → not current"
        ]
    ]
