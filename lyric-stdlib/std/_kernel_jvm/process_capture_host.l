//! std/_kernel_jvm/process_capture_host.l — JVM host boundary for piped
//! process execution (stdout + stderr capture, exit code, timeout flag).
//!
//! Mirrors _kernel/process_capture_host.l for the JVM target.  Used by
//! the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5 and
//! by the source-generator runtime when running under `--target jvm`.
//!
//! Implementation: pure JVM auto-FFI against the JDK — no F# host shim and
//! no external Java helper JAR, consistent with the `_kernel_jvm/hash_host.l`
//! precedent (M-9) and the project's no-new-shim rule.
//!
//!   * `java.lang.ProcessBuilder(List<String>)` spawns the child.  The Lyric
//!     `List[T]` maps to `java.util.ArrayList` at runtime and scores as a
//!     reference-subtype match (score 1) against the `List` parameter.
//!   * `Process.getOutputStream/getInputStream/getErrorStream` obtain the
//!     stdio pipes.  Stdin is written in one shot (UTF-8 bytes) and closed.
//!   * Stdout and stderr are drained incrementally inside the `isAlive()` poll
//!     loop via `InputStream.available()`-bounded reads into a
//!     `java.io.ByteArrayOutputStream`, preventing pipe-buffer deadlock.
//!   * Wall-clock cap is enforced by comparing `System.currentTimeMillis()`
//!     against a computed deadline and calling `Process.destroyForcibly()`.
//!     (`Process.waitFor(long, TimeUnit)` is unavailable because the auto-FFI
//!     resolver skips enum types such as `java.util.concurrent.TimeUnit`.)
//!   * Output byte arrays are converted to Strings via
//!     `ByteArrayOutputStream.toString("UTF-8")`.
//!
//! Internal: only Std.ProcessCapture should import this.
@axiom("java.lang.ProcessBuilder + java.lang.Process + java.io stream contracts conform to documented JVM process/IO semantics")
package Std.ProcessCaptureHost

import Std.Core
import Std.Collections

// ── JDK extern types ──────────────────────────────────────────────────────────
extern type JProcessBuilder = "java.lang.ProcessBuilder"

extern type JProcess = "java.lang.Process"

extern type JInputStream = "java.io.InputStream"

extern type JOutputStream = "java.io.OutputStream"

extern type JBAOS = "java.io.ByteArrayOutputStream"

// ── Wall-clock timer ─────────────────────────────────────────────────────────
@externTarget("java.lang.System.currentTimeMillis")
func currentTimeMillis(): Long = ()

// ── Result record ─────────────────────────────────────────────────────────────
/// Lyric record holding the captured output of a child process.
/// Structurally identical to the .NET kernel's `ProcessCaptureResult`
/// so `Std.ProcessCapture` compiles unchanged on both targets.
pub record ProcessCaptureResult {
  stdout: String
  stderr: String
  exitCode: Int
  timedOut: Bool
}

pub func pcResultStdout(r: in ProcessCaptureResult): String {
  r.stdout
}

pub func pcResultStderr(r: in ProcessCaptureResult): String {
  r.stderr
}

pub func pcResultExitCode(r: in ProcessCaptureResult): Int {
  r.exitCode
}

pub func pcResultTimedOut(r: in ProcessCaptureResult): Bool {
  r.timedOut
}

// ── Argument-string parser ────────────────────────────────────────────────────
// Parse the `buildArgString`-formatted `arguments` string (produced by
// `Std.ProcessCapture.buildArgString`) back into a `List[String]`.
// The format is a space-separated sequence of `"..."` tokens where interior
// `"` is escaped as `\"` and interior `\` is escaped as `\\`.
// The resulting list is prepended with `executable` so
// `ProcessBuilder` receives a complete command line.
func parseArgString(executable: in String, argStr: in String): List[String] {
  val result: List[String] = newList()
  result.add(executable)
  var i = 0
  val n = argStr.length
  while i < n {
    // Skip inter-argument whitespace
    while i < n and argStr[i] == ' ' {
      i = i + 1
    }
    if i >= n {
      return result
    }
    if argStr[i] == '"' {
      // Quoted token
      i = i + 1
      var arg = ""
      var done = false
      while not done and i < n {
        val c = argStr[i]
        if c == '\\' and i + 1 < n {
          i = i + 1
          val ec = argStr[i]
          if ec == '"' {
            arg = arg + "\""
          } else if ec == '\\' {
            arg = arg + "\\"
          } else {
            arg = arg + "\\" + argStr.substring(i, 1)
          }
          i = i + 1
        } else if c == '"' {
          i = i + 1
          done = true
        } else {
          arg = arg + argStr.substring(i, 1)
          i = i + 1
        }
      }
      result.add(arg)
    } else {
      // Unquoted token (fallback; buildArgString always quotes)
      var arg = ""
      while i < n and argStr[i] != ' ' {
        arg = arg + argStr.substring(i, 1)
        i = i + 1
      }
      result.add(arg)
    }
  }
  result
}

// ── Incremental drain ─────────────────────────────────────────────────────────
// Drain however many bytes are currently available on `stream` into `buf`
// without blocking.  Called from the isAlive() poll loop so we never
// deadlock on a pipe whose buffer is full.
func drainAvailable(stream: in JInputStream, buf: in JBAOS): Unit {
  var avail = JInputStream.available(stream)
  while avail > 0 {
    val b = JInputStream.read(stream)
    if b >= 0 {
      JBAOS.write(buf, b)
    }
    avail = avail - 1
  }
}

// ── Core implementation ───────────────────────────────────────────────────────
func runImpl(
  executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int
): ProcessCaptureResult {
  val cmdList = parseArgString(executable, arguments)
  val pb = JProcessBuilder.new(cmdList)
  val proc = JProcessBuilder.start(pb)

  // Write stdin as UTF-8 bytes then close the pipe so the child sees EOF.
  val stdinStream = JProcess.getOutputStream(proc)
  val stdinBytes = stringToUtf8Bytes(stdinContent)
  JOutputStream.write(stdinStream, stdinBytes)
  JOutputStream.close(stdinStream)

  val stdoutStream = JProcess.getInputStream(proc)
  val stderrStream = JProcess.getErrorStream(proc)
  val stdoutBuf = JBAOS.new()
  val stderrBuf = JBAOS.new()

  val startMs = currentTimeMillis()
  val timeoutMsL = intToLong(timeoutMs)
  var timedOut = false

  // Poll until the child exits, draining both pipes each iteration.
  while JProcess.isAlive(proc) {
    drainAvailable(stdoutStream, stdoutBuf)
    drainAvailable(stderrStream, stderrBuf)
    if not timedOut and currentTimeMillis() - startMs >= timeoutMsL {
      timedOut = true
      JProcess.destroyForcibly(proc)
    }
  }

  // Final drain after the child exits (last bytes may arrive after isAlive → false).
  drainAvailable(stdoutStream, stdoutBuf)
  drainAvailable(stderrStream, stderrBuf)

  val exitCode = if timedOut { -2 } else { try { JProcess.exitValue(proc) } catch Bug as _ { -1 } }

  ProcessCaptureResult(
    stdout = JBAOS.toString(stdoutBuf, "UTF-8"),
    stderr = JBAOS.toString(stderrBuf, "UTF-8"),
    exitCode = exitCode,
    timedOut = timedOut
  )
}

// ── Public host functions ─────────────────────────────────────────────────────
/// Spawn `executable` with `arguments` (buildArgString format), write
/// `stdinContent` to its stdin, and return a `ProcessCaptureResult`.
/// Applies a 10-second wall-clock cap.  Returns exitCode = -1 on spawn failure.
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): ProcessCaptureResult {
  try {
    runImpl(executable, arguments, stdinContent, 10000)
  } catch Bug as _ {
    ProcessCaptureResult(stdout = "", stderr = "", exitCode = -1, timedOut = false)
  }
}

/// Variant with a caller-supplied `timeoutMs` wall-clock cap.
pub func hostRunCaptureTimeout(
  executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int
): ProcessCaptureResult {
  runImpl(executable, arguments, stdinContent, timeoutMs)
}
