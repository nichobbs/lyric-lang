// lyric/repl/repl.l — Lyric.Repl interactive REPL.
//
// Script-accumulation REPL: statements are collected into a synthesised
// Lyric program and re-run after each line.  Two buffers are kept:
//   topLevel  — top-level func/record/union definitions (entered via :fn…:end)
//   body      — statements inside the synthesised main() func
//
// Meta-commands:
//   :help  :h        show help
//   :quit  :q        exit
//   :clear           reset session
//   :show            print accumulated script
//   :fn … :end       enter a top-level definition block
//   :run             re-run without adding a line
//
// Compilation uses Lyric.Emitter.emit (shells out to --internal-build);
// the compiled DLL is executed via `dotnet exec`.  Compiler errors are
// printed to stderr by the subprocess; the REPL continues.

@runtime_checked
package Lyric.Repl

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Errors
import Std.File as File
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment

import Lyric.Emitter as Emitter

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────

func BANNER(): String { "lyric repl 0.1.0  —  :help for help, :quit to exit" }
func PROMPT(): String { "> " }
func CONT(): String   { "| " }

func printHelp(): Unit {
  Console.println("Commands:")
  Console.println("  :help  :h        show this message")
  Console.println("  :quit  :q        exit the REPL")
  Console.println("  :clear           reset accumulated script")
  Console.println("  :show            print the accumulated script")
  Console.println("  :fn              begin a top-level definition (end with :end)")
  Console.println("  :end             finish a top-level definition")
  Console.println("  :run             re-run without adding a line")
  Console.println("")
  Console.println("Any other input is appended to main() and the script is re-run.")
}

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR",
    Environment.getVarOrDefault("TEMP",
      Environment.getVarOrDefault("TMP", "/tmp")))
}

// Remove all elements from `lst`.
// Removes from the tail to stay O(n) (removeAt(0) on a list is O(n) per call).
func clearList(lst: in List[String]): Unit {
  while lst.count > 0 { lst.removeAt(lst.count - 1) }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Script synthesis
// ─────────────────────────────────────────────────────────────────────────────

func PREAMBLE(): String {
  "package ReplSession\n" +
  "import Std.Core\n" +
  "import Std.Console\n" +
  "import Std.Collections\n" +
  "import Std.String\n" +
  "\n"
}

func buildScript(topLevel: in List[String], body: in List[String]): String {
  var s = PREAMBLE()

  for item in topLevel.toArray() {
    s = s + item + "\n"
  }

  s = s + "\nfunc main(): Int {\n"
  for stmt in body.toArray() {
    s = s + "  " + stmt + "\n"
  }
  s = s + "  0\n}\n"
  s
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Compile and run
// ─────────────────────────────────────────────────────────────────────────────

func runScript(
    script:  in String,
    dllFile: in String,
    verbose: in Bool
): Unit {
  if verbose {
    Console.println("--- script ---")
    Console.println(script)
    Console.println("--- end ---")
  }

  val req = Emitter.EmitRequest(
    source       = script,
    assemblyName = "lyric_repl_session",
    outputPath   = dllFile,
    target       = Emitter.Dotnet
  )
  val result = Emitter.emit(req)

  var hadError = false
  for d in result.diagnostics.toArray() {
    match d.severity {
      case DiagError   -> { hadError = true }
      case DiagWarning -> ()
    }
  }
  if hadError {
    // Subprocess printed the real errors to stderr already.
    return
  }

  // Execute the compiled program; inherit stdio.
  val execArgs: List[String] = newList()
  execArgs.add("exec")
  execArgs.add(dllFile)
  match Process.run("dotnet", execArgs) {
    case Ok(_)  -> ()
    case Err(e) -> Console.error("repl: dotnet exec failed: " + IOError.message(e))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Main loop
// ─────────────────────────────────────────────────────────────────────────────

pub func runRepl(argv: in slice[String]): Int {
  // Parse flags.
  var verbose = false
  var i = 0
  while i < argv.length {
    if argv[i] == "--verbose" or argv[i] == "-v" { verbose = true }
    i += 1
  }

  Console.println(BANNER())
  Console.println("")

  // Temp directory.  Each concurrent REPL session should use a distinct
  // directory to avoid file collisions; callers can set LYRIC_REPL_DIR.
  // NOTE: two simultaneous `lyric repl` invocations sharing the same
  // LYRIC_REPL_DIR will race on session.l / session.dll.  A future
  // stdlib Process.pid() binding would let us append the PID suffix.
  val replDir = Environment.getVarOrDefault("LYRIC_REPL_DIR",
    Path.join(tempBase(), "lyric-repl"))
  match File.createDir(replDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }
  val srcFile = Path.join(replDir, "session.l")
  val dllFile = Path.join(replDir, "session.dll")

  val topLevel: List[String] = newList()
  val body: List[String]     = newList()
  val fnBuf: List[String]    = newList()
  var fnMode  = false
  var running = true

  while running {
    val prompt = if fnMode { CONT() } else { PROMPT() }
    Console.print(prompt)

    match Console.readLine() {
      case Err(_) -> {
        // EOF (Ctrl-D / pipe close).
        Console.println("")
        running = false
      }

      case Ok(line) -> {
        val t = Str.trim(line)

        if t == ":quit" or t == ":q" {
          running = false
        } else if t == ":help" or t == ":h" {
          printHelp()
        } else if t == ":clear" {
          clearList(topLevel)
          clearList(body)
          clearList(fnBuf)
          fnMode = false
          Console.println("Session cleared.")
        } else if t == ":show" {
          if body.count == 0 and topLevel.count == 0 {
            Console.println("(empty session)")
          } else {
            Console.println(buildScript(topLevel, body))
          }
        } else if t == ":fn" {
          if fnMode {
            Console.println("repl: already in definition mode — use :end first")
          } else {
            fnMode = true
            clearList(fnBuf)
          }
        } else if t == ":end" {
          if not fnMode {
            Console.println("repl: not in definition mode — use :fn to begin")
          } else {
            fnMode = false
            if fnBuf.count > 0 {
              // Join the buffered lines into one top-level item.
              var fnText = ""
              var fi = 0
              while fi < fnBuf.count {
                if fi > 0 { fnText = fnText + "\n" }
                fnText = fnText + fnBuf[fi]
                fi += 1
              }
              topLevel.add(fnText)
              clearList(fnBuf)
              Console.println("Definition added.")
              if body.count > 0 {
                runScript(buildScript(topLevel, body), dllFile, verbose)
              }
            } else {
              Console.println("(empty definition — nothing added)")
            }
          }
        } else if t == ":run" {
          if body.count == 0 and topLevel.count == 0 {
            Console.println("(nothing to run)")
          } else {
            runScript(buildScript(topLevel, body), dllFile, verbose)
          }
        } else if Str.isEmpty(t) {
          if fnMode { fnBuf.add(line) }
          // blank lines outside :fn are ignored
        } else if fnMode {
          fnBuf.add(line)
        } else {
          body.add(line)
          runScript(buildScript(topLevel, body), dllFile, verbose)
        }
      }
    }
  }

  Console.println("Goodbye!")
  0
}
