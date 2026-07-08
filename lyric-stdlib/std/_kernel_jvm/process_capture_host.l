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
//!   * `proc.getOutputStream/getInputStream/getErrorStream()` obtain the
//!     stdio pipes.  Instance methods are called on the object (`proc.start()`,
//!     `stream.available()`, `buf.write(chunk)`, etc.) via the instance auto-FFI
//!     path; only constructors and static methods use the `JType.method()`
//!     form.  Stdin is written in one shot (UTF-8 bytes) and closed.
//!   * Stdout and stderr are drained incrementally inside the `isAlive()` poll
//!     loop via `stream.available()`-bounded chunk reads into a
//!     `java.io.ByteArrayOutputStream`, preventing pipe-buffer deadlock.
//!     Each drain call costs two JNI crossings regardless of chunk size:
//!     one `readNBytes(avail)` and one `write(byte[])`.  (The previous
//!     byte-at-a-time loop cost 2×N JNI crossings for N available bytes.)
//!   * Wall-clock cap is enforced by comparing `System.currentTimeMillis()`
//!     against a computed deadline and calling `Process.destroyForcibly()`.
//!     (`Process.waitFor(long, TimeUnit)` is unavailable because the auto-FFI
//!     resolver skips enum types such as `java.util.concurrent.TimeUnit`.)
//!   * `Thread.sleep(1L)` (via `extern type JThread`) parks the polling thread
//!     for 1 ms per iteration, preventing 100% CPU spin while the child runs.
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

extern type JThread = "java.lang.Thread"

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
// `Std.Process.buildArgString` / `Std.ProcessCapture.buildArgString`, the
// same format both callers share) back into a `List[String]`.
// The format is a space-separated sequence of `"..."` tokens where interior
// `"` is escaped as `\"` and interior `\` is escaped as `\\`.
// The resulting list is prepended with `executable` so
// `ProcessBuilder` receives a complete command line.
// `pub` so `Std.ProcessHost` (the non-capturing spawn kernel) can share this
// parser rather than reimplementing the same quoting convention.
pub func parseArgString(executable: in String, argStr: in String): List[String] {
  val parsed: List[String] = newList()
  parsed.add(executable)
  var i = 0
  val n = argStr.length
  while i < n {
    // Skip inter-argument whitespace
    while i < n and argStr[i] == ' ' {
      i = i + 1
    }
    if i >= n {
      return parsed
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
      parsed.add(arg)
    } else {
      // Unquoted token (fallback; buildArgString always quotes)
      var arg = ""
      while i < n and argStr[i] != ' ' {
        arg = arg + argStr.substring(i, 1)
        i = i + 1
      }
      parsed.add(arg)
    }
  }
  parsed
}

// ── Incremental drain ─────────────────────────────────────────────────────────
// Drain however many bytes are currently available on `stream` into `buf`
// without blocking.  Called from the isAlive() poll loop so we never
// deadlock on a pipe whose buffer is full.
//
// Uses InputStream.readNBytes(int) (Java 11+): reads the entire available
// chunk in one JDK call and writes it to the accumulator in another, costing
// two JNI crossings per drain call regardless of how many bytes arrive.  The
// previous single-byte loop cost 2×N crossings for N bytes.
func drainAvailable(stream: in JInputStream, buf: in JBAOS): Unit {
  // `destroyForcibly()` closes the child's pipes, after which `available()`
  // throws `IOException: Stream closed` — both on later poll iterations and
  // on the final post-loop drain.  A dead stream has nothing left to drain;
  // swallow and keep whatever was captured before the kill (letting the
  // IOException escape turned every timeout kill into the spawn-failure
  // fallback: exitCode -1, timedOut false).
  try {
    val avail = stream.available()
    if avail > 0 {
      val chunk = stream.readNBytes(avail)
      buf.write(chunk)
    }
  } catch Bug as _ {
    ()
  }
}

// ── Core implementation ───────────────────────────────────────────────────────
func runImpl(
  executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int
): ProcessCaptureResult {
  val cmdList = parseArgString(executable, arguments)
  val pb = JProcessBuilder.new(cmdList)
  val proc = pb.start()

  // Write stdin as UTF-8 bytes then close the pipe so the child sees EOF.
  val stdinStream = proc.getOutputStream()
  val stdinBytes = stringToUtf8Bytes(stdinContent)
  stdinStream.write(stdinBytes)
  stdinStream.close()

  val stdoutStream = proc.getInputStream()
  val stderrStream = proc.getErrorStream()
  val stdoutBuf = JBAOS.new()
  val stderrBuf = JBAOS.new()

  val startMs = currentTimeMillis()
  val timeoutMsL = intToLong(timeoutMs)
  var timedOut = false

  // Poll until the child exits, draining both pipes each iteration.
  // Sleep 1 ms per idle iteration to avoid spinning at 100% CPU.
  while proc.isAlive() {
    drainAvailable(stdoutStream, stdoutBuf)
    drainAvailable(stderrStream, stderrBuf)
    if not timedOut and currentTimeMillis() - startMs >= timeoutMsL {
      timedOut = true
      proc.destroyForcibly()
    }
    JThread.sleep(intToLong(1))
  }

  // Final drain after the child exits (last bytes may arrive after isAlive → false).
  drainAvailable(stdoutStream, stdoutBuf)
  drainAvailable(stderrStream, stderrBuf)

  val exitCode = if timedOut { -2 } else { try { proc.exitValue() } catch Bug as _ { -1 } }

  ProcessCaptureResult(
    stdout = stdoutBuf.toString("UTF-8"),
    stderr = stderrBuf.toString("UTF-8"),
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
  try {
    runImpl(executable, arguments, stdinContent, timeoutMs)
  } catch Bug as _ {
    ProcessCaptureResult(stdout = "", stderr = "", exitCode = -1, timedOut = false)
  }
}

// =====================================================================
// List-argv Result seam — the exception-free surface every kernel twin
// implements (issue #4752).  Joins to the quoted argument string
// `runImpl` expects (`parseArgString` reverses the same escaping
// convention exactly) and absorbs the Bug into the error channel.
// =====================================================================
pub func hostRunCaptureList(
  executable: in String, args: in List[String], stdinContent: in String, timeoutMs: in Int
): Result[ProcessCaptureResult, String] {
  var argStr = ""
  var i = 0
  val count = args.count
  while i < count {
    if i > 0 {
      argStr = argStr + " "
    }
    // The element read needs the String annotation so `.replace`
    // resolves against String (an unannotated `args[i]` receiver
    // erases to Object under the JVM auto-FFI).
    val arg: String = args[i]
    val escaped = arg.replace("\\", "\\\\").replace("\"", "\\\"")
    argStr = argStr + "\"" + escaped + "\""
    i += 1
  }
  try {
    Ok(value = runImpl(executable, argStr, stdinContent, timeoutMs))
  } catch Bug as b {
    Err(error = b.message)
  }
}
