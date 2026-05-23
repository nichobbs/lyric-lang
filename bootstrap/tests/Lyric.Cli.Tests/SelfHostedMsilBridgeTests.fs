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

/// Compile `source` via the self-hosted MSIL bridge, run it, and additionally
/// reflect over the produced DLL with `System.Reflection.Metadata` to assert
/// that the InterfaceImpl table contains `expectedIfaceImplCount` rows and the
/// MethodImpl table contains `expectedMethodImplCount` rows.  Used by the
/// #878 regression to verify the MPImpl wiring landed real `InterfaceImpl` +
/// `MethodImpl` rows instead of silently dropping them.
let private mkBridgeWithImplCounts
        (label: string) (source: string) (expected: string)
        (expectedIfaceImplCount: int) (expectedMethodImplCount: int) : Test =
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
            // Inspect metadata BEFORE running so we report row counts even if
            // the runtime fails (which itself signals a structural problem).
            let dllBytes = File.ReadAllBytes dllPath
            use peStream = new MemoryStream(dllBytes)
            use peReader = new System.Reflection.PortableExecutable.PEReader(peStream)
            let mdReader : System.Reflection.Metadata.MetadataReader =
                System.Reflection.Metadata.PEReaderExtensions.GetMetadataReader peReader
            // Both InterfaceImpl and MethodImpl rows are reachable through the
            // owning TypeDef: a TypeDef's `GetInterfaceImplementations()` lists
            // its InterfaceImpl rows and `GetMethodImplementations()` lists
            // its MethodImpl rows.  Sum across every TypeDef in the assembly.
            let mutable ifaceImplRows  = 0
            let mutable methodImplRows = 0
            for tdHandle in mdReader.TypeDefinitions do
                let td = mdReader.GetTypeDefinition(tdHandle)
                ifaceImplRows  <- ifaceImplRows  + td.GetInterfaceImplementations().Count
                methodImplRows <- methodImplRows + td.GetMethodImplementations().Count
            Expect.equal ifaceImplRows expectedIfaceImplCount
                (sprintf "InterfaceImpl row count for '%s'" label)
            Expect.equal methodImplRows expectedMethodImplCount
                (sprintf "MethodImpl row count for '%s'" label)
            let stdout, stderr, exitCode = runDll dllPath
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) expected
                (sprintf "stdout matches expected for '%s'" label)
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

        // ── Band 2 (#849): IEnum → CLR int enum TypeDef ───────────────────────
        // Enum cases use the `case Name` syntax (no value list on one line).
        mkBridge "shm_enum_smoke"
            """package ShMEnum

enum Color {
  case Red
  case Green
  case Blue
}

func main(): Unit {
  println("enum ok")
}
"""
            "enum ok"

        // ── Band 2 (#850): IVal → static init-only field; literal val inlines ──
        // `val ANSWER: Int = 42` produces a single ldc.i4 init, which the
        // codegen inlines into constValues so `println(ANSWER)` emits ldc.i4 42.
        mkBridge "shm_const_int"
            """package ShMConst

val ANSWER: Int = 42

func main(): Unit {
  println(ANSWER)
}
"""
            "42"

        // ── Band 2 (#850): IVal with non-literal init → static .cctor ────────
        mkBridge "shm_val_cctor"
            """package ShMVal

val COMPUTED: Int = 10 + 5

func main(): Unit {
  println("val ok")
}
"""
            "val ok"

        // ── Band 2 (#853): IInterface → CLR interface TypeDef ────────────────
        mkBridge "shm_interface_smoke"
            """package ShMIface

interface Greeter {
  func greet(name: in String): String
}

func main(): Unit {
  println("interface ok")
}
"""
            "interface ok"

        // ── #878 Regression: IImpl emits MPImpl + InterfaceImpl/MethodImpl ──
        // Before #878, the IImpl handler folded impl funcs into the host class
        // as static methods and never created an `MPImpl` package item.  The
        // resulting DLL carried no `InterfaceImpl` row for `Greeter`-on-Person`,
        // and no `MethodImpl` row binding `greet` to its implementation, so
        // the CLR could not bind interface dispatch even if a caller tried.
        //
        // This regression test compiles a program with an interface, a record,
        // and an `impl` block, then inspects the resulting DLL with
        // `System.Reflection.Metadata` to assert that the InterfaceImpl table
        // has exactly 1 row and the MethodImpl table has exactly 1 row.  It
        // also runs the DLL to confirm the metadata is well-formed enough to
        // load `Person` (which would otherwise throw `TypeLoadException`).
        mkBridgeWithImplCounts "shm_impl_metadata"
            """package ShMImpl

interface Greeter {
  func greet(): String
}

record Person { age: Int }

impl Greeter for Person {
  func greet(): String { "hello" }
}

func main(): Unit {
  val p = Person(age = 30)
  println("impl-metadata-ok")
}
"""
            "impl-metadata-ok"
            1   // InterfaceImpl rows
            1   // MethodImpl rows

        // ── Band 2 (#853): IOpaque → sealed TypeDef with private fields + .ctor ─
        // Opaque field syntax is `fieldName: Type` (no `val` keyword).
        mkBridge "shm_opaque_smoke"
            """package ShMOpaque

opaque type Token {
  raw: String
}

func main(): Unit {
  println("opaque ok")
}
"""
            "opaque ok"

        // ── Band 2 (#855): IAspect + aspect weaver ────────────────────────────
        // The weaver runs before addPackageTokens so that `doWork` in funcTokens
        // points to the synthesised wrapper.  The wrapper's body is the aspect's
        // `around` block; `main` calls `doWork()` which dispatches to the wrapper.
        mkBridge "shm_aspect_weave"
            """package ShMAspect

aspect Shim {
  matches: visibility: pub
  around(args) {
    println("shim ran")
  }
}

pub func doWork(): Unit {
  println("original")
}

func main(): Unit {
  doWork()
}
"""
            "shim ran"

        // ── Band 2 (#855): IProtected → Monitor-based record (bootstrap: regular record) ─
        // Protected fields use `var` / `let`; entries use `entry name(params): Ret { body }`.
        mkBridge "shm_protected_smoke"
            """package ShMProtected

protected type Counter {
  var count: Int = 0
  entry increment(): Unit {
    count = count + 1
  }
}

func main(): Unit {
  println("protected ok")
}
"""
            "protected ok"

        // ── Band 2 (R6): ELambda — non-capturing lambda lifted to static method ──────────
        // Zero-arg lambda: newobj System.Action::.ctor; f() → callvirt Action::Invoke().
        mkBridge "shm_lambda_non_capturing"
            """package ShMLambda

func main(): Unit {
  val f = { println("lambda ok") }
  f()
}
"""
            "lambda ok"

        // 1-param lambda: newobj System.Action`1<object>::.ctor; f(x) → callvirt Action`1<object>::Invoke(object).
        mkBridge "shm_lambda_one_param"
            """package ShMLambdaP

func main(): Unit {
  val g = { x: Int -> println("param ok") }
  g(99)
}
"""
            "param ok"

        // ── Band 2 (R6): EYield — collect-all generator model ────────────────────────────
        // async func with yield is detected by isAsync && funcBodyContainsYield.
        // Lowered as: allocate List<object> collector, each yield appends to it,
        // return collector at end (return type = MObject regardless of annotation).
        // Reads items.count to verify all 3 yielded values were collected.
        mkBridge "shm_yield_collect"
            """package ShMYield

async func gen(): Object {
  yield 1
  yield 2
  yield 3
}

func main(): Unit {
  val items = gen()
  println(items.count)
}
"""
            "3"

        // ── Band 2 (R6): Auto-FFI — extern type method resolution without @externTarget ──
        // Calls System.GC.Collect() (void, no-arg static) via the auto-FFI path to
        // verify that emitAutoFfiCallMsil emits a valid static `call` (not callvirt).
        // Bootstrap-grade auto-FFI uses () : void sig; non-void returns require @externTarget.
        mkBridge "shm_extern_type_smoke"
            """package ShMExternType

extern type GCHelper = "System.GC"

func main(): Unit {
  GCHelper.Collect()
  println("extern type ok")
}
"""
            "extern type ok"
    ]
