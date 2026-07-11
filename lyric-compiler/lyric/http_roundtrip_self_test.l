//! http_roundtrip_self_test.l — real HTTP round trips through the PUBLIC
//! `Std.Http` client API against a live `Std.HttpServer` listener.
//!
//! This is the coverage gap that let #5560 ship: no CI test ever SENT a
//! request, so `Std.Http`'s async kernel externs (`HttpClient.SendAsync` /
//! `GetAsync` / `PostAsync`, all instance externs declared without
//! `@externInstance`) were emitted as STATIC calls and every send faulted
//! at run time with MissingMethodException — invisible to the pure
//! request-shaping tests in `lyric-stdlib/tests/http_tests.l`.  It also
//! exercises the #5561 cross-assembly async encoding: `Std.Http.getAsync`,
//! `postAsync`, `sendAsync`, and `HttpResponse.bodyText` are `async func`s
//! reached through cross-assembly MemberRefs that must encode the
//! Task-wrapped kickoff return.
//!
//! Concurrency model: the listener runs in a CHILD PROCESS (a small
//! `Std.HttpServer` echo program compiled in-process via `Lyric.Emitter`
//! and launched with `dotnet exec`), while the `Std.Http` client blocks on
//! the test thread.  An in-process server thread is not an option today:
//! `Std.Task.scopeSpawn`'s `Task.Run(Action)` delegate never invokes the
//! Lyric closure on .NET (pre-existing issue #5329), and `spawn` is
//! degenerate-synchronous on MSIL.  The child echoes everything it
//! observed (method, path, the `X-Probe` request header, the request body)
//! into the response body, so every server-side observation is asserted
//! client-side in TAP output.  (Response-header READS via
//! `HttpResponse.header` are deliberately not asserted: the kernel's
//! `HttpHeaders.TryGetValues` extern — an instance extern with a
//! generic-typed `out` param — has never bound at run time, a separate
//! pre-existing FFI gap surfaced while writing this test.)  The child
//! binds its listener BEFORE writing
//! the port file the test polls, so there is no readiness race; it exits
//! on a `/quit` request or after a bounded number of requests, so a failed
//! run cannot leave it serving forever.
//!
//! IMPORTANT (CI wiring): the machine code serving and sending these
//! requests is the compiled stdlib the run links — run this with
//! `LYRIC_STDLIB_BIN` pointing at a directory that holds BOTH the stage-1
//! compiler DLLs (this module imports `Lyric.Emitter`, and
//! `LYRIC_STDLIB_BIN` also redirects compiler-DLL discovery) AND a stdlib
//! built by the SAME compiler under test (the
//! `lyric build --manifest lyric-stdlib/lyric.full.toml` output), not the
//! seed-built stdlib, or the round trip exercises the previous release's
//! codegen:
//!   mkdir -p .bootstrap/httprt-lib
//!   cp .bootstrap/stage1/*.dll .bootstrap/httprt-lib/
//!   cp lyric-stdlib/bin/Lyric.Stdlib*.dll .bootstrap/httprt-lib/
//!   LYRIC_STDLIB_BIN=$PWD/.bootstrap/httprt-lib \
//!     lyric test --target dotnet lyric-compiler/lyric/http_roundtrip_self_test.l
//!
@test_module
package Lyric.HttpRoundtripSelfTest

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

// ─── Child server program ────────────────────────────────────────────────────
// argv: <portFile> <basePort>.  Binds the first free port in
// [base, base+9], writes the bound port to portFile (AFTER the listener is
// live), then serves echo responses until a `/quit` request or a 25-request
// safety cap.  Echo body: "<method>|<path>|<X-Probe>|<body>"; status 201
// for path `/submit`, 200 otherwise.
func serverSource(): String {
  "package HttpRt.Server\n" + "\n" + "import Std.Collections\n" + "import Std.Core\n" +
    "import Std.Environment as Environment\n" +
    "import Std.File as File\n" +
    "import Std.HttpServer as Server\n" +
    "import Std.Parse as Parse\n" +
    "import Std.String as Str\n" +
    "\n" +
    "func headerValue(headers: in Map[String, String], name: in String): String {\n" +
    "  val wanted = Str.toLower(name)\n" +
    "  val names = mapKeys(headers).toArray()\n" +
    "  var i = 0\n" +
    "  while i < names.length {\n" +
    "    if Str.toLower(names[i]) == wanted {\n" +
    "      match mapGet(headers, names[i]) {\n" +
    "        case Some(v) -> return v\n" +
    "        case None -> ()\n" +
    "      }\n" +
    "    }\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  \"\"\n" +
    "}\n" +
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
    "    } else {\n" +
    "      val method = Server.requestMethod(ctx)\n" +
    "      val body = Server.requestBody(ctx)\n" +
    "      val headers = Server.requestHeaders(ctx)\n" +
    "      val probe = headerValue(headers, \"X-Probe\")\n" +
    "      val respBody = method + \"|\" + path + \"|\" + probe + \"|\" + body\n" +
    "      val status = if path == \"/submit\" { 201 } else { 200 }\n" +
    "      Server.respondText(ctx, status, respBody)\n" +
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

// ─── Harness ─────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-httprt-" + label + "-" + uuidToString(newUuid()))
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

// Co-locate the stdlib runtime DLLs beside the child server DLL so
// `dotnet exec` resolves them.  Prefers `LYRIC_STDLIB_BIN` (the CI wiring
// points it at the compiler-under-test stdlib); falls back to this test
// process's own base directory, where `lyric test` co-located the same
// stdlib it linked the test against.
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

// Build the child server DLL and return its path.
func buildServerDll(tmpDir: in String): String {
  val dllPath = Path.join(tmpDir, "HttpRtServer.dll")
  val srcs: List[String] = newList()
  srcs.add(serverSource())
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "HttpRt.Server", sources = srcs))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "HttpRtServer",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList()
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

// Spawn the child server and block until it has bound a port (it writes the
// port file only after the listener is live).  Bounded poll: ~20s.
func startServer(tmpDir: in String): RunningServer {
  val dllPath = buildServerDll(tmpDir)
  val portFile = Path.join(tmpDir, "port.txt")
  val base = 18000 + Math.longToInt(Time.nowEpochMillis() % 12000i64)
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

// Ask the child to exit, join it, and assert it saw a clean shutdown.
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
test "GET round-trip: status and echoed request line" {
  val tmpDir = freshTempDir("get")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/hello"
  val result = await getAsync(url)
  match result {
    case Err(e) -> panic("GET " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "GET status is 200")
      assertTrue(resp.isSuccess(), "GET isSuccess")
      val bodyRes = await resp.bodyText()
      match bodyRes {
        case Ok(body) -> assertEqual(body, "GET|/hello||", "server observed method GET, path /hello, no probe header, empty body")
        case Err(e) -> panic("bodyText failed: " + IOError.message(e))
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}

test "POST round-trip: request body reaches the server and is echoed back" {
  val tmpDir = freshTempDir("post")
  val srv = startServer(tmpDir)
  val url = "http://127.0.0.1:" + toString(srv.port) + "/submit"
  val result = await postAsync(url, "ping-42")
  match result {
    case Err(e) -> panic("POST " + url + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 201, "POST status is 201")
      assertTrue(resp.isSuccess(), "201 is a success status")
      val bodyRes = await resp.bodyText()
      match bodyRes {
        case Ok(body) -> assertEqual(body, "POST|/submit||ping-42", "server observed method POST, path /submit, and the text body")
        case Err(e) -> panic("bodyText failed: " + IOError.message(e))
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}

test "sendAsync round-trip: a custom request header reaches the server" {
  val tmpDir = freshTempDir("send")
  val srv = startServer(tmpDir)
  val urlStr = "http://127.0.0.1:" + toString(srv.port) + "/probe"
  val url = match Url.tryFrom(urlStr) {
    case Ok(u) -> u
    case Err(e) -> panic("unexpected InvalidUrl: " + HttpError.message(e))
  }
  val req = withHeader(request(GET, url), "X-Probe", "probe-7")
  val result = await sendAsync(req)
  match result {
    case Err(e) -> panic("sendAsync " + urlStr + " failed: " + HttpError.message(e))
    case Ok(resp) -> {
      assertEqualInt(resp.statusCode(), 200, "sendAsync status is 200")
      val bodyRes = await resp.bodyText()
      match bodyRes {
        case Ok(body) -> assertEqual(body, "GET|/probe|probe-7|", "server observed the X-Probe request header value")
        case Err(e) -> panic("bodyText failed: " + IOError.message(e))
      }
    }
  }
  stopServer(srv)
  cleanup(tmpDir)
}
