/// Stage B15 smoke test — instance creation with new + invokespecial.
///
/// Compiles self_test_b15.l which generates a two-class JAR:
///   Greeter.class  has <init>()V and greet()Ljava/lang/String;
///   Main.class     creates a Greeter, calls greet(), prints the result
/// Runs the JAR with `java -jar` and verifies "hello from b15".
/// First test exercising object construction and instance method dispatch.
module Lyric.Emitter.Tests.JvmLoweringB15Test

open System
open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private findSelfTestB15Source () : string option =
    let mutable dir : DirectoryInfo option = Some (DirectoryInfo(AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let candidate = Path.Combine(dir.Value.FullName, "lyric", "jvm", "self_test_b15.l")
        if File.Exists candidate then found <- Some candidate
        dir <- dir.Value.Parent |> Option.ofObj
    found

let private runJar (jarPath: string) : string * int =
    try
        let psi = System.Diagnostics.ProcessStartInfo("java", $"-jar {jarPath}")
        psi.RedirectStandardOutput <- true
        psi.RedirectStandardError  <- true
        psi.UseShellExecute        <- false
        match System.Diagnostics.Process.Start(psi) |> Option.ofObj with
        | None -> "", -1
        | Some proc ->
            let stdout = proc.StandardOutput.ReadToEnd()
            proc.WaitForExit()
            stdout, proc.ExitCode
    with _ -> "", -1

let tests =
    testList "Jvm.Driver B15 (instance creation with invokespecial)" [

        testCase "b15_new_invokespecial_invokevirtual_works" <| fun () ->
            let src =
                match findSelfTestB15Source () with
                | Some path -> File.ReadAllText path
                | None      -> failwith "cannot locate lyric/jvm/self_test_b15.l"

            let result, stdout, stderr, exitCode = compileAndRun "jvm_driver_b15" src

            let errors =
                result.Diagnostics
                |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors
                (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))

            Expect.equal exitCode 0
                (sprintf "Lyric program exit 0 expected (stderr=%s stdout=%s)" stderr stdout)

            Expect.stringContains stdout "jar_written=true"
                (sprintf "expected jar_written=true in stdout, got: '%s'" stdout)

            let jarPath = "/tmp/lyric-jvm-b15/hello.jar"
            Expect.isTrue (File.Exists jarPath)
                (sprintf "expected %s to exist after driver run" jarPath)

            let javaOut, javaExit = runJar jarPath
            Expect.equal javaExit 0
                (sprintf "java -jar expected exit 0, got %d (stdout=%s)" javaExit javaOut)

            Expect.stringContains javaOut "hello from b15"
                (sprintf "expected 'hello from b15' in java output, got: '%s'" javaOut)
    ]
