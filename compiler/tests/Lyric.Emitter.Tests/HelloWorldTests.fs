module Lyric.Emitter.Tests.HelloWorldTests

open System
open System.Diagnostics
open System.IO
open Expecto
open Lyric.Emitter.Emitter

/// Resolve the dotnet host. The CI environment usually has it on
/// PATH; the development sandbox here installs it under
/// `/root/.dotnet/dotnet`. Falling back to that path keeps tests
/// portable across both.
let private dotnetHost () : string =
    let envPath = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
    match Option.ofObj envPath with
    | Some p when File.Exists p -> p
    | _ ->
        let primary = "/root/.dotnet/dotnet"
        if File.Exists primary then primary
        else "dotnet"

/// `dotnet exec` the produced .dll so we observe the actual runtime
/// behaviour rather than just inspect the metadata. Returns the
/// stdout / stderr / exit code triple.
let private runDll (dll: string) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- dotnetHost ()
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add dll
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute         <- false
    psi.CreateNoWindow          <- true
    let proc =
        match Option.ofObj (Process.Start(psi)) with
        | Some p -> p
        | None   -> failwith "failed to start dotnet process"
    use _ = proc
    let stdout = proc.StandardOutput.ReadToEnd()
    let stderr = proc.StandardError.ReadToEnd()
    proc.WaitForExit()
    stdout, stderr, proc.ExitCode

/// The path to the in-tree Lyric.Stdlib.dll. The emitted assembly
/// references types in that DLL, so it has to sit alongside the
/// emitted PE for `dotnet exec` to load it.
let private stdlibDll () : string =
    let baseDir = AppContext.BaseDirectory
    Path.Combine(baseDir, "Lyric.Stdlib.dll")

/// Drop the produced .dll into a fresh subdirectory and copy the
/// stdlib next to it, so the runtime probing finds both.
let private prepareOutputDir (name: string) : string =
    let dir = Path.Combine(Path.GetTempPath(), "lyric-emit-" + name + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    File.Copy(stdlibDll (), Path.Combine(dir, "Lyric.Stdlib.dll"), overwrite = true)
    dir

/// E1 hard requirement: `func main(): Unit { println("hello") }`
/// compiles, runs, and prints `hello\n`.
let tests =
    testSequenced
    <| testList "hello-world (E1)" [

        test "main calling println('hello') runs and prints hello" {
            let outDir = prepareOutputDir "hello"
            let dll    = Path.Combine(outDir, "Hello.dll")
            let req =
                { Source       = """
package Hello
func main(): Unit { println("hello") }
"""
                  AssemblyName = "Hello"
                  OutputPath   = dll }
            let r = emit req
            Expect.isEmpty
                (r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E"))
                "no emitter-side diagnostics"
            Expect.isSome r.OutputPath "produced an output path"
            Expect.isTrue (File.Exists dll) "output dll exists on disk"
            let cfg = Path.ChangeExtension(dll, "runtimeconfig.json")
            Expect.isTrue (File.Exists cfg) "runtimeconfig present"
            let stdout, stderr, exitCode = runDll dll
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr was: %s)" stderr)
            Expect.stringContains stdout "hello"
                "stdout contains the printed line"
        }

        test "expression-bodied main with println also runs" {
            let outDir = prepareOutputDir "hello-expr"
            let dll    = Path.Combine(outDir, "HelloExpr.dll")
            let req =
                { Source       = """
package HelloExpr
func main(): Unit = println("from expr body")
"""
                  AssemblyName = "HelloExpr"
                  OutputPath   = dll }
            let r = emit req
            Expect.isSome r.OutputPath "produced an output path"
            let stdout, stderr, exitCode = runDll dll
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr was: %s)" stderr)
            Expect.stringContains stdout "from expr body"
                "expr-bodied main runs"
        }
    ]
