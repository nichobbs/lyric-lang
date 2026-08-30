//! rest_json_roundtrip_self_test.l — real HTTP round trips through
//! `Std.Rest.RestClient.json` against a live `Std.HttpServer` listener
//! (#1119).
//!
//! `lyric-stdlib/tests/rest_tests.l` pins the `parseJson` / `disposeJson`
//! sequence `RestClient.json` depends on, but a `HttpResponse` is `pub
//! opaque` in `Std.Http` with no test-stub constructor — that file cannot
//! exercise `RestClient.json` itself without a real HTTP response to hand
//! it. This file supplies that response the same way
//! `http_roundtrip_self_test.l` supplies one for `Std.Http`: a real
//! `Std.HttpServer` listener running in a CHILD PROCESS (an in-process
//! server thread is not an option — see that file's header for why), with
//! the client blocking on the test thread.
//!
//! Scope: the response is obtained via the free `Std.Http.getAsync`, NOT
//! `RestClient.get`. `RestClient.get` (and `.post`/`.put`/`.patch`/
//! `.delete`) route through `sendRequest` -> `fullUrl`, which is
//! runtime-broken on MSIL today (#5622: `fullUrl`'s `base.charAt(...)` on
//! a `String` read off an opaque-type field throws "unsupported method
//! 'charAt' on the receiver type" before any request is sent — verified
//! against the published 0.5.1 CLI while authoring this file). Testing
//! `RestClient.json` does not require going through `fullUrl` at all: the
//! function only needs an `HttpResponse`, which `getAsync` supplies
//! directly. This sidesteps #5622 rather than papering over it — the
//! `RestClient.get`/`.post`/... URL-building round trip stays a real,
//! tracked gap until #5622 is fixed, at which point it belongs here
//! alongside these cases (or in a sibling file).
@test_module
package Lyric.RestJsonRoundtripSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.Environment as Environment
import Std.File as File
import Std.Http
import Std.Json
import Std.Math as Math
import Std.Parse as Parse
import Std.Path as Path
import Std.ProcessHost as Proc
import Std.Rest
import Std.String as Str
import Std.Task as Task
import Std.Testing
import Std.Time as Time
import Std.Uuid
import Lyric.Emitter as Emitter

// ─── Child server program ────────────────────────────────────────────────────
// argv: <portFile> <basePort>. Binds the first free port in [base, base+9],
// writes the bound port to portFile (AFTER the listener is live), then
// serves fixed JSON/error responses until a `/quit` request or a 25-request
// safety cap:
//   /widget -> 200 application/json {"name":"widget-x","count":7,"active":true}
//   /broken -> 500 text/plain "internal error, not json"
//   other   -> 404 text/plain "not found"
func serverSource(): String {
  "package RestRt.Server\n" + "\n" + "import Std.Core\n" + "import Std.Environment as Environment\n" +
    "import Std.File as File\n" +
    "import Std.HttpServer as Server\n" +
    "import Std.Parse as Parse\n" +
    "\n" +
    "func tryStart(port: in Int): Option[Server.HttpListener] {\n" +
    "  return try {\n" +
    "    Some(value = Server.startListener(\"http://127.0.0.1:\" + toString(port) + \"/\"))\n" +
    "  } catch Bug as _ {\n" +
    "    None\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func serveLoop(l: in Server.HttpListener): Bool {\n" +
    "  var served = 0\n" +
    "  var quit = false\n" +
    "  while not quit and served < 25 {\n" +
    "    val ctx = Server.nextContext(l)\n" +
    "    val path = Server.requestPath(ctx)\n" +
    "    if path == \"/quit\" {\n" +
    "      Server.respondText(ctx, 200, \"bye\")\n" +
    "      quit = true\n" +
    "    } else if path == \"/widget\" {\n" +
    "      Server.respondJson(ctx, 200, \"{\\\"name\\\":\\\"widget-x\\\",\\\"count\\\":7,\\\"active\\\":true}\")\n" +
    "    } else if path == \"/broken\" {\n" +
    "      Server.respondText(ctx, 500, \"internal error, not json\")\n" +
    "    } else {\n" +
    "      Server.respondText(ctx, 404, \"not found\")\n" +
    "    }\n" +
    "    served = served + 1\n" +
    "  }\n" +
    "  quit\n" +
    "}\n" +
    "\n" +
    "func main(): Int {\n" +
    "  val argv = Environment.args()\n" +
    "  if argv.length < 2 {\n" +
    "    return 2\n" +
    "  }\n" +
    "  val portFile = argv[argv.length - 2]\n" +
    "  val base = Parse.parseInt(argv[argv.length - 1])\n" +
    "  var port = 0\n" +
    "  var attempt = 0\n" +
    "  while attempt < 10 {\n" +
    "    if port == 0 {\n" +
    "      match tryStart(base + attempt) {\n" +
    "        case Some(l) -> {\n" +
    "          port = base + attempt\n" +
    "          match File.writeText(portFile, toString(port)) {\n" +
    "            case Ok(_) -> ()\n" +
    "            case Err(_) -> return 4\n" +
    "          }\n" +
    "          val quit = serveLoop(l)\n" +
    "          Server.stopListener(l)\n" +
    "          if not quit {\n" +
    "            return 5\n" +
    "          }\n" +
    "        }\n" +
    "        case None -> ()\n" +
    "      }\n" +
    "    }\n" +
    "    attempt = attempt + 1\n" +
    "  }\n" +
    "  if port == 0 {\n" +
    "    return 3\n" +
    "  }\n" +
    "  0\n" +
    "}\n"
}

// ─── Harness (mirrors http_roundtrip_self_test.l — see its header for the
// concurrency-model rationale) ────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-restrt-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) } else { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write runtimeconfig beside " + dllPath + ": " + IOError.message(e))
  }
}

// Co-locate the stdlib runtime DLLs beside the child server DLL so `dotnet
// exec` resolves them. See http_roundtrip_self_test.l's copy of this helper
// for the `LYRIC_STDLIB_BIN` / CI-wiring rationale.
func copyStdlibBeside(dllPath: in String): Unit {
  val env = Environment.getVarOrDefault("LYRIC_STDLIB_BIN", "")
  val srcDir = if env.length > 0 { env } else { Environment.appBaseDirectory() }
  val destDir = Path.dirname(dllPath)
  var copied = 0
  match File.listFiles(srcDir) {
    case Err(e) -> panic("cannot list stdlib dir " + srcDir + ": " + IOError.message(e))
    case Ok(fs) -> {
      for f in fs.toArray() {
        val base = Path.basename(f)
        if Str.startsWith(base, "Lyric.Stdlib") and Str.endsWith(base, ".dll") {
          match File.readBytes(f) {
            case Ok(bs) -> {
              match File.writeBytes(Path.join(destDir, base), bs) {
                case Ok(_) -> {
                  copied = copied + 1
                }
                case Err(e) -> panic("cannot copy " + base + " beside child server: " + IOError.message(e))
              }
            }
            case Err(e) -> panic("cannot read " + f + ": " + IOError.message(e))
          }
        }
      }
    }
  }
  if copied == 0 {
    panic("no Lyric.Stdlib*.dll found in " + srcDir + " — cannot run the child server")
  }
}

func buildServerDll(tmpDir: in String): String {
  val dllPath = Path.join(tmpDir, "RestRtServer.dll")
  val srcs: List[String] = newList()
  srcs.add(serverSource())
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "RestRt.Server", sources = srcs, paths = paths))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "RestRtServer",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> panic("buildServerDll: child server compilation failed")
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  copyStdlibBeside(dllPath)
  dllPath
}

record RunningServer {
  handle: Proc.ProcessHandle
  port: Int
}

func startServer(tmpDir: in String): RunningServer {
  val dllPath = buildServerDll(tmpDir)
  val portFile = Path.join(tmpDir, "port.txt")
  val base = 19000 + Math.longToInt(Time.nowEpochMillis() % 12000i64)
  val handle = Proc.hostSpawn("dotnet", "exec " + dllPath + " " + portFile + " " + toString(base))
  var waited = 0
  while waited < 200 {
    match File.readText(portFile) {
      case Ok(content) -> {
        match Parse.parseOptInt(Str.trim(content)) {
          case Some(p) -> return RunningServer(handle = handle, port = p)
          case None -> ()
        }
      }
      case Err(_) -> ()
    }
    await Task.delay(100)
    waited = waited + 1
  }
  panic("child HTTP server did not report a bound port within 20s (portFile=" + portFile + ")")
}

func stopServer(srv: in RunningServer): Unit {
  val quitRes = await getAsync("http://127.0.0.1:" + toString(srv.port) + "/quit")
  match quitRes {
    case Ok(resp) -> assertEqualInt(resp.statusCode(), 200, "server acknowledged /quit")
    case Err(e) -> panic("/quit request failed: " + HttpError.message(e))
  }
  Proc.hostWait(srv.handle)
  assertEqualInt(Proc.hostExitCode(srv.handle), 0, "child server exited cleanly")
  Proc.hostDisposeProc(srv.handle)
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// ─── Tests ───────────────────────────────────────────────────────────────────
test "RestClient.json: live GET response parses and its fields are readable" {
  val tmpDir = freshTempDir("widget")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/widget"
  match await getAsync(url) {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "widget GET status is 200")
      match await RestClient.json(resp) {
        case Err(e) -> panic("RestClient.json unexpectedly failed on a valid JSON body: " + RestError.message(e))
        case Ok(doc) -> {
          val root = rootElement(doc)
          assertEqual(
            getString(getProperty(root, "name")),
            "widget-x",
            "json field 'name' round-tripped through a live response"
          )
          assertEqualInt(getInt32(getProperty(root, "count")), 7, "json field 'count' round-tripped through a live response")
          assertTrue(getBoolean(getProperty(root, "active")), "json field 'active' round-tripped through a live response")
          disposeJson(doc)
        }
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}

test "RestClient.json: a non-JSON live response body classifies as Deserialize" {
  val tmpDir = freshTempDir("broken")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/broken"
  match await getAsync(url) {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 500, "broken-endpoint GET status is 500")
      match await RestClient.json(resp) {
        case Ok(doc) -> {
          disposeJson(doc)
          panic("expected a non-JSON body to fail to parse")
        }
        case Err(Deserialize(_, reason)) -> assertTrue(reason.length > 0, "Deserialize reason present: " + reason)
        case Err(other) -> panic("expected Deserialize, got: " + RestError.message(other))
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}

test "RestClient.json: disposeJson is a no-op on a second call against a live-fetched doc" {
  val tmpDir = freshTempDir("dispose")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/widget"
  match await getAsync(url) {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      match await RestClient.json(resp) {
        case Err(e) -> panic("RestClient.json unexpectedly failed: " + RestError.message(e))
        case Ok(doc) -> {
          disposeJson(doc)
          disposeJson(doc)
          assertTrue(true, "second disposeJson on the same live-fetched doc returned without panic")
        }
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}
