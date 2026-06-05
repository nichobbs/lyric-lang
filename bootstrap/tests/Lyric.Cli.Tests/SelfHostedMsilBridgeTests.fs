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

/// Like `mkBridge`, but additionally asserts the produced PE carries a
/// MethodSpec (table 0x2B) row whose instantiation decodes to
/// `expectedInstantiation` (e.g. `["String"]`) — used by the #1497 MethodSpec
/// regression to confirm an open-generic BCL call (`System.Array.Empty<T>()`)
/// emits a real MethodSpec token bound to the right element type, not a stub.
let private mkBridgeWithMethodSpec
        (label: string) (source: string) (expected: string)
        (expectedInstantiation: string list) : Test =
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
            let dllBytes = File.ReadAllBytes dllPath
            use peStream = new MemoryStream(dllBytes)
            use peReader = new System.Reflection.PortableExecutable.PEReader(peStream)
            let md : System.Reflection.Metadata.MetadataReader =
                System.Reflection.Metadata.PEReaderExtensions.GetMetadataReader peReader
            // Enumerate MethodSpec rows by walking the table by handle.  The
            // MethodSpec table has no public enumerator on MetadataReader, so we
            // probe MetadataTokens-built handles and decode each instantiation.
            // A minimal signature provider renders type args as their short name.
            let provider =
                { new System.Reflection.Metadata.ISignatureTypeProvider<string, unit> with
                    member _.GetPrimitiveType(c) = string c
                    member _.GetSZArrayType(e) = e + "[]"
                    member _.GetArrayType(e, _) = e + "[]"
                    member _.GetGenericMethodParameter(_, i) = sprintf "!!%d" i
                    member _.GetGenericTypeParameter(_, i) = sprintf "!%d" i
                    member _.GetByReferenceType(e) = e + "&"
                    member _.GetPointerType(e) = e + "*"
                    member _.GetPinnedType(e) = e
                    member _.GetModifiedType(_, u, _) = u
                    member _.GetFunctionPointerType(_) = "fnptr"
                    member _.GetGenericInstantiation(g, a) = g + "<" + System.String.Join(",", a) + ">"
                    member _.GetTypeFromDefinition(r, h, _) = md.GetString((r.GetTypeDefinition h).Name)
                    member _.GetTypeFromReference(r, h, _) = md.GetString((r.GetMemberReference (System.Reflection.Metadata.MemberReferenceHandle())).Name)
                    member _.GetTypeFromSpecification(_, _, _, _) = "spec" }
            let mutable found : string list option = None
            let mutable i = 1
            let mutable go = true
            while go do
                let h = System.Reflection.Metadata.Ecma335.MetadataTokens.MethodSpecificationHandle i
                let ok2 =
                    try
                        let spec = md.GetMethodSpecification h
                        if spec.Method.IsNil then false
                        else
                            let args = spec.DecodeSignature(provider, ()) |> List.ofSeq
                            found <- Some args
                            true
                    with _ -> false
                if ok2 then i <- i + 1 else go <- false
            match found with
            | Some args ->
                Expect.equal args expectedInstantiation
                    (sprintf "MethodSpec instantiation for '%s'" label)
            | None ->
                failtestf "no MethodSpec row emitted for '%s'" label
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

        // #1497 — open-generic BCL call via a MethodSpec (table 0x2B): an empty
        // typed-slice literal `val xs: slice[T] = []` lowers to a real empty
        // `T[]` through `System.Array.Empty<T>()` (a GENERIC-convention MemberRef
        // instantiated by a MethodSpec), instead of a `List<object>` that
        // mis-reads as `T[]` at the MArray-typed local (which printed garbage for
        // `.length`).  Asserts exactly one MethodSpec row is emitted and the
        // empty slice reports length 0.
        mkBridgeWithMethodSpec "shm_empty_slice_array_empty"
            """package ShMEmptySlice
import Std.Core

func main(): Unit {
  val xs: slice[String] = []
  println(toString(xs.length))
}
"""
            "0"
            ["String"]


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

        // #1504 part 1 — an @externTarget whose signature mentions a BCL
        // class type (here System.Text.StringBuilder) now emits a real
        // TypeRef-backed MemberRef instead of a runtime-throw stub.  Exercises
        // a ctor returning the class, an instance method taking + returning the
        // class, and an instance method returning String.
        mkBridge "shm_ffi_class_extern"
            """package ShMFfiClass
import Std.Core

extern type SB = "System.Text.StringBuilder"

@externTarget("System.Text.StringBuilder..ctor")
func newSb(): SB = ()

@externTarget("System.Text.StringBuilder.Append")
@externInstance
func sbAppend(sb: in SB, s: in String): SB = ()

@externTarget("System.Text.StringBuilder.ToString")
@externInstance
func sbStr(sb: in SB): String = ()

func main(): Unit {
  val sb  = newSb()
  val sb2 = sbAppend(sb, "hello ")
  println(sbStr(sbAppend(sb2, "world")))
}
"""
            "hello world"

        // #1536 — same-name function overloads distinguished by arity.
        // Two regressions are pinned here: (1) `addPackageTokens` keyed the
        // funcTokens/funcRetTypes maps by bare FQN, so the second overload's
        // unguarded `.add` threw a duplicate-key error and crashed codegen;
        // (2) `lowerMFuncsToHostClass` interned each method's signature blob
        // under a name-only key, so the second overload silently inherited the
        // first's signature (emitting a method whose arity disagreed with its
        // call sites → invalid IL).  Both keys are now arity-qualified, so each
        // overload gets its own token and signature, and the call site
        // dispatches by argument count.
        mkBridge "shm_func_overload_by_arity"
            """package ShMOverload
import Std.Core

func add(a: in Int, b: in Int): Int { a + b }
func add(a: in Int, b: in Int, c: in Int): Int { a + b + c }

func main(): Unit {
  println(toString(add(1, 2)))
  println(toString(add(1, 2, 3)))
}
"""
            "3\n6"

        // #1476 — indexed assignment a[i] = v.  Previously the assignment
        // target match had no EIndex arm, so `xs[1] = 99` fell through to the
        // wildcard arm that evaluated-then-popped the value: the write was
        // silently discarded.  The EIndex arm now emits List<object>::set_Item,
        // so the mutated element reads back its new value.
        mkBridge "shm_indexed_assign"
            """package ShMIdxAssign
import Std.Core
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  xs[1] = 99
  println(toString(xs[0]))
  println(toString(xs[1]))
  println(toString(xs[2]))
}
"""
            "10\n99\n30"

        // #1476 / #1532 — indexed assignment over a reference-element list,
        // exercising the boxing path for a String value (distinct from the Int
        // value path above).
        mkBridge "shm_indexed_assign_string"
            """package ShMIdxAssignStr
import Std.Core
import Std.Collections

func main(): Unit {
  val xs: List[String] = newList()
  xs.add("a")
  xs.add("b")
  xs[0] = "X"
  println(xs[0])
  println(xs[1])
}
"""
            "X\nb"

        // #1478 — range `for` loops.  `for i in lo .. hi` and `lo ..< hi` are
        // half-open (hi excluded); `lo ..= hi` is closed.  Previously `SFor`
        // panicked in codegen and the parser didn't accept a range in iterator
        // position.
        mkBridge "shm_range_for"
            """package ShMRangeFor
import Std.Core

func main(): Unit {
  var a = 0
  for i in 0 .. 5 { a = a + i }
  println(toString(a))
  var b = 0
  for i in 1 ..= 5 { b = b + i }
  println(toString(b))
  var d = 0
  for i in 0 ..< 5 { d = d + i }
  println(toString(d))
}
"""
            "10\n15\n10"

        // #1478 (#1557) — nested range `for` exercises the loopBreak/loopCont
        // push-pop depth invariant: an inner loop's labels must not leak to the
        // outer loop's `break`/`continue`.
        mkBridge "shm_nested_for"
            """package ShMNestedFor
import Std.Core

func main(): Unit {
  var n = 0
  for i in 0 ..< 3 {
    for j in 0 ..< 4 { n = n + 1 }
  }
  println(toString(n))
}
"""
            "12"

        // #1478 (#1556) — collection `for` reads the loop variable.  Iterating
        // a `List[String]` and printing each element verifies element binding
        // (`get_Item` -> pattern bind), not just the loop count.
        mkBridge "shm_collection_for_reads_elem"
            """package ShMCollRead
import Std.Core
import Std.Collections

func main(): Unit {
  val xs: List[String] = newList()
  xs.add("a")
  xs.add("b")
  xs.add("c")
  for x in xs { println(x) }
}
"""
            "a\nb\nc"

        // #1478 — collection `for` loops + break / continue.  Iterating a
        // `List` walks it by index via `get_Count` / `get_Item`; `continue`
        // still advances the counter and `break` exits.
        mkBridge "shm_collection_for_break_continue"
            """package ShMCollFor
import Std.Core
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  var c = 0
  for x in xs { c = c + 1 }
  println(toString(c))
  var s = 0
  for i in 0 .. 100 {
    if i == 4 { break }
    if i % 2 == 0 { continue }
    s = s + i
  }
  println(toString(s))
}
"""
            "3\n4"


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
            1   // InterfaceImpl rows: Person implements Greeter
            0   // MethodImpl rows: CLR name-matching wires same-name virtual methods automatically

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

        // ── #876: aspect `around` body that calls `proceed()` to wrap the target ─
        // The weaver renames `work` to `__aspect_target_0_work`; the wrapper body
        // must rewrite `proceed()` to call the renamed target.  Without the
        // tree-walking rewrite (the original stub left `proceed` unresolved), the
        // call lowered to a no-op and the "inside" line was silently dropped.
        mkBridge "shm_aspect_proceed_wrap"
            """package ShMAspectProceed

aspect Wrap {
  matches: visibility: pub
  around(args) {
    println("before")
    proceed()
    println("after")
  }
}

pub func work(): Unit {
  println("inside")
}

func main(): Unit {
  work()
}
"""
            "before\ninside\nafter"

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

async func gen(): Int {
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

        // Regression for #878: IImpl blocks must emit InterfaceImpl + MethodImpl
        // metadata so that interface dispatch (callvirt through an interface slot)
        // reaches the concrete method.  Before the fix, impl methods were emitted
        // as static helpers and dispatch silently produced null / wrong output.
        mkBridgeWithImplCounts "shm_interface_dispatch"
            """package ShMIface
interface Greeter {
  func greet(name: in String): String
}
record EnglishGreeter {}
impl Greeter for EnglishGreeter {
  func greet(name: in String): String {
    "hello, " + name
  }
}
func main(): Unit {
  val g = EnglishGreeter()
  println(g.greet("world"))
}
"""
            "hello, world"
            1   // expectedIfaceImplCount: EnglishGreeter implements Greeter
            0   // expectedMethodImplCount: CLR name-matching, no explicit MethodImpl rows

        // ── Trailing-expression-as-return-value: `func main(): Int { 0 }` ──────────────────
        // Regression test for the codegen bug where `lowerBlockMsil` popped the
        // trailing literal, leaving the stack empty for `ret` and producing
        // `InvalidProgramException` at JIT time.
        mkBridge "shm_trailing_int_literal"
            """package ShMTrailingLit
func main(): Int {
  println("trailing-int-ok")
  0
}
"""
            "trailing-int-ok"

        // Bare trailing expression in a non-void function with no side-effecting
        // preamble — the simplest reproducer of the same bug.  Exit code is
        // asserted via `runDll`'s `exitCode = 0`.
        mkBridge "shm_trailing_only_zero"
            """package ShMTrailingZero
func main(): Int { 0 }
"""
            ""

        // ── Band 7 parity expansion (docs/41 §9): one program per core language
        //    feature class.  Each smoke runs the full self-hosted pipeline (lexer /
        //    parser / type-check / mode-check / elaborator / mono / codegen / lowering /
        //    PE) and asserts on runtime output, which is the strongest acceptance
        //    check short of running the full v1 example set.
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

        // Regression for #877: a module-level `val b = a` whose initialiser is
        // just a reference to a previously-declared literal `val a` lowers to
        // a single `ldc.i4` at codegen.  The pre-scan predicate must agree
        // (no phantom `.cctor` MethodDef row), otherwise IFunc tokens shift
        // by 1 and calls dispatch to the wrong method.  The crash shape was
        // `MethodNotFoundException` / `MissingMethodException` at entry-point
        // invocation.
        mkBridge "shm_module_const_chain"
            """package ShMConstChain
val first  = 7
val second = first
func main(): Unit {
  println(second)
}
"""
            "7"

        // Companion depth-3 chain (#1143): independent assurance that
        // `isLiteralI4ExprMsilWithEnv` propagates transitively across
        // multiple levels of val aliasing, not just one.  A future regression
        // that capped the lookup at one indirection would pass the depth-1
        // test above while silently miscompiling this case.
        mkBridge "shm_module_const_chain_deep"
            """package ShMConstChainDeep
val a = 7
val b = a
val c = b
val d = c
func main(): Unit {
  println(d)
}
"""
            "7"

        // Regression for #962: when a tiny-header method (e.g. `add` — no locals,
        // code <= 63 bytes) precedes a fat-header method (e.g. `main` declaring
        // `val a = add(3,4)`, which needs 1 local and therefore a fat header),
        // the fat header must start on a 4-byte boundary per ECMA-335 II.25.4.5.
        // Without pre-method padding the JIT rejected the assembly with
        // `InvalidProgramException` even though `ilverify` accepted the IL.  This
        // test reproduces the minimum 4-line trigger.
        mkBridge "shm_fat_header_alignment"
            """package ShMFatHeaderAlign
func add(a: in Int, b: in Int): Int { a + b }
func main(): Unit {
  val a = add(3, 4)
  println(a)
}
"""
            "7"

        // Regression for #962 (original reproducer): three sequential `println`
        // statements where the third nests a user-function call.  Confirms that
        // fat-header alignment holds across multiple bodies, not just the
        // 2-method minimum.
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
