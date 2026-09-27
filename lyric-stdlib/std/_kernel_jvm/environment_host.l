//! std/_kernel_jvm/environment_host.l - JVM host boundary for process state.
//!
//! Mirrors _kernel/environment_host.l for the JVM target.  Pure Lyric over
//! JVM auto-FFI against `java.lang.System`, replacing a `lyric.stdlib.jvm.
//! EnvHost` shim class that never existed at runtime (the `extern package`
//! mechanism it used is a no-op in both the type checker and both codegens
//! -- same elimination as the `console_host.l` / `time_host.l` /
//! `collections_host.l` / `file_host.l` rewrites).
//!
//! `System.getenv(String)` returns null on a missing key, mapped to `None`
//! by `hostGetVarOpt` below (matching the .NET kernel's `??`-based Option
//! seam).
//!
//! `hostExit` calls `System.exit(int)` directly: `Never` erases to `void`
//! on the JVM (`Jvm.Codegen.typeExprToJvm`), which is exactly `System.exit`'s
//! real return type, so no "throw after call" trick is needed.
//!
//! `hostGetCommandLineArgs` has no extern-bindable host equivalent: unlike
//! .NET's `System.Environment.GetCommandLineArgs()`, the JDK exposes no
//! process-wide argv retrieval API. Issue #5377 closed this with new JVM
//! codegen instead of an extern binding: `Jvm.Codegen`'s `hasMain`
//! entry-point synthesis (`codegen/06_items.l`) stores the incoming
//! `String[]` into a package-independent holder class
//! (`__LyricJvmRuntime.commandLineArgs`, `LPRuntimeArgsHolder` in
//! `Jvm.Lowering`) before forwarding argv to the Lyric `main` -- so the
//! value is captured even when `main()` itself declares no `argv`
//! parameter. Every *call site* naming `hostGetCommandLineArgs` is then
//! intercepted by `lowerBuiltinOrStaticCall` (`codegen/04_calls.l`,
//! following the same bare-name compiler-intrinsic convention already
//! used for `intToLong`/`stringToUtf8Bytes`) and lowered directly to a
//! `getstatic` read of that field -- the function body below is therefore
//! never actually invoked at runtime; it exists only so the package
//! type-checks and to fail loudly (rather than silently) in the
//! unreachable case where some future refactor removes the call-site
//! interception without updating this fallback.
//!
//! **Ordering constraint (#6587):** `__LyricJvmRuntime.commandLineArgs` is
//! only populated once the entry-point `main(String[])` wrapper's
//! `putstatic` executes -- before that (e.g. a module-level `val`
//! initializer that called `args()` during some OTHER class's `<clinit>`,
//! ahead of `main` ever running) the field still reads its JVM zero-init
//! default (`null`). Not reachable today (no module-level `val` in the
//! tree calls `Std.Environment.args()`), but a real divergence from the
//! `.NET` kernel below, which calls a real OS API unconditionally -- keep
//! this in mind before adding one. The call-site interception that reads
//! this field (`Jvm.Codegen.lowerBuiltinOrStaticCall`, `codegen/04_calls.l`)
//! now guards the read with an explicit null check: a `null` read panics
//! with a diagnostic naming this exact ordering hazard instead of letting
//! a bare `NullPointerException` propagate, so a future caller who trips
//! this gets a message pointing at the real problem. See
//! `env_args_ordering_jvm_main.l` for the standalone repro that exercises
//! the panic path.
//!
//! **setVar / getVar (issue #7546):** the JVM exposes no `setenv(3)`
//! equivalent without unsafe reflection, so `hostSetEnvironmentVariable`
//! cannot touch the real process environment block the way the .NET
//! kernel's `System.Environment.SetEnvironmentVariable` does.  Instead this
//! kernel keeps a process-wide overlay, `envOverlay` (a `ConcurrentHashMap
//! <String, String>`), that every `setVar` call writes into. `hostGetVarOpt`
//! checks `envOverlay.containsKey` first — a present key wins even when its
//! value is `""`, so an overlaid empty value is distinguishable from "not
//! overlaid" — before falling back to the real `System.getenv`, so the
//! overlay wins over — and can mask — any real OS-inherited variable for
//! the lifetime of this process. `envOverlay` is a `ConcurrentHashMap` so
//! `setVar` is safe to call from multiple threads (matching `.NET`'s
//! thread-safe `SetEnvironmentVariable`). `Std.ProcessHost` /
//! `Std.ProcessCaptureHost` / `Std.ProcessPipedHost` copy the overlay onto
//! each spawned child's `ProcessBuilder.environment()` map (via
//! `hostForEachOverlayVar` below) so a child process observes the same
//! variables `getVar` would report in this process, matching the .NET and
//! native kernels (there, `setVar` mutates the real process environment
//! block that a spawned child already inherits).
//!
//! **Empty value (verified against the real BCL, #7546):** `System
//! .Environment.SetEnvironmentVariable(key, "")` on .NET sets the variable
//! to an empty string — it does NOT remove it (the two-argument overload
//! has no way to pass a null value from Lyric's non-nullable `String`
//! parameter). `hostGetVarOpt("k")` after `setVar("k", "")` therefore
//! returns `Some(value = "")` here too, exactly like the real `getenv`
//! would for a real, present-but-empty OS variable — there is no portable
//! way to UNSET a variable through this function on any target.
@axiom("java.lang.System and java.util.concurrent.ConcurrentHashMap operations conform to their documented JVM contracts")
package Std.EnvironmentHost

import Std.Core

extern type JSystem = "java.lang.System"

// Process-wide setVar overlay (see the module header).  Declared as a
// generic extern type over `java.util.concurrent.ConcurrentHashMap`
// (the JVM has no reified generics, so `Jvm.Codegen.typeExprToJvmExtern`
// erases this to the raw `ConcurrentHashMap` class — same pattern as
// `lyric-web`'s `JvmConcurrentDict[K, V]`, #5458).
extern type JvmConcurrentMap[K, V] = "java.util.concurrent.ConcurrentHashMap"

@externTarget("java.util.concurrent.ConcurrentHashMap.<init>")
func newConcurrentMap[K, V](): JvmConcurrentMap[K, V] = ()

extern type JvmMapEntryIterator = "java.util.Iterator"

extern type JvmMapEntry = "java.util.Map$Entry"

// Values `setVar` has set for this process (present key = observed override,
// including an overridden EMPTY value — see the module header).
val envOverlay: JvmConcurrentMap[String, String] = newConcurrentMap[String, String]()

// .NET's `System.AppContext.BaseDirectory` (the entry-ASSEMBLY's own
// directory, for resolving resources packaged alongside the binary) has no
// direct JVM equivalent without reflecting on a loaded class's
// `ProtectionDomain`/`CodeSource` -- and unlike the current working
// directory below, it is NOT interchangeable with `user.dir` (running
// `java -jar /opt/app/app.jar` from an unrelated `cwd` would silently
// return the wrong directory).  Returns "" per the "empty = unavailable"
// convention already used for `hostRuntimeDirectory`/`hostRuntimeIdentifier`
// rather than a plausible-looking but wrong answer.
pub func hostAppBaseDirectory(): String {
  ""
}

// Current working directory of the process — `pwd` on POSIX.  `user.dir`
// is a genuine, real JVM equivalent (guaranteed set at JVM startup), unlike
// `hostAppBaseDirectory` above.
pub func hostCurrentDirectory(): String {
  JSystem.getProperty("user.dir")
}

// The .NET runtime shared-framework directory has no JVM equivalent.
// Returns "" so that callers following the "empty = unavailable" convention
// (documented in Std.Environment.runtimeDirectory) behave correctly on JVM.
pub func hostRuntimeDirectory(): String {
  ""
}

// The .NET runtime identifier is a .NET-only concept with no JVM equivalent.
// Returns "" per the "empty = unavailable" convention.
pub func hostRuntimeIdentifier(): String {
  ""
}

// Sets a process-local overlay entry — see the module header.  Always
// records `value` (even `""`) into `envOverlay`; there is no unset path,
// matching the real, BCL-verified `System.Environment
// .SetEnvironmentVariable(string, string)` contract.
pub func hostSetEnvironmentVariable(key: in String, value: in String): Unit {
  val _ = envOverlay.put(key, value)
}

// Option seam — the exception-free surface every kernel twin implements
// (issue #4752): absent and error both surface as None here, matching
// `_kernel/environment_host.l`'s `try`/`catch Bug` wrapper exactly (a
// `SecurityManager`-denied `System.getenv` throws on JVM the same way a
// permission failure could on .NET).  `System.getenv` returns null for an
// unset variable; Lyric has no null pattern (issue #4775), so unset is
// detected via `??` with a NUL-string marker: POSIX and Windows
// environment blocks are NUL-delimited, so no real value can ever equal
// "\0".
//
// Checks the `setVar` overlay (module header) before falling back to the
// real `System.getenv`: `envOverlay.containsKey` (not just a non-empty
// `get`) so an overlaid EMPTY value is still reported as present, matching
// the .NET kernel where `setVar` mutates the real environment block that
// `GetEnvironmentVariable` reads from directly.
pub func hostGetVarOpt(key: in String): Option[String] {
  if envOverlay.containsKey(key) {
    val overlaid = envOverlay.get(key) ?? ""
    return Some(value = overlaid)
  }
  try {
    val v = JSystem.getenv(key) ?? "\u{0000}"
    if v == "\u{0000}" {
      None
    } else {
      Some(value = v)
    }
  } catch Bug as _ {
    None
  }
}

// Apply `action(key, value)` for every `setVar`-overridden variable in the
// overlay.  Used by `Std.ProcessHost` / `Std.ProcessCaptureHost` /
// `Std.ProcessPipedHost` to copy the overlay onto a spawned child's
// `ProcessBuilder.environment()` map before `start()` (see the module
// header).
pub func hostForEachOverlayVar(action: in (String, String) -> Unit): Unit {
  val it: JvmMapEntryIterator = envOverlay.entrySet().iterator()
  while it.hasNext() {
    val e: JvmMapEntry = it.next()
    action(e.getKey(), e.getValue())
  }
}

// See the module header: every real call site is intercepted at compile
// time and lowered directly to a `getstatic __LyricJvmRuntime.
// commandLineArgs` read (issue #5377) -- this body never actually runs.
pub func hostGetCommandLineArgs(): slice[String] {
  panic(
    "Std.Environment.args() reached its unreachable JVM fallback body -- the compile-time call-site interception (Jvm.Codegen.lowerBuiltinOrStaticCall, issue #5377) should have replaced this call with a direct getstatic read. This indicates a compiler regression, not a missing feature."
  )
}

pub func hostExit(code: in Int): Never {
  JSystem.exit(code)
}

// True when the JVM reports a Windows host.  `os.name` is a standard system
// property set at JVM startup ("Windows 11", "Windows Server 2022", ...).
pub func hostIsWindows(): Bool {
  val name = JSystem.getProperty("os.name") ?? ""
  name.startsWith("Windows")
}
