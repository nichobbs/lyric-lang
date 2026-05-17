/// Stage B11 smoke test — ZIP/JAR assembler.
///
/// Compiles lyric-compiler/jvm/self_test_b11.l, runs it (which generates
/// /tmp/lyric-jvm-b11/hello.jar containing MANIFEST.MF + Hello.class),
/// verifies the ZIP magic bytes and written-flag, then runs
/// `unzip -l` to confirm both entries appear in the listing.
module Lyric.Emitter.Tests.JvmLoweringB11Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB11Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric-compiler", "jvm", "self_test_b11.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private runUnzipL (jarPath: string) : string =
    try
        let psi = System.Diagnostics.ProcessStartInfo("unzip", $"-l {jarPath}")
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError  <- true
        psi.UseShellExecute        <- false
        match System.Diagnostics.Process.Start(psi) |> Option.ofObj with
        | None      -> ""
        | Some proc ->
            let out = proc.StandardOutput.ReadToEnd()
            proc.WaitForExit()
            out
    with _ -> ""

let tests =
    testList "Jvm.Zip B11 (ZIP/JAR assembler)" [

        testCase "b11_jar_assembler_produces_valid_zip" <| fun () ->
            let src =
                match findSelfTestB11Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric-compiler/jvm/self_test_b11.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_zip_b11" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "zip_magic_ok=true"
                (sprintf "expected zip_magic_ok=true in stdout, got: '%s'" stdout)

            // Verify both entries appear when listed with unzip.
            let jarPath = "/tmp/lyric-jvm-b11/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist" jarPath)

            let listing = runUnzipL jarPath
            Expect.stringContains listing "MANIFEST.MF"
                (sprintf "expected MANIFEST.MF in unzip listing, got: '%s'" listing)

            Expect.stringContains listing "Hello.class"
                (sprintf "expected Hello.class in unzip listing, got: '%s'" listing)
    ]
