//! lyric-compiler/lyric/stdlib_jvm_kernels_self_test.l
//!
//! @test_module covering four `lyric-stdlib/std/_kernel_jvm/*.l` kernels
//! migrated off the non-functional `extern package` mechanism onto plain
//! `extern type` + JVM auto-FFI: `environment_host.l`, `process_host.l`,
//! `log_host.l`, `unicode_host.l`.  Before this migration every function in
//! these four files crashed immediately on first call ("unsupported
//! method ... no matching user method, extern binding, or built-in
//! intrinsic") -- `extern package` parses but is a no-op in the type
//! checker and both codegens.
//!
//! Imports the KERNEL packages (`Std.EnvironmentHost` / `Std.ProcessHost` /
//! `Std.LogHost` / `Std.UnicodeHost`) directly rather than their public
//! wrappers (`Std.Environment` / `Std.Process` / `Std.Log`): three of the
//! four public wrappers currently hit separate, pre-existing, unrelated JVM
//! codegen bugs found while migrating these kernels (tracked as issues
//! #5377, #5378, #5380, #5381 -- see docs/03-decision-log.md for the full
//! writeup), so testing through them would conflate those bugs with this
//! migration's own correctness.  This file verifies the kernel functions
//! themselves resolve and behave correctly; the public-wrapper bugs are
//! each separately tracked and unaffected by this migration.
//!
//! `Std.EnvironmentHost.hostExit` / `Std.EnvironmentHost.
//! hostGetCommandLineArgs` are not exercised here: the former terminates
//! the JVM process (incompatible with a test harness expecting the process
//! to complete and report every test), the latter panics deliberately
//! (tracked as issue #5377) -- both are manually verified in the PR
//! description instead.
//!
//! Also covers the docs/59 F-1a/F-1b/F-1c phantom-kernel remediation wave:
//! `format_host.l` (rewritten off the phantom `lyric.stdlib.jvm.FormatHost`
//! onto BigDecimal/Integer/Locale), `path_host.l` (pure Lyric, System.IO.Path
//! semantics), `regex_host.l` (Pattern/Matcher via auto-FFI), and the
//! `math_host.l` intToLong/longToInt additions.  These cases go through the
//! PUBLIC modules (`Std.Format` / `Std.Path` / `Std.Regex` / `Std.Math`) —
//! the modules that were non-functional on this target — and every expected
//! literal below was captured from a `--target dotnet` run of the same
//! expression, so the assertions double as cross-target parity checks.
//!
//! Also covers the last two phantom-kernel rewrites (docs/59 F-1c, #2663):
//! `http_host.l` (java.net.http.HttpClient) and `http_server.l`
//! (com.sun.net.httpserver.HttpServer), which retired the final
//! `lyric.stdlib.jvm.*` bindings.  These cases run REAL local HTTP round
//! trips through the PUBLIC `Std.Http` / `Std.HttpServer` APIs -- server on
//! an ephemeral 127.0.0.1 port in a spawned virtual thread, client driving
//! it -- proving the two kernels against each other network-free.
//!
//! Run via `lyric test --target jvm` so the self-hosted Jvm.Bridge pipeline
//! is exercised end-to-end.
@test_module
package Lyric.StdlibJvmKernelsSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.EnvironmentHost
import Std.ProcessHost
import Std.LogHost
import Std.UnicodeHost
import Std.Format as Fmt
import Std.FormatHost as FmtHost
import Std.Path as Path
import Std.Math as Math
import Std.JvmExceptionHost
import Std.Regex as Rx
// Std.RegexSafe's API is typed in terms of the raw Std.RegexHost handle
// types (`RxKernel.Regex` / `RxKernel.Match`), so consuming it requires the
// kernel import too — the `Regex` extern alias must be in this file's extern
// seed for the Ok-payload binding to checkcast to java.util.regex.Pattern.
import Std.RegexHost as RxHost
import Std.RegexSafe as RxSafe
import Std.Http
import Std.HttpServer as HttpSrv
import Std.Task
import Std.Time

// Concrete unchecked Exception subclass used to exercise the
// Std.JvmExceptionHost accessors without an FFI boundary crossing.
extern type JKernelTestException = "java.lang.IllegalStateException"

// ── Std.EnvironmentHost ─────────────────────────────────────────────────────
test "hostGetVarOpt resolves a real environment variable via System.getenv" {
  // PATH is set in every POSIX process launched from a shell, including the
  // JVM this test runs under.
  match hostGetVarOpt("PATH") {
    case Some(v) -> assertTrue(v.length > 0, "PATH is set and non-empty")
    case None -> panic("PATH should be set in the test environment")
  }
}

test "hostGetVarOpt returns None for a variable that is not set" {
  match hostGetVarOpt("LYRIC_DEFINITELY_NOT_SET_KERNEL_TEST_XYZ") {
    case Some(_) -> panic("unexpected: variable should not be set")
    case None -> assertTrue(true, "correctly absent")
  }
}

test "hostRuntimeDirectory / hostRuntimeIdentifier / hostSetEnvironmentVariable do not crash" {
  // .NET-only concepts with no JVM equivalent; the empty-string /
  // no-op stubs must resolve and run without throwing.
  assertEqual(hostRuntimeDirectory(), "", "hostRuntimeDirectory is the empty-string stub on JVM")
  assertEqual(hostRuntimeIdentifier(), "", "hostRuntimeIdentifier is the empty-string stub on JVM")
  hostSetEnvironmentVariable("LYRIC_KERNEL_TEST_NOOP", "x")
  assertTrue(true, "hostSetEnvironmentVariable's no-op stub did not crash")
}

test "hostAppBaseDirectory is the empty-string stub; hostCurrentDirectory returns a real absolute path" {
  // hostAppBaseDirectory has no accurate JVM equivalent to .NET's
  // AppContext.BaseDirectory (see the kernel's doc comment) -- "" per the
  // established "empty = unavailable" convention, not a plausible-looking
  // but potentially wrong cwd substitute.
  assertEqual(hostAppBaseDirectory(), "", "hostAppBaseDirectory is the empty-string stub on JVM")
  // hostCurrentDirectory IS a genuine, accurate JVM equivalent (user.dir).
  val cwd = hostCurrentDirectory()
  assertTrue(cwd.length > 0, "hostCurrentDirectory is non-empty")
  assertTrue(cwd.startsWith("/"), "hostCurrentDirectory is a real POSIX absolute path")
}

test "hostGetCommandLineArgs panics (issue #5377) rather than crashing on the old extern package no-op" {
  // Regression for the JDK-has-no-argv-retrieval gap (issue #5377): this
  // must fail loud, not the generic "unsupported method" crash the old
  // extern package no-op produced.  Uses assertPanics (occurrence only),
  // not assertPanicsWith (message content): a closure-propagated panic's
  // .message is unreliable on JVM (issue #5388, found while writing this
  // test), independent of hostGetCommandLineArgs itself -- manually
  // verified the real panic text separately (see the PR description).
  //
  // The trailing `; ()` is required, not stylistic (issue #5393):
  // `hostGetCommandLineArgs`'s declared return type is `slice[String]`
  // (its body unconditionally panics, but that's a runtime fact, not a
  // static one -- the type checker only infers `Never` for a closure body
  // whose registered return type already says so, e.g. a bare
  // `{ -> panic(...) }`).  `assertPanics` expects `fn: in () -> Unit`, and
  // `argSatisfiesParam` has no "declared-Unit-parameter discards any
  // return type" rule for closure arguments, so `{ -> hostGetCommandLineArgs() }`
  // alone fails to type-check (T0043).  Appending `; ()` makes the
  // closure's own inferred return type genuinely `Unit`.
  assertPanics(
    "hostGetCommandLineArgs panics rather than returning/crashing silently",
    { -> hostGetCommandLineArgs(); () }
  )
}

// ── Std.ProcessHost ──────────────────────────────────────────────────────────
test "hostSpawn/hostWait/hostExitCode/hostDisposeProc run a real child process" {
  val proc = hostSpawn("/bin/sh", "\"-c\" \"exit 7\"")
  hostWait(proc)
  val code = hostExitCode(proc)
  hostDisposeProc(proc)
  assertEqualInt(code, 7, "child process exit code round-trips through ProcessBuilder/Process")
}

test "hostSpawn/hostWait/hostExitCode with a zero exit code" {
  val proc = hostSpawn("/bin/sh", "\"-c\" \"exit 0\"")
  hostWait(proc)
  val code = hostExitCode(proc)
  hostDisposeProc(proc)
  assertEqualInt(code, 0, "successful child process reports exit code 0")
}

// ── Std.LogHost ────────────────────────────────────────────────────────────
test "write resolves and runs without crashing (java.util.logging.Logger reference removed)" {
  // The old header comment claimed a java.util.logging.Logger-backed shim;
  // this kernel now matches the .NET twin exactly (a plain stderr write via
  // Std.ConsoleHost).  Capturing stderr content isn't exercised here; this
  // asserts the call resolves and returns rather than crashing the way the
  // extern package no-op did on every prior call.
  write("INFO", "stdlib_jvm_kernels_self_test smoke message")
  assertTrue(true, "Std.LogHost.write ran without throwing")
}

// ── Std.UnicodeHost ──────────────────────────────────────────────────────────
//
// Verifies jvmCategoryToNetConvention's translation table against known
// .NET System.Globalization.UnicodeCategory ordinals, cross-checked against
// an identical dotnet-target run of the same code points (see this PR's
// description) -- all five matched exactly.
test "hostUnicodeCategory matches the .NET UnicodeCategory convention for common categories" {
  assertEqualInt(hostUnicodeCategory('A'), 0, "'A' is UppercaseLetter (0)")
  assertEqualInt(hostUnicodeCategory('a'), 1, "'a' is LowercaseLetter (1)")
  assertEqualInt(hostUnicodeCategory('0'), 8, "'0' is DecimalDigitNumber (8)")
  assertEqualInt(hostUnicodeCategory('_'), 18, "'_' is ConnectorPunctuation (18)")
  assertEqualInt(hostUnicodeCategory(' '), 11, "' ' is SpaceSeparator (11)")
}

test "hostUnicodeCategory matches the .NET UnicodeCategory convention for less common categories" {
  assertEqualInt(hostUnicodeCategory('('), 20, "'(' is OpenPunctuation (20)")
  assertEqualInt(hostUnicodeCategory(')'), 21, "')' is ClosePunctuation (21)")
  assertEqualInt(hostUnicodeCategory('-'), 19, "'-' is DashPunctuation (19)")
  assertEqualInt(hostUnicodeCategory('+'), 25, "'+' is MathSymbol (25)")
  assertEqualInt(hostUnicodeCategory('$'), 26, "'$' is CurrencySymbol (26)")
}

// ── Std.Format (docs/59 F-1a) ────────────────────────────────────────────────
//
// Every expected literal below is the output of the same expression run on
// `--target dotnet` (System.Int32.ToString / System.Double.ToString with the
// invariant culture).
test "Std.Format hex formatting matches the .NET twin" {
  assertEqual(Fmt.toHexString(255), "ff", "toHexString(255)")
  assertEqual(Fmt.toHexString(16), "10", "toHexString(16)")
  assertEqual(Fmt.toHexString(0), "0", "toHexString(0)")
  assertEqual(Fmt.toHexString(0 - 1), "ffffffff", "toHexString(-1) is two's complement")
  assertEqual(Fmt.toHexStringUpper(255), "FF", "toHexStringUpper(255)")
  assertEqual(Fmt.hexPad(255, 4), "00ff", "hexPad(255, 4)")
  assertEqual(Fmt.hexPadUpper(255, 4), "00FF", "hexPadUpper(255, 4)")
  assertEqual(Fmt.zeroPad(7, 3), "007", "zeroPad(7, 3)")
}

test "Std.Format formatFixed matches the .NET invariant fixed-point output" {
  assertEqual(Fmt.formatFixed(3.14159, 2), "3.14", "formatFixed(3.14159, 2)")
  assertEqual(Fmt.formatFixed(1.0, 4), "1.0000", "formatFixed(1.0, 4)")
  assertEqual(Fmt.formatFixed(0.1, 2), "0.10", "formatFixed(0.1, 2)")
  // Round-half-to-even over the EXACT binary value, like .NET: 0.125 is
  // exactly representable (half → even → 2), while the 2.675 literal is
  // 2.67499999… so it rounds DOWN despite looking like a half-up case.
  assertEqual(Fmt.formatFixed(0.125, 2), "0.12", "formatFixed(0.125, 2) half-to-even")
  assertEqual(Fmt.formatFixed(2.675, 2), "2.67", "formatFixed(2.675, 2) exact-value rounding")
  assertEqual(Fmt.formatFixed(0.0 - 1.005, 2), "-1.00", "formatFixed(-1.005, 2)")
}

test "Std.FormatHost kernel surface parity: D specifier, non-finite and negative-zero doubles" {
  assertEqual(FmtHost.hostIntToString(42, "D5"), "00042", "hostIntToString(42, D5)")
  assertEqual(FmtHost.hostIntToString(0 - 42, "D5"), "-00042", "hostIntToString(-42, D5) pads after the sign")
  assertEqual(FmtHost.hostIntToString(255, "x8"), "000000ff", "hostIntToString(255, x8)")
  assertEqual(FmtHost.hostIntToString(42, "G"), "42", "hostIntToString(42, G)")
  val inv = FmtHost.hostInvariantCulture()
  assertEqual(FmtHost.hostDoubleToString(0.0 / 0.0, "F2", inv), "NaN", "NaN spelling")
  assertEqual(FmtHost.hostDoubleToString(1.0 / 0.0, "F2", inv), "Infinity", "+inf spelling")
  assertEqual(FmtHost.hostDoubleToString((0.0 - 1.0) / 0.0, "F2", inv), "-Infinity", "-inf spelling")
  // .NET preserves the sign of negative zero and of negatives that round to 0.
  assertEqual(FmtHost.hostDoubleToString((0.0 - 1.0) * 0.0, "F2", inv), "-0.00", "negative zero keeps its sign")
  assertEqual(FmtHost.hostDoubleToString(0.0 - 0.4, "F0", inv), "-0", "-0.4 rounds to signed zero")
}

// ── Std.Path (docs/59 F-1c) ──────────────────────────────────────────────────
//
// Expected literals captured from a `--target dotnet` run (System.IO.Path on
// POSIX).
test "Std.Path join matches System.IO.Path.Combine" {
  assertEqual(Path.join("/home/user", "projects"), "/home/user/projects", "join absolute base")
  assertEqual(Path.join("a/", "b"), "a/b", "trailing separator not doubled")
  assertEqual(Path.join("a", "/b"), "/b", "rooted relative wins")
  assertEqual(Path.join("", "b"), "b", "empty base")
  assertEqual(Path.join("a", ""), "a", "empty relative")
}

test "Std.Path extension/basename match System.IO.Path" {
  assertEqual(Path.extension("file.txt"), ".txt", "extension(file.txt)")
  assertEqual(Path.extension("archive.tar.gz"), ".gz", "extension takes the final suffix")
  assertEqual(Path.extension("README"), "", "no extension")
  assertEqual(Path.extension("file."), "", "trailing dot is no extension")
  assertEqual(Path.extension(".gitignore"), ".gitignore", "dotfile is all extension")
  assertEqual(Path.extension("d.x/file"), "", "dot in directory component ignored")
  assertEqual(Path.basename("/a/b.txt"), "b.txt", "basename of absolute path")
  assertEqual(Path.basename("/a/b/"), "", "trailing separator yields empty basename")
  assertEqual(Path.basename("b.txt"), "b.txt", "bare filename")
}

test "Std.Path dirname/isAbsolute match System.IO.Path" {
  assertEqual(Path.dirname("/a/b.txt"), "/a", "dirname of file in directory")
  assertEqual(Path.dirname("/a/b/"), "/a/b", "trailing separator preserved (no normalization)")
  assertEqual(Path.dirname("/a//b"), "/a", "doubled separator trimmed from result")
  assertEqual(Path.dirname("/a"), "/", "parent of top-level entry is the root")
  assertEqual(Path.dirname("/"), ".", "root maps to . through the public dirname")
  assertEqual(Path.dirname("a"), ".", "bare filename maps to .")
  assertEqual(Path.dirname("a/b"), "a", "relative path")
  assertTrue(Path.isAbsolute("/a"), "isAbsolute(/a)")
  assertFalse(Path.isAbsolute("a"), "isAbsolute(a)")
  assertTrue(Path.isRelative(""), "empty path is relative by convention")
}

// ── Std.Regex (docs/59 F-1c) ─────────────────────────────────────────────────
test "Std.Regex compile/isMatch/replace work over java.util.regex" {
  val r = Rx.compile("a+b")
  assertTrue(Rx.isMatch(r, "xxaab!"), "isMatch finds an interior match")
  assertFalse(Rx.isMatch(r, "zzz"), "isMatch is false with no match")
  assertEqual(Rx.replace(r, "xxaab!", "Z"), "xxZ!", "replace substitutes every match")
  // Timeout parameter is accepted (unenforced on JVM pending #1103).
  val rt = Rx.compileWithTimeout("b+", 5.0)
  assertTrue(Rx.isMatch(rt, "abc"), "compileWithTimeout produces a working pattern")
}

test "Std.Regex Result-shaped API classifies invalid patterns" {
  match Rx.tryCompile("(unclosed") {
    case Ok(_) -> panic("tryCompile should reject an unclosed group")
    case Err(e) -> assertTrue(Rx.errorMessage(e).startsWith("invalid regex pattern"), "syntax error classified as InvalidPattern")
  }
  val r = Rx.compile("a+b")
  match Rx.tryIsMatch(r, "xxaab!") {
    case Ok(v) -> assertTrue(v, "tryIsMatch Ok(true)")
    case Err(_) -> panic("tryIsMatch should not fail on a valid match")
  }
}

test "Std.RegexSafe tryMatchOne returns a positioned Matcher handle" {
  match RxSafe.tryCompile("a+b") {
    case Ok(r) -> {
      match RxSafe.tryMatchOne(r, "xxaab!") {
        case Ok(_) -> assertTrue(true, "tryMatchOne resolves hostMatchOne")
        case Err(_) -> panic("tryMatchOne should succeed on a valid pattern")
      }
    }
    case Err(_) -> panic("tryCompile should accept a valid pattern")
  }
}

// ── Std.JvmExceptionHost (docs/59 F-1c) ──────────────────────────────────────
//
// `jvmExceptionTypeName` previously routed through a phantom
// `lyric.runtime.jvm.ExceptionHelper` class; it is now a pure-Lyric
// getClass().getName() chain.  A concrete Exception subclass instance stands
// in for a checked exception caught at the FFI boundary (same JVM class
// hierarchy, no boundary crossing needed for the accessor contract).
test "jvmExceptionTypeName/-Message read through real JDK calls" {
  val e = JKernelTestException.new("boom")
  assertEqual(jvmExceptionTypeName(e), "java.lang.IllegalStateException", "fully-qualified class name")
  assertEqual(jvmExceptionMessage(e), "boom", "detail message")
}

// ── Std.Math intToLong/longToInt (docs/59 F-1b) ─────────────────────────────
test "Std.Math intToLong/longToInt round-trip and panic on overflow" {
  val widened = Math.intToLong(2000000000)
  assertEqualInt(Math.longToInt(widened), 2000000000, "round-trip preserves the value")
  assertEqualInt(Math.longToInt(Math.intToLong(0 - 7)), 0 - 7, "negative round-trip")
  val overflowing = widened + widened
  // Matches the .NET twin's System.Convert.ToInt32 OverflowException panic
  // (java.lang.Math.toIntExact throws ArithmeticException).
  assertPanics("longToInt panics on a value outside Int range", { -> Math.longToInt(overflowing); () })
}

// ── Std.Http / Std.HttpServer (docs/59 F-1c, #2663) ─────────────────────────
//
// End-to-end round trips over 127.0.0.1: Std.HttpServer serves, Std.Http
// drives it — all through the PUBLIC std APIs, proving the two rewritten
// `_kernel_jvm` kernels (the last two `lyric.stdlib.jvm.*` phantoms) against
// each other with no external network.  Each test runs its server exchange
// as a `scope { spawn ... }` virtual thread and joins it (`await`) after the
// client call returns — a bare no-scope `spawn` is degenerate-synchronous on
// this target, so the scope form is required for genuine concurrency; a
// server-side panic propagates through the join.  Every client call goes
// through the *WithTimeout*/*WithCancel* family so a kernel regression fails
// the run with a timeout Err instead of hanging CI.
// Where an asserted literal is target-neutral (status codes, echo bodies,
// urlDecode outputs), it matches what the .NET twins produce for the same
// public-API calls.
record HttpTestSrv {
  listener: HttpSrv.HttpListener
  port: Int
}

// Time-derived local port with bind-failure retry: the public startListener
// contract (mirroring .NET HttpListener prefixes) has no port-0
// "pick-for-me" form, so the test derives a port and strides on collision.
func startTestListener(offset: in Int): HttpTestSrv {
  var attempt = 0
  while attempt < 5 {
    val port = 30000 + Math.longToInt(nowEpochMillis() % 20000i64) + offset + attempt * 131
    val started = try {
      Some(value = HttpSrv.startListener("http://127.0.0.1:" + port.toString() + "/"))
    } catch Bug as _ {
      None
    }
    match started {
      case Some(l) -> return HttpTestSrv(listener = l, port = port)
      case None -> ()
    }
    attempt = attempt + 1
  }
  panic("no free local port for the HTTP kernel round-trip test")
}

// One echo exchange: method|path|rawQuery|decodedQuery|X-tag|body — a single
// response exercising requestMethod / requestPath / requestQuery /
// requestHeaders / urlDecode / requestBody / respondText.
func serveEchoOnce(l: in HttpSrv.HttpListener): Unit {
  val ctx = HttpSrv.nextContext(l)
  val method = HttpSrv.requestMethod(ctx)
  val path = HttpSrv.requestPath(ctx)
  val query = HttpSrv.requestQuery(ctx)
  val headers = HttpSrv.requestHeaders(ctx)
  // com.sun.net.httpserver.Headers normalizes header-name capitalization
  // ("X-Tag" arrives as "X-tag"); names are case-insensitive per RFC 7230.
  val tag = match mapGet(headers, "X-tag") { case Some(v) -> v; case None -> "(absent)" }
  val body = HttpSrv.requestBody(ctx)
  HttpSrv.respondText(
    ctx,
    200,
    method + "|" + path + "|" + query + "|" + HttpSrv.urlDecode(query) + "|" + tag + "|" + body
  )
}

func serveJsonOnce(l: in HttpSrv.HttpListener): Unit {
  val ctx = HttpSrv.nextContext(l)
  HttpSrv.respondJson(ctx, 201, "{\"ok\":true}")
}

func serveBytesOnce(l: in HttpSrv.HttpListener): Unit {
  val ctx = HttpSrv.nextContext(l)
  val extra: Map[String, String] = newMap()
  extra.add("X-Kernel-Probe", "forty-two")
  val payload: List[Byte] = newList()
  payload.add(97)
  payload.add(98)
  payload.add(99)
  HttpSrv.respondBytesWithHeaders(ctx, 202, "application/octet-stream", payload.toArray(), extra)
}

// 302 to /target, then 200 on the follow-up — one function so a single
// spawn serves the redirect-following client's two requests in order.
func serveRedirectThenTarget(l: in HttpSrv.HttpListener): Unit {
  val ctx = HttpSrv.nextContext(l)
  val extra: Map[String, String] = newMap()
  extra.add("Location", "/target")
  val empty: List[Byte] = newList()
  HttpSrv.respondBytesWithHeaders(ctx, 302, "text/plain; charset=utf-8", empty.toArray(), extra)
  val ctx2 = HttpSrv.nextContext(l)
  HttpSrv.respondText(ctx2, 200, "after-redirect|" + HttpSrv.requestPath(ctx2))
}

func serveRedirectOnce(l: in HttpSrv.HttpListener): Unit {
  val ctx = HttpSrv.nextContext(l)
  val extra: Map[String, String] = newMap()
  extra.add("Location", "/target")
  val empty: List[Byte] = newList()
  HttpSrv.respondBytesWithHeaders(ctx, 302, "text/plain; charset=utf-8", empty.toArray(), extra)
}

// Client summaries flatten status/headers/body into one assertable string so
// each test block stays a single await + assertEqual.
async func getEchoSummary(port: in Int): String {
  val r = await getWithTimeoutAsync("http://127.0.0.1:" + port.toString() + "/hello?a=1&msg=hi%20there", 10000)
  match r {
    case Err(e) -> return "GET failed: " + HttpError.message(e)
    case Ok(resp) -> {
      var ct = "(none)"
      match HttpResponse.header(resp, "Content-Type") {
        case Some(v) -> {
          ct = v
        }
        case None -> ()
      }
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + ct + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

async func postEchoSummary(port: in Int): String {
  val r = await postWithTimeoutAsync("http://127.0.0.1:" + port.toString() + "/echo", "ping-body", 10000)
  match r {
    case Err(e) -> return "POST failed: " + HttpError.message(e)
    case Ok(resp) -> {
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

async func headerEchoSummary(port: in Int): String {
  val url = match Url.tryFrom("http://127.0.0.1:" + port.toString() + "/hdr") {
    case Ok(u) -> u
    case Err(_) -> return "bad url"
  }
  val req = withHeader(request(GET, url), "X-Tag", "kernel-tag")
  val r = await sendWithTimeoutAsync(req, 10000)
  match r {
    case Err(e) -> return "send failed: " + HttpError.message(e)
    case Ok(resp) -> {
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

async func jsonSummary(port: in Int): String {
  val r = await getWithTimeoutAsync("http://127.0.0.1:" + port.toString() + "/json", 10000)
  match r {
    case Err(e) -> return "GET failed: " + HttpError.message(e)
    case Ok(resp) -> {
      var ct = "(none)"
      match HttpResponse.header(resp, "Content-Type") {
        case Some(v) -> {
          ct = v
        }
        case None -> ()
      }
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + ct + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

// Byte content is asserted through both views of the same buffered body:
// bodyBytes length plus bodyText over the identical bytes.  (Per-element
// user-code access to a cross-package `slice[Byte]` payload is a
// pre-existing JVM ABI gap — the payload arrives as a boxed Byte[] that is
// neither indexable nor iterable — so the text view carries the content
// assertion.)
async func bytesSummary(port: in Int): String {
  val r = await getWithTimeoutAsync("http://127.0.0.1:" + port.toString() + "/bytes", 10000)
  match r {
    case Err(e) -> return "GET failed: " + HttpError.message(e)
    case Ok(resp) -> {
      var probe = "(none)"
      match HttpResponse.header(resp, "X-Kernel-Probe") {
        case Some(v) -> {
          probe = v
        }
        case None -> ()
      }
      var lenText = "?"
      val bb = await HttpResponse.bodyBytes(resp)
      match bb {
        case Ok(bytes) -> {
          lenText = bytes.length.toString()
        }
        case Err(_) -> return "bodyBytes failed"
      }
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + probe + "|" + lenText + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

async func followRedirectSummary(port: in Int): String {
  val r = await getWithTimeoutAsync("http://127.0.0.1:" + port.toString() + "/hop", 10000)
  match r {
    case Err(e) -> return "GET failed: " + HttpError.message(e)
    case Ok(resp) -> {
      val bt = await HttpResponse.bodyText(resp)
      match bt {
        case Ok(text) -> return HttpResponse.statusCode(resp).toString() + "|" + text
        case Err(_) -> return "bodyText failed"
      }
    }
  }
  "unreachable"
}

// Drives the HttpClient interface surface (clientNoRedirects + sendWithCancel
// with a timeout token) rather than the free functions, so the configured-
// client path through HttpClientImpl is exercised too.
async func noFollowRedirectSummary(port: in Int): String {
  val url = match Url.tryFrom("http://127.0.0.1:" + port.toString() + "/hop") {
    case Ok(u) -> u
    case Err(_) -> return "bad url"
  }
  val client = clientNoRedirects()
  val src = makeCancelSourceTimeout(10000)
  val tok = sourceToken(src)
  val r = await client.sendWithCancel(request(GET, url), tok)
  disposeSource(src)
  match r {
    case Err(e) -> return "send failed: " + HttpError.message(e)
    case Ok(resp) -> {
      var loc = "(none)"
      match HttpResponse.header(resp, "Location") {
        case Some(v) -> {
          loc = v
        }
        case None -> ()
      }
      return HttpResponse.statusCode(resp).toString() + "|" + loc
    }
  }
  "unreachable"
}

// Network-free: an already-cancelled token must surface as Err before any
// connection is attempted (cooperative cancellation on this target).
async func cancelledSendSummary(): String {
  val src = makeCancelSource()
  cancelSource(src)
  val tok = sourceToken(src)
  val url = match Url.tryFrom("http://127.0.0.1:9/never") { case Ok(u) -> u; case Err(_) -> return "bad url" }
  val r = await sendWithCancelAsync(request(GET, url), tok)
  match r {
    case Ok(_) -> return "unexpected ok"
    case Err(e) -> return HttpError.message(e)
  }
  "unreachable"
}

test "Std.Http GET drives Std.HttpServer: status, content-type, query, urlDecode, header map, body echo" {
  val srv = startTestListener(0)
  var summary = ""
  scope {
    val serverTask = spawn serveEchoOnce(srv.listener)
    val s = await getEchoSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(
    summary,
    "200|text/plain; charset=utf-8|GET|/hello|a=1&msg=hi%20there|a=1&msg=hi there|(absent)|",
    "GET round trip through the public APIs"
  )
}

test "Std.Http POST body round-trips through Std.HttpServer.requestBody" {
  val srv = startTestListener(700)
  var summary = ""
  scope {
    val serverTask = spawn serveEchoOnce(srv.listener)
    val s = await postEchoSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "200|POST|/echo|||(absent)|ping-body", "POST round trip echoes the request body")
}

test "request headers cross the boundary: withHeader -> requestHeaders map" {
  val srv = startTestListener(1400)
  var summary = ""
  scope {
    val serverTask = spawn serveEchoOnce(srv.listener)
    val s = await headerEchoSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "200|GET|/hdr|||kernel-tag|", "custom request header observed by the server")
}

test "respondJson sets application/json and the verbatim body" {
  val srv = startTestListener(2100)
  var summary = ""
  scope {
    val serverTask = spawn serveJsonOnce(srv.listener)
    val s = await jsonSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "201|application/json; charset=utf-8|{\"ok\":true}", "JSON response round trip")
}

test "respondBytesWithHeaders: byte body, custom header, and both body views" {
  val srv = startTestListener(2800)
  var summary = ""
  scope {
    val serverTask = spawn serveBytesOnce(srv.listener)
    val s = await bytesSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "202|forty-two|3|abc", "byte-body response with extra headers")
}

test "default client follows a 302 served by Std.HttpServer" {
  val srv = startTestListener(3500)
  var summary = ""
  scope {
    val serverTask = spawn serveRedirectThenTarget(srv.listener)
    val s = await followRedirectSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "200|after-redirect|/target", "redirect followed to the target path")
}

test "clientNoRedirects surfaces the 302 and its Location header" {
  val srv = startTestListener(4200)
  var summary = ""
  scope {
    val serverTask = spawn serveRedirectOnce(srv.listener)
    val s = await noFollowRedirectSummary(srv.port)
    summary = s
    await serverTask
  }
  HttpSrv.stopListener(srv.listener)
  assertEqual(summary, "302|/target", "3xx returned to the caller with Location intact")
}

test "an already-cancelled token fails a send before connecting" {
  val summary = await cancelledSendSummary()
  assertTrue(summary.contains("cancellation was requested"), "cancellation classified in the Err message")
}

test "Std.HttpServer.urlDecode matches Uri.UnescapeDataString semantics" {
  assertEqual(HttpSrv.urlDecode("hi%20there"), "hi there", "%20 decodes to a space")
  assertEqual(HttpSrv.urlDecode("a+b"), "a+b", "plus is NOT a space (UnescapeDataString, not form decoding)")
  assertEqual(HttpSrv.urlDecode("100%"), "100%", "lone percent passes through")
  assertEqual(HttpSrv.urlDecode("%GG"), "%GG", "invalid escape passes through")
  assertEqual(HttpSrv.urlDecode("caf%C3%A9"), "café", "multi-byte UTF-8 run decodes as one code point")
  assertEqual(HttpSrv.urlDecode("%E2%82%AC5"), "€5", "three-byte UTF-8 escape run decodes")
}

test "unsupported JVM paths fail loudly: Unix-socket client and https prefix" {
  // Fail-loud stubs (tracked in #2663): a wrong-but-running TCP client or a
  // silently-plaintext "https" server would be worse than a panic.
  assertPanics("clientWithUnixSocket panics on the JVM target", { -> clientWithUnixSocket("/var/run/docker.sock"); () })
  assertPanics(
    "https startListener prefix panics on the JVM target",
    { -> HttpSrv.startListener("https://127.0.0.1:8443/"); () }
  )
}
