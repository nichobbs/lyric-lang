module Lyric.Cli.Tests.MavenTests

open System.IO
open Expecto
open Lyric.Cli.Maven
open Lyric.Cli.MavenShim

// Convenience: build a JavaMethod without boilerplate.
let private staticMethod name ret (ps: (string * string) list) =
    { Name = name; ReturnType = ret; IsStatic = true; HasCheckedExceptions = false
      Params = ps |> List.map (fun (n, t) -> { Name = n; TypeName = t }) }

let private instanceMethod name ret (ps: (string * string) list) =
    { Name = name; ReturnType = ret; IsStatic = false; HasCheckedExceptions = false
      Params = ps |> List.map (fun (n, t) -> { Name = n; TypeName = t }) }

let private checkedMethod name ret (ps: (string * string) list) =
    { Name = name; ReturnType = ret; IsStatic = false; HasCheckedExceptions = true
      Params = ps |> List.map (fun (n, t) -> { Name = n; TypeName = t }) }

let private checkedStaticMethod name ret (ps: (string * string) list) =
    { Name = name; ReturnType = ret; IsStatic = true; HasCheckedExceptions = true
      Params = ps |> List.map (fun (n, t) -> { Name = n; TypeName = t }) }

let private mkJar group art ver classes =
    { Group = group; Artifact = art; Version = ver
      JarPath = sprintf "/tmp/%s-%s.jar" art ver; Sha256 = "aaa"
      IsTopLevel = true; Classes = classes }

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
                Expect.equal
                    (lyricPackageName "com.example" "my-lib")
                    "ComExample.MyLib"
                    "hyphen in artifact"

            testCase "guava base case" <| fun () ->
                Expect.equal
                    (lyricPackageName "com.google.guava" "guava")
                    "ComGoogleGuava.Guava"
                    "guava base case"
        ]

        testList "MavenShim.generate" [

            testCase "shim header carries sha256 drift marker" <| fun () ->
                let jar = mkJar "org.slf4j" "slf4j-api" "2.0.13" None
                let jar = { jar with Sha256 = "abcdef1234567890" }
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "# lyric:generated-sha256:abcdef1234567890"
                    "B0053 drift-detection header"

            testCase "shim carries @axiom with Maven coordinate" <| fun () ->
                let jar = mkJar "org.slf4j" "slf4j-api" "2.0.13" None
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "@axiom(\"from Maven org.slf4j:slf4j-api v2.0.13\")"
                    "axiom carries full Maven coordinate"

            testCase "shim package name derived from coordinate" <| fun () ->
                let jar = mkJar "com.fasterxml.jackson.core" "jackson-databind" "2.17.0" None
                let shim = generate jar
                Expect.equal shim.LyricPackage
                    "ComFasterxmlJacksonCore.JacksonDatabind"
                    "Lyric package name"
                Expect.stringContains shim.LyricSource
                    "package ComFasterxmlJacksonCore.JacksonDatabind"
                    "package declaration in source"

            testCase "relative path uses PascalGroup_PascalArtifact.l" <| fun () ->
                let jar = mkJar "org.slf4j" "slf4j-api" "2.0.13" None
                let shim = generate jar
                Expect.equal shim.RelativePath
                    (Path.Combine("_extern", "OrgSlf4j_Slf4jApi.l"))
                    "relative path convention"

            testCase "classes=None emits unloadable-artifact comment" <| fun () ->
                let jar = mkJar "org.example" "native-lib" "1.0" None
                let shim = generate jar
                Expect.stringContains shim.LyricSource "Resolver could not"
                    "note about unloadable JAR"
                Expect.equal shim.ExternTypes 0 "no extern types"
                Expect.equal shim.ExternMethods 0 "no methods"

            testCase "extern type block emitted for public classes" <| fun () ->
                let cls = { ClassName = "org.example.Foo"
                            Methods = [ staticMethod "doIt" "int" ["n", "int"] ] }
                let jar = mkJar "org.example" "mylib" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "extern type Foo = \"org.example.Foo\""
                    "extern type declaration"
                Expect.equal shim.ExternTypes 1 "one extern type"

            testCase "static method emits TypeName_method stub" <| fun () ->
                let cls = { ClassName = "org.example.Bar"
                            Methods = [ staticMethod "compute" "long" ["x", "int"] ] }
                let jar = mkJar "org.example" "bar" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "@externTarget(\"org.example.Bar.compute\")"
                    "externTarget for static method"
                Expect.stringContains shim.LyricSource
                    "pub func Bar_compute(x: in Int): Long = ()"
                    "static stub naming convention"
                Expect.equal shim.ExternMethods 1 "one method"

            testCase "instance method emits receiver as first in-param" <| fun () ->
                let cls = { ClassName = "org.example.Conn"
                            Methods = [ instanceMethod "close" "void" [] ] }
                let jar = mkJar "org.example" "mydb" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "@externTarget(\"org.example.Conn.close\")"
                    "externTarget for instance method"
                Expect.stringContains shim.LyricSource
                    "pub func close(conn: in Conn): Unit = ()"
                    "receiver as first in-param, method name unqualified"
                Expect.equal shim.ExternMethods 1 "one instance method emitted"

            testCase "instance method with params appends args after receiver" <| fun () ->
                let cls = { ClassName = "org.example.Stmt"
                            Methods = [ instanceMethod "execute" "boolean"
                                            ["sql", "java.lang.String"] ] }
                let jar = mkJar "org.example" "jdbc" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "pub func execute(stmt: in Stmt, sql: in String): Bool = ()"
                    "receiver then regular params"

            testCase "checked-exception method wraps return in Result" <| fun () ->
                let cls = { ClassName = "org.example.IO"
                            Methods = [ checkedStaticMethod "readFile" "java.lang.String"
                                            ["path", "java.lang.String"] ] }
                let jar = mkJar "org.example" "myio" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "pub func IO_readFile(path: in String): Result[String, JvmException] = ()"
                    "checked exception wraps return in Result"

            testCase "checked-exception void method wraps as Result[Unit, JvmException]" <| fun () ->
                let cls = { ClassName = "org.example.Closer"
                            Methods = [ { Name = "close"; ReturnType = "void"
                                          IsStatic = false; HasCheckedExceptions = true
                                          Params = [] } ] }
                let jar = mkJar "org.example" "closer" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "Result[Unit, JvmException]"
                    "void + checked → Result[Unit, JvmException]"

            testCase "shim imports JvmExceptionHost when checked exceptions present" <| fun () ->
                let cls = { ClassName = "org.example.X"
                            Methods = [ checkedMethod "go" "int" [] ] }
                let jar = mkJar "org.example" "x" "1.0" (Some [cls])
                let shim = generate jar
                Expect.stringContains shim.LyricSource
                    "import Std.JvmExceptionHost"
                    "import added when checked exceptions present"

            testCase "no JvmExceptionHost import when no checked exceptions" <| fun () ->
                let cls = { ClassName = "org.example.Y"
                            Methods = [ staticMethod "add" "int" ["a","int"; "b","int"] ] }
                let jar = mkJar "org.example" "y" "1.0" (Some [cls])
                let shim = generate jar
                Expect.isFalse (shim.LyricSource.Contains "JvmExceptionHost")
                    "no import when no checked exceptions"

            testCase "untranslatable return type adds skip entry" <| fun () ->
                let cls = { ClassName = "org.example.Qux"
                            Methods = [ staticMethod "getList" "java.util.List" [] ] }
                let jar = mkJar "org.example" "qux" "1.0" (Some [cls])
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
