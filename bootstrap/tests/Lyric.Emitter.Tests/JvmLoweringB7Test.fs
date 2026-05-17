/// Stage B7 smoke test — native-image config file generation.
///
/// Compiles lyric/jvm/self_test_b7.l, runs it (which writes
/// 4 JSON config files to /tmp/lyric-jvm-b7/), then verifies each file
/// exists and contains the expected JSON structure.
/// No GraalVM installation is required.
module Lyric.Emitter.Tests.JvmLoweringB7Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

let private findSelfTestB7Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b7.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

let tests =
    testList "Jvm.NativeImage B7 (native-image config generation)" [

        testCase "b7_native_image_configs_are_written_and_well_formed" <| fun () ->
            let src =
                match findSelfTestB7Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b7.l"

            // 1. Compile and run the Lyric program (writes four JSON files).
            let result, stdout, stderr, exitCode = compileAndRun "jvm_nativeimage_b7" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            // 2. Verify all four files exist.
            let outDir = "/tmp/lyric-jvm-b7"
            for name in ["reflect-config.json"; "resource-config.json"; "proxy-config.json"; "jni-config.json"] do
                let path = Path.Combine(outDir, name)
                Expect.isTrue (File.Exists path) (sprintf "%s was not written" name)

            // 3. reflect-config.json must be an empty JSON array.
            let reflectContent = File.ReadAllText(Path.Combine(outDir, "reflect-config.json"))
            Expect.stringContains reflectContent "[]"
                (sprintf "reflect-config.json should be empty array, got: %s" reflectContent)

            // 4. resource-config.json must reference the lyric-contract pattern and the package name.
            let resourceContent = File.ReadAllText(Path.Combine(outDir, "resource-config.json"))
            Expect.stringContains resourceContent "lyric-contract"
                (sprintf "resource-config.json should mention lyric-contract, got: %s" resourceContent)
            Expect.stringContains resourceContent "TestPkg"
                (sprintf "resource-config.json should mention TestPkg, got: %s" resourceContent)

            // 5. proxy-config.json must contain "proxies".
            let proxyContent = File.ReadAllText(Path.Combine(outDir, "proxy-config.json"))
            Expect.stringContains proxyContent "proxies"
                (sprintf "proxy-config.json malformed: %s" proxyContent)

            // 6. jni-config.json must contain "jni".
            let jniContent = File.ReadAllText(Path.Combine(outDir, "jni-config.json"))
            Expect.stringContains jniContent "jni"
                (sprintf "jni-config.json malformed: %s" jniContent)
    ]
