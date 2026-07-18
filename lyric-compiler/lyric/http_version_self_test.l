//! http_version_self_test.l — real HTTP round trips proving the
//! `HttpVersion` client default/pin (docs/61 §5.1, D128 decision 4; #5879)
//! against a live PLAINTEXT `Std.HttpServer` listener, on the .NET target.
//!
//! Concurrency model: mirrors `http_roundtrip_self_test.l` exactly, and for
//! the SAME reason (see that file's header, #5329) — the listener runs in a
//! CHILD PROCESS (a tiny `Std.HttpServer` responder compiled in-process via
//! `Lyric.Emitter` and launched with `dotnet exec`), while the `Std.Http`
//! client blocks on the test thread. `Std.Task.scopeSpawn`'s `Task.Run`
//! delegate never invokes the Lyric closure on .NET, and `spawn` is
//! degenerate-synchronous on MSIL, so an in-process listener + client
//! cannot overlap in one process on this target — `http_version_jvm_self_test.l`
//! covers the same two assertions on `--target jvm`, where `scope`/`spawn`
//! genuinely run concurrently (D120) and an in-process listener works fine.
//!
//! Coverage: plaintext responses are ALWAYS `Http11` — h2 only upgrades via
//! ALPN, which requires TLS, so this does not (and cannot) exercise real h2
//! negotiation; `Std.HttpServer` has no TLS surface yet (server TLS is
//! phase 2/3 of docs/61, tracked separately) and a live test against a
//! public HTTPS endpoint is not acceptable in CI. Two cases:
//!   1. the default client's `negotiatedVersion()` is `Http11` over
//!      plaintext, even though the client's own default is now h2-or-lower
//!      (D128 decision 3/4) — proves the default change is behavior-safe
//!      for existing plaintext consumers;
//!   2. `withHttpVersion(Http11)` also reports `Http11` (the redundant-but-
//!      exercised exact pin).
//!
//! IMPORTANT (CI wiring): same as `http_roundtrip_self_test.l` — run with
//! `LYRIC_STDLIB_BIN` pointing at a directory holding both the stage-1
//! compiler DLLs and a stdlib built by the compiler under test:
//!   mkdir -p .bootstrap/httprt-lib
//!   cp .bootstrap/stage1/*.dll .bootstrap/httprt-lib/
//!   cp lyric-stdlib/bin/Lyric.Stdlib*.dll .bootstrap/httprt-lib/
//!   LYRIC_STDLIB_BIN=$PWD/.bootstrap/httprt-lib \
//!     lyric test --target dotnet lyric-compiler/lyric/http_version_self_test.l
@test_module
package Lyric.HttpVersionSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.Environment as Environment
import Std.File as File
import Std.Http
import Std.Math as Math
import Std.Parse as Parse
import Std.Path as Path
import Std.ProcessHost as Proc
import Std.String as Str
import Std.Task as Task
import Std.Testing
import Std.Time as Time
import Std.Uuid
import Lyric.Emitter as Emitter

func versionName(v: in HttpVersion): String {
  match v {
    case Http11 -> "Http11"
    case Http2 -> "Http2"
    case Http3 -> "Http3"
  }
}

// ─── Child server program ────────────────────────────────────────────────────
// argv: <portFile> <basePort>. Binds the first free port in [base, base+9],
// writes the bound port to portFile (AFTER the listener is live), answers a
// fixed 200 OK to every request until `/quit` or a 10-request safety cap.
func serverSource(): String {
  "package HttpVerRt.Server\n" + "\n" + "import Std.Core\n" + "import Std.Environment as Environment\n" +
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
    "  while not quit and served < 10 {\n" +
    "    val ctx = Server.nextContext(l)\n" +
    "    if Server.requestPath(ctx) == \"/quit\" {\n" +
    "      Server.respondText(ctx, 200, \"bye\")\n" +
    "      quit = true\n" +
    "    } else {\n" +
    "      Server.respondText(ctx, 200, \"pong\")\n" +
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

// ─── Harness (mirrors http_roundtrip_self_test.l) ────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-httpverrt-" + label + "-" + uuidToString(newUuid()))
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
  val dllPath = Path.join(tmpDir, "HttpVerRtServer.dll")
  val srcs: List[String] = newList()
  srcs.add(serverSource())
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "HttpVerRt.Server", sources = srcs))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "HttpVerRtServer",
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
test "default client negotiatedVersion is Http11 over plaintext" {
  val tmpDir = freshTempDir("default")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/ping"
  val result = await getAsync(url)
  match result {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "status is 200")
      assertEqual(versionName(resp.negotiatedVersion()), "Http11", "plaintext default stays Http11")
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}

test "withHttpVersion(Http11) pins negotiatedVersion to Http11 over plaintext" {
  val tmpDir = freshTempDir("pin11")
  val srv = startServer(tmpDir)
  val client = HttpClientBuilder.build(HttpClientBuilder.new().withHttpVersion(Http11))
  val url = "http://127.0.0.1:" + toString(srv.port) + "/ping"
  val result = await client.get(url)
  match result {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "status is 200")
      assertEqual(versionName(resp.negotiatedVersion()), "Http11", "explicit Http11 pin holds over plaintext")
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}
