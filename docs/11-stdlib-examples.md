# 11 - Standard Library Examples

These examples are source-level sketches for the future stdlib surface.
They are meant to help reviewers validate API shape, error handling, and
effect boundaries before the compiler can execute every construct here.

## Error Handling Pattern

Fallible stdlib operations return `Result[T, E]`. Recoverable boundary
errors are data; callers should pattern-match or use `?` once the
operator is available.

```lyric
package Examples.Errors

import Std.Console as Console
import Std.File as File

func printConfig(path: in String): Unit {
  match File.readText(path) {
    case Ok(text) -> Console.println(text)
    case Err(e) -> Console.error("could not read config: " + IOError.message(e))
  }
}
```

## Console Application

```lyric
package Examples.Cli

import Std.App as App
import Std.Console as Console
import Std.Environment as Environment

func main(): Unit {
  val args = Environment.args()
  Console.println("args: " + args.length)

  val mode = Environment.getVarOrDefault("APP_MODE", "dev")
  Console.println("mode: " + mode)
}

pub func entry(): Int {
  return App.run(main)
}
```

## File Processing Utility

```lyric
package Examples.Files

import Std.Console as Console
import Std.Directory as Directory
import Std.File as File
import Std.Path as Path

func printTextFiles(root: in String): Unit {
  match Directory.enumerateFiles(root) {
    case Err(e) ->
      Console.error("cannot list " + root + ": " + IOError.message(e))

    case Ok(files) ->
      for file in files {
        if Path.extension(file) == ".txt" {
          match File.readText(file) {
            case Ok(text) ->
              Console.println(Path.basename(file) + ": " + text.length)
            case Err(e) ->
              Console.error("cannot read " + file + ": " + IOError.message(e))
          }
        }
      }
  }
}
```

## HTTP Client

HTTP status codes are explicit. A response with status 404 is still a
successful transport response unless the caller asks for
`ensureSuccess`.

```lyric
package Examples.Http

import Std.Console as Console
import Std.Http as Http

async func fetch(url: in String): Unit {
  match await Http.getAsync(url) {
    case Err(e) ->
      Console.error("request failed: " + HttpError.message(e))

    case Ok(response) ->
      Console.println("status: " + HttpResponse.statusCode(response))
      match await HttpResponse.bodyText(response) {
        case Ok(body) -> Console.println(body)
        case Err(e) -> Console.error("body read failed: " + IOError.message(e))
      }
  }
}
```

## Time and Logging

Code that needs testability should accept `Clock` rather than construct
`SystemClock` internally. Application wires can bind a system clock in
production and a fixed clock in tests.

```lyric
package Examples.Diagnostics

import Std.Log as Log
import Std.Time as Time

func reportStartup(clock: in Clock): Unit {
  val now = clock.now()
  Log.info("started at " + Instant.toIso8601(now))
}
```

## App Config Boundary

`App.withConfig` loads raw text only. Decoding and validation stay
explicit so generated JSON readers can produce domain-specific errors.

```lyric
package Examples.Config

import Std.App as App
import Std.Console as Console

func load(path: in String): Unit {
  match App.withConfig(path) {
    case Ok(config) ->
      Console.println("loaded " + Config.path(config))
    case Err(e) ->
      Console.error("config error: " + IOError.message(e))
  }
}
```

## Review Checklist

- Fallible IO/network/config operations return `Result`.
- Existence probes return `Bool` and do not classify errors.
- Opaque wrappers hide host handles from application code.
- Host calls live in `*_host.l` or `io.l` trusted boundaries.
- Comments on public functions list preconditions-as-data and errors.
