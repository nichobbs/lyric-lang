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

        // ── Trailing-expression-as-return-value: `func main(): Int { 0 }` ─
        // Regression test for the codegen bug where `lowerBlockMsil`
        // popped the trailing literal, leaving the stack empty for
        // `ret` and producing `InvalidProgramException` at JIT time.
        mkBridge "shm_trailing_int_literal"
            """package ShMTrailingLit
func main(): Int {
  println("trailing-int-ok")
  0
}
"""
            "trailing-int-ok"

        // Bare trailing expression in a non-void function with no
        // side-effecting preamble — the simplest reproducer of the
        // same bug.  Exit code is asserted via `runDll`'s `exitCode = 0`.
        mkBridge "shm_trailing_only_zero"
            """package ShMTrailingZero
func main(): Int { 0 }
"""
            ""

        // ── Band 7 parity expansion (docs/41 §9): one program per core
        //    language feature class.  Each smoke runs the full
        //    self-hosted pipeline (lexer / parser / type-check / mode-check
        //    / elaborator / mono / codegen / lowering / PE) and asserts on
        //    runtime output, which is the strongest acceptance check
        //    short of running the full v1 example set.

        mkBridge "shm_if_else_chain"
            """package ShMIfElse
func classify(n: in Int): String {
  if n < 0 {
    "negative"
  } else if n == 0 {
    "zero"
  } else {
    "positive"
  }
}
func main(): Unit {
  println(classify(-5))
  println(classify(0))
  println(classify(42))
}
"""
            "negative\nzero\npositive"

        mkBridge "shm_match_int_with_wildcard"
            """package ShMMatchInt
func describe(n: in Int): String {
  match n {
    case 0 -> "zero"
    case 1 -> "one"
    case _ -> "other"
  }
}
func main(): Unit {
  println(describe(0))
  println(describe(1))
  println(describe(42))
}
"""
            "zero\none\nother"

        mkBridge "shm_recursion_factorial"
            """package ShMRecursion
func factorial(n: in Int): Int {
  if n <= 1 {
    1
  } else {
    n * factorial(n - 1)
  }
}
func main(): Unit {
  println(factorial(5))
  println(factorial(10))
}
"""
            "120\n3628800"

        mkBridge "shm_string_concat"
            """package ShMStringConcat
func greet(name: in String): String {
  "hello, " + name + "!"
}
func main(): Unit {
  println(greet("world"))
  println(greet("lyric"))
}
"""
            "hello, world!\nhello, lyric!"

        mkBridge "shm_int_arithmetic"
            """package ShMIntArith
func main(): Unit {
  val a = 17
  val b = 5
  println(a + b)
  println(a - b)
  println(a * b)
  println(a / b)
  println(a % b)
}
"""
            "22\n12\n85\n3\n2"

        // Regression for #877: a module-level `val b = a` whose
        // initialiser is just a reference to a previously-declared
        // literal `val a` lowers to a single `ldc.i4` at codegen.
        // The pre-scan predicate must agree (no phantom `.cctor`
        // MethodDef row), otherwise IFunc tokens shift by 1 and
        // calls dispatch to the wrong method.  The crash shape was
        // `MethodNotFoundException` / `MissingMethodException` at
        // entry-point invocation.
        mkBridge "shm_module_const_chain"
            """package ShMConstChain
val first  = 7
val second = first
func main(): Unit {
  println(second)
}
"""
            "7"

        // Regression for #962: when a tiny-header method (e.g. `add` —
        // no locals, code <= 63 bytes) precedes a fat-header method
        // (e.g. `main` declaring `val a = add(3,4)`, which needs 1
        // local and therefore a fat header), the fat header must
        // start on a 4-byte boundary per ECMA-335 II.25.4.5.  Without
        // pre-method padding the JIT rejected the assembly with
        // `InvalidProgramException` even though `ilverify` accepted
        // the IL.  This test reproduces the minimum 4-line trigger.
        mkBridge "shm_fat_header_alignment"
            """package ShMFatHeaderAlign
func add(a: in Int, b: in Int): Int { a + b }
func main(): Unit {
  val a = add(3, 4)
  println(a)
}
"""
            "7"

        // Regression for #962 (original reproducer): three sequential
        // `println` statements where the third nests a user-function
        // call.  Confirms that fat-header alignment holds across
        // multiple bodies, not just the 2-method minimum.
        mkBridge "shm_fat_header_three_println"
            """package ShMFatHeaderThreePrintln
func add(a: in Int, b: in Int): Int { a + b }
func square(n: in Int): Int { n * n }
func main(): Unit {
  println(add(3, 4))
  println(square(7))
  println(add(square(2), square(3)))
}
"""
            "7\n49\n13"
    ]
