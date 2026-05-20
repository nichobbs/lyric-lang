/// End-to-end tests for the self-hosted MSIL bridge (`Lyric.Cli.SelfHostedMsil`).
/// Compiles Lyric programs through the full self-hosted pipeline
/// (lexer → parser → codegen → MSIL lowering → PE) and executes the
/// resulting DLL, asserting on stdout output.
module Lyric.Cli.Tests.SelfHostedMsilBridgeTests

open System
open System.IO
open System.Diagnostics
open Expecto
open Lyric.Cli

/// Run a .dll produced by the self-hosted emitter and return (stdout, stderr, exitCode).
let private runDll (dll: string) : string * string * int =
    let dotnet =
        let env = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
        match Option.ofObj env with
        | Some p when File.Exists p -> p
        | _ ->
            let p = "/root/.dotnet/dotnet"
            if File.Exists p then p else "dotnet"
    let psi = ProcessStartInfo()
    psi.FileName <- dotnet
    psi.ArgumentList.Add "exec"
    psi.ArgumentList.Add dll
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute         <- false
    psi.CreateNoWindow          <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None   -> failwith "failed to start dotnet process"
    use _ = proc
    let stdoutTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardOutput.ReadToEnd())
    let stderrTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardError.ReadToEnd())
    let exited = proc.WaitForExit(60_000)
    if not exited then
        try proc.Kill() with _ -> ()
        proc.WaitForExit()
    stdoutTask.Result, stderrTask.Result, proc.ExitCode

/// Compile `source` via the self-hosted MSIL bridge, run it, and check
/// that stdout (trimmed) equals `expected`.
let private mkBridge (label: string) (source: string) (expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let dir = Path.Combine(Path.GetTempPath(), "lyric-msil-bridge-test-" + label + "-" + Guid.NewGuid().ToString("N"))
        Directory.CreateDirectory dir |> ignore
        try
            let dllPath = Path.Combine(dir, label + ".dll")
            let ok = SelfHostedMsil.compileToDll source dllPath
            Expect.isTrue ok
                (sprintf "self-hosted MSIL compile succeeded for '%s'" label)
            Expect.isTrue (File.Exists dllPath)
                (sprintf "output DLL exists at %s" dllPath)
            let stdout, stderr, exitCode = runDll dllPath
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) expected
                (sprintf "stdout matches expected for '%s'" label)
        finally
            try Directory.Delete(dir, recursive = true) with _ -> ()

/// Compile `source` via the self-hosted MSIL bridge and assert that the
/// compile FAILS — used to verify Band 1 middle-end gating (mode checker
/// catches V-codes, parse errors abort, etc.).
let private mkBridgeFails (label: string) (source: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let dir = Path.Combine(Path.GetTempPath(), "lyric-msil-bridge-test-" + label + "-" + Guid.NewGuid().ToString("N"))
        Directory.CreateDirectory dir |> ignore
        try
            let dllPath = Path.Combine(dir, label + ".dll")
            let ok = SelfHostedMsil.compileToDll source dllPath
            Expect.isFalse ok
                (sprintf "self-hosted MSIL compile should fail for '%s' (Band 1 gating)" label)
        finally
            try Directory.Delete(dir, recursive = true) with _ -> ()

let tests =
    testSequenced
    <| testList "SelfHostedMsil bridge (codegen end-to-end)" [

        mkBridge "shm_hello"
            """package ShMHello
func main(): Unit {
  println("hello from self-hosted")
}
"""
            "hello from self-hosted"

        mkBridge "shm_while_basic"
            """package ShMWhile
func main(): Unit {
  var i = 0
  while i < 5 {
    i = i + 1
  }
  println(i)
}
"""
            "5"

        mkBridge "shm_break_early"
            """package ShMBreak
func main(): Unit {
  var i = 0
  while i < 100 {
    if i == 5 { break }
    i = i + 1
  }
  println(i)
}
"""
            "5"

        mkBridge "shm_continue_skip_evens"
            """package ShMCont
func main(): Unit {
  var i = 0
  var oddSum = 0
  while i < 10 {
    i = i + 1
    if i % 2 == 0 { continue }
    oddSum = oddSum + i
  }
  println(oddSum)
}
"""
            "25"

        mkBridge "shm_nested_while_break"
            """package ShMNested
func main(): Unit {
  var i = 0
  var total = 0
  while i < 5 {
    var j = 0
    while j < 5 {
      if j == 3 { break }
      total = total + 1
      j = j + 1
    }
    i = i + 1
  }
  println(total)
}
"""
            "15"

        mkBridge "shm_newList_add_count"
            """package ShMList
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  println(xs.count)
}
"""
            "3"

        // ── Band 1 (docs/41 §9) — middle-end gating ───────────────────────────

        // The mode checker now runs from the bridge.  An @axiom function with
        // a body is V0004; without Band 1's wiring the bridge silently emitted
        // a DLL anyway.
        mkBridgeFails "shm_mode_check_v0004"
            """@proof_required
package ShMVerify

@axiom
func aboveSafe(x: in Int): Bool {
  x > 0
}

func main(): Unit { }
"""

        // Parse errors must also abort the bridge before codegen — verifies
        // the new `reportAndAbort` plumbing.
        mkBridgeFails "shm_parse_error"
            """package ShMParse

func main(): Unit {
  val x = 1 +
}
"""
    ]
