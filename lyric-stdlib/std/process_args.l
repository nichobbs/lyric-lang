//! Std.ProcessArgs — the single encoder and decoder for the command-line
//! convention every process kernel shares (#7234).
//!
//! A child's argument list crosses the kernel boundary as one string in the
//! CommandLineToArgvW convention, the one .NET also applies to
//! `ProcessStartInfo.Arguments`:
//!
//! - arguments are separated by unquoted blanks, and every argument this
//!   encoder produces is wrapped in `"..."` (so an empty argument survives);
//! - inside quotes, a run of N backslashes is literal unless it precedes a
//!   `"`; there it stands for N/2 backslashes, and an odd N also makes the
//!   quote literal instead of closing the span;
//! - `""` inside a quoted span is a literal quote (decoder only).
//!
//! `argvJoin` / `argvQuote` encode; `argvSplit` decodes, so
//! `argvSplit(argvJoin(xs)) == xs` for every list of strings.  The .NET
//! kernel hands the joined string to `ProcessStartInfo.Arguments`; the JVM
//! and native kernels split it back into an argv list.  Pure Lyric with no
//! kernel dependency, so every target shares this one implementation.
@runtime_checked
package Std.ProcessArgs

import Std.Core
import Std.Collections
import Std.String

/// Quote one argument so `argvSplit` (and CommandLineToArgvW) decodes it
/// back to exactly `arg`.
@pure
@stable(since = "1.2")
pub func argvQuote(arg: in String): String {
  val sb = StringBuilder.new()
  sb.append("\"")
  var i = 0
  val n = arg.length
  while i < n {
    val ch = arg.substring(i, 1)
    if ch == "\\" {
      var run = 0
      while i < n and arg.substring(i, 1) == "\\" {
        run = run + 1
        i = i + 1
      }
      // A run before the closing quote this function appends, or before a
      // literal quote, is doubled; a run before any other character is
      // copied as-is, because the decoder copies it as-is too.
      val beforeQuote = i == n or arg.substring(i, 1) == "\""
      sb.append(repeat("\\", if beforeQuote { run * 2 } else { run }))
    } else if ch == "\"" {
      sb.append("\\\"")
      i = i + 1
    } else {
      sb.append(ch)
      i = i + 1
    }
  }
  sb.append("\"")
  sb.toString()
}

/// Join `args` into one command-line string, each argument quoted.
@pure
@stable(since = "1.2")
pub func argvJoin(args: in List[String]): String {
  val sb = StringBuilder.new()
  var i = 0
  while i < args.count {
    if i > 0 {
      sb.append(" ")
    }
    sb.append(argvQuote(args[i]))
    i = i + 1
  }
  sb.toString()
}

/// Split a command-line string into its arguments (the inverse of
/// `argvJoin`, and of any CommandLineToArgvW-conformant encoder).
@stable(since = "1.2")
pub func argvSplit(argStr: in String): List[String] {
  val parsed: List[String] = newList()
  var i = 0
  val n = argStr.length
  while i < n {
    while i < n and isBlank(argStr.substring(i, 1)) {
      i = i + 1
    }
    if i >= n {
      return parsed
    }
    val arg = StringBuilder.new()
    var inQuotes = false
    var done = false
    while not done and i < n {
      val c = argStr.substring(i, 1)
      if c == "\\" {
        var run = 0
        while i < n and argStr.substring(i, 1) == "\\" {
          run = run + 1
          i = i + 1
        }
        val beforeQuote = i < n and argStr.substring(i, 1) == "\""
        arg.append(repeat("\\", if beforeQuote { run / 2 } else { run }))
        if beforeQuote and run % 2 == 1 {
          arg.append("\"")
          i = i + 1
        }
      } else if c == "\"" {
        if inQuotes and i + 1 < n and argStr.substring(i + 1, 1) == "\"" {
          arg.append("\"")
          i = i + 2
        } else {
          inQuotes = not inQuotes
          i = i + 1
        }
      } else if isBlank(c) and not inQuotes {
        done = true
      } else {
        arg.append(c)
        i = i + 1
      }
    }
    parsed.add(arg.toString())
  }
  parsed
}

func isBlank(c: in String): Bool {
  c == " " or c == "\t"
}
