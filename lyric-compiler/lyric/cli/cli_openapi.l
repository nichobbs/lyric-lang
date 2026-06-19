package Lyric.Cli.Doc

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Lyric.OpenApiParser as OAParser
import Lyric.OpenApiGen as OAGen
import Lyric.Cli.Shared

// ─────────────────────────────────────────────────────────────────────────────
// §11e. OpenAPI command
// ─────────────────────────────────────────────────────────────────────────────
pub func cmdOpenApi(argv: in slice[String]): Int {
  var explicitOut: Option[String] = None
  var clientName = "ApiClient"
  var packageName = "Api.Client"
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("openapi: -o requires a value")
        return 1
      }
    } else if arg == "--client-name" {
      if i + 1 < argv.length {
        clientName = argv[i + 1]
        i += 2
      } else {
        printErr("openapi: --client-name requires a value")
        return 1
      }
    } else if arg == "--package" {
      if i + 1 < argv.length {
        packageName = argv[i + 1]
        i += 2
      } else {
        printErr("openapi: --package requires a value")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  if positional.count == 0 {
    printErr("openapi: missing spec file")
    return 1
  }

  val specPath = positional[0]
  val json = match File.readText(specPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("openapi: " + IOError.message(e))
      return 1
    }
  }

  match OAParser.parseSpec(json) {
    case Err(msg) -> {
      printErr("openapi: " + msg)
      return 1
    }
    case Ok(spec) -> {
      val generated = OAGen.generateOpenApi(spec, clientName, packageName)
      val outPath = match explicitOut {
        case Some(p) -> p
        case None -> {
          val stem = stemOf(Path.basename(specPath), 5)  // strip ".json"
          stem + "_client.l"
        }
      }
      match File.writeText(outPath, generated) {
        case Ok(_) -> {
          Console.println("generated " + outPath)
          0
        }
        case Err(e) -> {
          printErr("openapi: " + IOError.message(e))
          1
        }
      }
    }
  }
}
