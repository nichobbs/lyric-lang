//! piped_process_jvm_main.l — `Std.Process.spawnPiped` real-child-process
//! round-trip check for `--target jvm` (#6135).
//!
//! Not a `@test_module`: a real bidirectional child-process pipe (spawn,
//! write, read back) is exactly the shape `entry_args_jvm_main.l` /
//! `env_args_jvm_main.l` already use this file layout for — a program
//! built with `lyric build --target jvm` and run directly under `java`,
//! not through `lyric test`'s synthesised harness. Mirrors the coverage of
//! `lyric-mcp/tests/mcp_stdio_process_tests.l`'s dotnet-only (`@cfg(target
//! = "dotnet")`) suite: single-line echo, multi-line ordering,
//! `pipedCloseStdin` clean-exit-with-final-line, a nonexistent-executable
//! spawn failure, and post-EOF `None` — 5/5 cases, matching that file's
//! dotnet coverage exactly.
//!
//! Exercises the byte-level, `available()`-polled rewrite of
//! `std/_kernel_jvm/process_piped_host.l`'s `hostPipedReadLineOpt` (see
//! that file's module header for why the previous `BufferedReader
//! .readLine()`-based version was unreliable, and why this technique
//! fixes it) against a REAL `cat` subprocess — this is the actual
//! `Mcp.Client.connectStdio` validation target the issue names, exercised
//! one layer down (the raw `Std.Process` piped API `Mcp.Stdio` itself
//! sits on top of).
//!
//! Prints one PASS/FAIL line per case and "failures=N"; exits 0 iff every
//! case passed (N == 0).
package Main

import Std.Core
import Std.Collections
import Std.Console
import Std.Process

func main(): Int {
  var failures = 0

  // Case 1: single line round-trip.
  match spawnPiped("cat", newList()) {
    case Err(e) -> {
      println("FAIL case1 spawn: " + IOError.message(e))
      failures = failures + 1
    }
    case Ok(p) -> {
      if not pipedIsAlive(p) {
        println("FAIL case1: not alive right after spawn")
        failures = failures + 1
      }
      pipedWriteLine(p, "hello from lyric")
      match pipedReadLine(p) {
        case Err(e) -> {
          println("FAIL case1 read: " + e)
          failures = failures + 1
        }
        case Ok(None) -> {
          println("FAIL case1: unexpected EOF")
          failures = failures + 1
        }
        case Ok(Some(line)) -> {
          if line == "hello from lyric" {
            println("PASS case1: echoed line matches")
          } else {
            println("FAIL case1: got '" + line + "'")
            failures = failures + 1
          }
        }
      }
      pipedKill(p)
      pipedWaitExit(p, 3000)
      pipedClose(p)
    }
  }

  // Case 2: multiple lines round-trip in order.
  match spawnPiped("cat", newList()) {
    case Err(e) -> {
      println("FAIL case2 spawn: " + IOError.message(e))
      failures = failures + 1
    }
    case Ok(p) -> {
      pipedWriteLine(p, "one")
      pipedWriteLine(p, "two")
      pipedWriteLine(p, "three")
      var ok = true
      match pipedReadLine(p) {
        case Ok(Some(line)) -> {
          ok = ok and line == "one"
        }
        case _ -> {
          ok = false
        }
      }
      match pipedReadLine(p) {
        case Ok(Some(line)) -> {
          ok = ok and line == "two"
        }
        case _ -> {
          ok = false
        }
      }
      match pipedReadLine(p) {
        case Ok(Some(line)) -> {
          ok = ok and line == "three"
        }
        case _ -> {
          ok = false
        }
      }
      if ok {
        println("PASS case2: three lines in order")
      } else {
        println("FAIL case2: out-of-order or missing line")
        failures = failures + 1
      }
      pipedKill(p)
      pipedWaitExit(p, 3000)
      pipedClose(p)
    }
  }

  // Case 3: pipedCloseStdin signals EOF and the child exits cleanly; the
  // line written before EOF is still readable afterward.
  match spawnPiped("cat", newList()) {
    case Err(e) -> {
      println("FAIL case3 spawn: " + IOError.message(e))
      failures = failures + 1
    }
    case Ok(p) -> {
      pipedWriteLine(p, "last line")
      pipedCloseStdin(p)
      val exited = pipedWaitExit(p, 3000)
      if not exited {
        println("FAIL case3: cat did not exit after stdin EOF")
        failures = failures + 1
      }
      match pipedReadLine(p) {
        case Ok(Some(line)) -> {
          if line == "last line" {
            println("PASS case3: final buffered line readable after exit")
          } else {
            println("FAIL case3: got '" + line + "'")
            failures = failures + 1
          }
        }
        case Ok(None) -> {
          println("FAIL case3: expected buffered line, got immediate EOF")
          failures = failures + 1
        }
        case Err(e) -> {
          println("FAIL case3 read: " + e)
          failures = failures + 1
        }
      }
      pipedClose(p)
    }
  }

  // Case 4: spawning a nonexistent executable returns Err.
  match spawnPiped("lyric-nonexistent-executable-xyz", newList()) {
    case Ok(_) -> {
      println("FAIL case4: expected spawn to fail")
      failures = failures + 1
    }
    case Err(_) -> println("PASS case4: nonexistent executable rejected")
  }

  // Case 5: after stdin EOF and the child exits with no more data
  // buffered, a further read returns None (not a hang, not stale data).
  match spawnPiped("cat", newList()) {
    case Err(e) -> {
      println("FAIL case5 spawn: " + IOError.message(e))
      failures = failures + 1
    }
    case Ok(p) -> {
      pipedCloseStdin(p)
      pipedWaitExit(p, 3000)
      match pipedReadLine(p) {
        case Ok(None) -> println("PASS case5: EOF with no buffered data returns None")
        case Ok(Some(line)) -> {
          println("FAIL case5: expected None, got '" + line + "'")
          failures = failures + 1
        }
        case Err(e) -> {
          println("FAIL case5 read: " + e)
          failures = failures + 1
        }
      }
      pipedClose(p)
    }
  }

  println("failures=" + failures.toString())
  failures
}
