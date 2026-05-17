/// Stage B13 smoke test — JDK round-trip class-file reader.
///
/// Uses javac to compile a minimal Probe.java, then runs self_test_b13.l
/// which reads the resulting class file via Std.File.readBytes and passes
/// the bytes to Jvm.Reader.parseClassSummary.  Verifies the magic number
/// is valid and the major version is >= 52 (Java 8 class format).
module Lyric.Emitter.Tests.JvmLoweringB13Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private probeJavaSource =
    "public class Probe { public static void main(String[] args) { System.out.println(\"probe\"); } }"

let private findSelfTestB13Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b13.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private compileProbeClass (outDir: string) : bool =
    try
        Directory.CreateDirectory(outDir) |> ignore
        let javaPath = Path.Combine(outDir, "Probe.java")
        File.WriteAllText(javaPath, probeJavaSource)
        let psi = System.Diagnostics.ProcessStartInfo("javac", $"-d {outDir} {javaPath}")
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError  <- true
        psi.UseShellExecute        <- false
        match System.Diagnostics.Process.Start(psi) |> Option.ofObj with
        | None -> false
        | Some proc ->
            proc.WaitForExit()
            proc.ExitCode = 0
    with _ -> false

let tests =
    testList "Jvm.Driver B13 (JDK round-trip class-file reader)" [

        testCase "b13_reads_jdk_class_file_correctly" <| fun () ->
            let src =
                match findSelfTestB13Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b13.l"

            let outDir = "/tmp/lyric-jvm-b13"
            let compiled = compileProbeClass outDir
            Expect.isTrue compiled
                "javac should compile Probe.java successfully"

            let classPath = Path.Combine(outDir, "Probe.class")
            Expect.isTrue (File.Exists classPath)
                (sprintf "Probe.class should exist at %s" classPath)

            let result, stdout, stderr, exitCode = compileAndRun "jvm_reader_b13" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "read_ok=true"
                (sprintf "expected read_ok=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "magic_valid=true"
                (sprintf "expected magic_valid=true in stdout, got: '%s'" stdout)

            Expect.stringContains stdout "version_ok=true"
                (sprintf "expected version_ok=true (major >= 52) in stdout, got: '%s'" stdout)
    ]
