//! std/_kernel_native/process_piped_host.l — native-target twin of
//! `_kernel/process_piped_host.l`, selected by the native source loader
//! by basename (issue #6142).
//!
//! Implements long-lived piped child stdio over `lyric-rt`'s
//! `lyric_process_piped_*` seam (`lyric_process.c`): `fork`+`execvp`
//! wiring only the child's stdin and stdout to fresh pipes, exactly
//! like the dotnet (`RedirectStandardInput`/`RedirectStandardOutput`
//! only) and JVM (`Redirect.INHERIT` on stderr) twins — stderr is left
//! inherited from this process, so a spawned server's diagnostic/log
//! output goes straight to this process's own stderr instead of
//! risking a deadlock on a full, never-drained capture pipe.
//!
//! ## Representation: the handle is a `Long`, not a `NativePtr[Byte]`
//!
//! `PipedHandle` must survive across MULTIPLE separate top-level calls
//! (`hostSpawnPiped` constructs it; `hostPipedReadLineOpt`/
//! `hostPipedWriteLine`/etc. use it later) — the mode checker's N0100
//! boundary documents storing `NativePtr[T]` in a record/union field as
//! rejected unconditionally (heap storage outlives any frame), so the
//! raw `lyric_process_piped_*` handle (a `void*` in C) is declared
//! `Long` at both its extern-func return and parameter positions —
//! `_kernel_native/tcp_host.l`'s identical `Conn.tlsConnHandle` idiom,
//! not a new pattern.
//!
//! ## Argument parsing: re-materializing argv from `Std.Process`'s quoted string
//!
//! `Std.Process.spawnPiped` builds `arguments` via `buildArgString`
//! (space-separated `"..."` tokens with `\"`/`\\` escaping) and calls
//! `hostSpawnPiped(fileName, arguments)` — the SAME two-string signature
//! on every target, since that call site is shared, target-independent
//! code. The dotnet twin hands that string straight to
//! `ProcessStartInfo.Arguments`, which the OS/CLR re-parses; native's
//! `fork`+`execvp` needs a real argv array with NO shell involved
//! (`lyric_process.c`'s own header: "no shell is ever invoked"), so
//! `parseArgString` below re-materializes the list, reusing the SAME
//! token-scanning algorithm `_kernel_jvm/process_capture_host.l`'s own
//! `parseArgString` already uses to solve the identical problem for
//! `ProcessBuilder`'s `List<String>` constructor (both targets need a
//! real list; only dotnet's `ProcessStartInfo.Arguments` accepts the
//! joined string directly). Unlike the JVM version, this one does NOT
//! prepend the executable to the returned list: `rtPipedSpawn` (like
//! `_kernel_native/process_capture_host.l`'s `rtProcessRun`) takes the
//! executable path as its OWN separate `path` parameter and builds
//! `argv[0]` from it directly — `ProcessBuilder`'s constructor is what
//! needs argv[0] folded into the same list, not `lyric_process.c`'s
//! `execvp`.
//!
//! ## Disclosed gap: `Std.Process.spawnPiped`/`pipedReadLine`/`pipedWriteLine`
//! are NOT reachable through this kernel on `--target native` today
//!
//! This file's own `hostSpawnPiped`/`hostPipedReadLineOpt`/
//! `hostPipedWriteLine`/etc. are genuinely correct and fully exercised
//! against a real `cat` child (`llvm_stdlib_self_test.l`'s
//! `Std.ProcessPipedHost` case) — but the SHARED, target-independent
//! `Std.Process.spawnPiped`/`pipedReadLine`/`pipedWriteLine` (the API a
//! caller would actually use, e.g. `lyric-mcp`'s stdio transport) wrap
//! their host call in `try { } catch Bug as b { }`, and
//! `Lyric.LlvmCodegen` unconditionally rejects `STry` for `--target
//! native` (D-N-003: "no unwinding") the instant any native build
//! reaches one of those three functions — a real, pre-existing,
//! independently-tracked compiler gap (not something this kernel could
//! work around; #4752's own Result-seam precedent for `runCapture` is
//! the template a follow-up would use to fix it). Two further,
//! independently-discovered blockers sit on the SAME shared call path:
//! `Std.Process.buildArgString` (called by `spawnPiped` before it ever
//! reaches this kernel) uses `String.replace`, which has no native
//! codegen lowering yet either; and this file's OWN first draft of
//! `parseArgString` used `argStr[i]` bracket indexing (mirroring the JVM
//! twin verbatim), which also has no native lowering (issue #6237) — the
//! shipped version above uses `.substring(i, 1)` instead, so THIS
//! blocker is already fixed here. See `docs/03-decision-log.md`
//! D-progress-878 for the full investigation (including the exact
//! compile-time panic each gap produces), issue #6887 (the
//! `try/catch`-on-native blocker) and issue #6888 (the
//! `String.replace`-on-native blocker).
@axiom("fork/execvp piped child stdio via lyric-rt conforms to its documented contract")
package Std.ProcessPipedHost

import Std.Core
import Std.Collections

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

// ── Argument-string parser (same token-scanning algorithm as
// _kernel_jvm/process_capture_host.l's parseArgString; see module header
// for why this one takes no `executable` param) ────────────────────────────
func parseArgString(argStr: in String): List[String] {
  val parsed: List[String] = newList()
  var i = 0
  val n = argStr.length
  while i < n {
    // `.substring(i, 1)` character access, NOT `argStr[i]` bracket
    // indexing — String bracket indexing has no native codegen lowering
    // yet (issue #6237), unlike the JVM twin this algorithm mirrors,
    // which uses `argStr[i]` directly. Every other `_kernel_native/`
    // file doing character-by-character string scanning already uses
    // this same `.substring(i, 1)` idiom (e.g. `http_host.l`'s header
    // parser).
    while i < n and argStr.substring(i, 1) == " " {
      i = i + 1
    }
    if i >= n {
      return parsed
    }
    if argStr.substring(i, 1) == "\"" {
      i = i + 1
      var arg = ""
      var done = false
      while not done and i < n {
        val c = argStr.substring(i, 1)
        if c == "\\" and i + 1 < n {
          i = i + 1
          val ec = argStr.substring(i, 1)
          if ec == "\"" {
            arg = arg + "\""
          } else if ec == "\\" {
            arg = arg + "\\"
          } else {
            arg = arg + "\\" + ec
          }
          i = i + 1
        } else if c == "\"" {
          i = i + 1
          done = true
        } else {
          arg = arg + c
          i = i + 1
        }
      }
      parsed.add(arg)
    } else {
      var arg = ""
      while i < n and argStr.substring(i, 1) != " " {
        arg = arg + argStr.substring(i, 1)
        i = i + 1
      }
      parsed.add(arg)
    }
  }
  parsed
}

// ── Extern seam bindings (lyric-rt/src/lyric_process.c) ────────────────────
// `args` rides as the raw kernel handle of a Std.Collections List[String]
// (LyricList*): collection VALUES passed as call arguments (never stored
// in a record) ride NativePtr[Byte] under N4.5 argument adaptation, the
// same convention `_kernel_native/process_capture_host.l`'s
// `rtProcessRun(path, args, ...)` already uses.
extern func rtPipedSpawn(path: NativePtr[Byte], args: NativePtr[Byte]): Long = "lyric_process_piped_spawn"

extern func rtPipedReadLine(p: Long, outLine: NativePtr[String]): Int = "lyric_process_piped_read_line"

extern func rtPipedWriteLine(p: Long, line: String): Int = "lyric_process_piped_write_line"

extern func rtPipedIsAlive(p: Long): Int = "lyric_process_piped_is_alive"

extern func rtPipedKill(p: Long): Int = "lyric_process_piped_kill"

extern func rtPipedWaitExit(p: Long, timeoutMs: Int): Int = "lyric_process_piped_wait_exit"

extern func rtPipedExitCode(p: Long): Int = "lyric_process_piped_exit_code"

extern func rtPipedCloseStdin(p: Long): Int = "lyric_process_piped_close_stdin"

extern func rtPipedClose(p: Long): Unit = "lyric_process_piped_close"

// ── Public handle + entry points ────────────────────────────────────────────
/// Opaque handle to a running child process with piped stdin/stdout. See
/// the module header for why this is a `Long`, not a `NativePtr[Byte]`.
pub record PipedHandle {
  raw: Long
}

/// Spawn `fileName` with a pre-formed `arguments` string (see
/// `Std.Process.buildArgString`), redirecting stdin and stdout; stderr is
/// inherited (see module header). Panics if the OS spawn itself fails
/// (pipe/fork failure) — `Std.Process.spawnPiped` catches this and maps it
/// to `IOError`. An `execvp` failure inside the child (e.g. `fileName` not
/// found) is NOT a spawn failure: it surfaces as exit code 127 once the
/// child is observed to exit, matching shell convention and
/// `_kernel_native/process_capture_host.l`'s identical contract.
@unsafe_ffi
pub func hostSpawnPiped(fileName: in String, arguments: in String): PipedHandle {
  val args = parseArgString(arguments)
  val c = toC(fileName)
  val raw = rtPipedSpawn(c, args)
  freeC(c)
  if raw == 0i64 {
    panic("Std.ProcessPipedHost: failed to spawn piped process: " + fileName)
  } else {
    PipedHandle(raw = raw)
  }
}

// Option seam avoiding `case null`'s catch-all miscompile (#4775) — the
// same NUL-marker convention `_kernel_native/environment_host.l`'s
// hostGetVarOpt uses, over the int32 ok-flag out-param protocol
// `rtSockReadBytes`/`rtEnvGetOk` already establish for this target.
@unsafe_ffi
pub func hostPipedReadLineOpt(p: in PipedHandle): Option[String] {
  var line: String = ""
  val rc = rtPipedReadLine(p.raw, nativeAddrOf(line))
  if rc == 1 {
    Some(value = line)
  } else {
    None
  }
}

/// Write one line to the child's stdin (a trailing newline is appended and
/// the write blocks until fully accepted by the pipe). Panics if the
/// child's stdin is already closed or the write fails (broken pipe / child
/// gone) — matching the dotnet/JVM twins' identical "an uncaught write
/// failure propagates" contract (neither twin's `hostPipedWriteLine`
/// catches one either).
pub func hostPipedWriteLine(p: in PipedHandle, line: in String): Unit {
  val rc = rtPipedWriteLine(p.raw, line)
  if rc != 0 {
    panic("Std.ProcessPipedHost: write to piped child's stdin failed (broken pipe)")
  }
}

/// True while the child process has not yet exited.
pub func hostPipedIsAlive(p: in PipedHandle): Bool {
  rtPipedIsAlive(p.raw) != 0
}

/// Forcibly terminate the child process's whole process group. Safe to
/// call unconditionally (a no-op once the child is already reaped).
pub func hostPipedKill(p: in PipedHandle): Unit {
  val _ = rtPipedKill(p.raw)
}

/// Block up to `timeoutMs` milliseconds for the child to exit. Returns
/// `true` if it exited within the deadline.
pub func hostPipedWaitExit(p: in PipedHandle, timeoutMs: in Int): Bool {
  rtPipedWaitExit(p.raw, timeoutMs) != 0
}

/// The child's OS exit code. Only meaningful after `hostPipedIsAlive`
/// reports `false` (or `hostPipedWaitExit` returned `true`).
pub func hostPipedExitCode(p: in PipedHandle): Int {
  rtPipedExitCode(p.raw)
}

/// Close only the child's stdin (signals EOF to the child without
/// affecting its stdout — useful for a batch-style child that reads until
/// EOF, then writes its complete output and exits). Idempotent-safe.
pub func hostPipedCloseStdin(p: in PipedHandle): Unit {
  val _ = rtPipedCloseStdin(p.raw)
}

/// Close the child's stdin/stdout pipes and release the handle. Does not
/// itself wait for or kill the child. Safe to call during best-effort
/// cleanup.
pub func hostPipedClose(p: in PipedHandle): Unit {
  rtPipedClose(p.raw)
}
