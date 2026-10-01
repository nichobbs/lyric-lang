//! tests/desktop_tests.l — the access token that admits only the desktop
//! window (Ui.Host.Web `accessToken`), and the desktop host's loader page.
//! Opening a real window is covered by `scripts/ci/ui-desktop-e2e.sh`.
@test_module
package Ui.DesktopTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Web
import Ui.Core.{View, Step, stay}
import Ui.Widgets.{paragraph}
import Ui.Host
import Ui.Host.{Instance}
import Ui.Host.Web as WebHost
import Ui.Host.Desktop as Desktop
import Ui.Session.{Program}

record Model {
  text: String
}

union Msg {
  case Nothing
}

union Eff {
  case NoEffect
}

func view(m: in Model): View[Msg] {
  return paragraph[Msg](m.text)
}

func update(m: in Model, msg: in Msg): Step[Model, Eff] {
  return stay[Model, Eff](m)
}

func page(): Instance {
  val program = Program(update = update, view = view, uiEffect = { _: Eff -> None })
  return Host.instance(program, stay[Model, Eff](Model(text = "Hello")), { _: Eff -> None })
}

func route(url: in String): Option[Instance] {
  return Some(value = page())
}

val token: String = "0123456789abcdef"

func guardedRouter(): Web.Router {
  val cfg = WebHost.defaultConfig("Guarded").copy(accessToken = token)
  match WebHost.router(cfg, route) {
    case Ok(r) -> return r
    case Err(e) -> panic("router: " + e)
  }
}

func get(path: in String, query: in Map[String, String], headers: in Map[String, String]): Web.Response {
  val req = Web.Request(
    method = "GET",
    path = path,
    pathParams = newMap(),
    queryParams = query,
    headers = headers,
    body = ""
  )
  return Web.dispatch(guardedRouter(), req)
}

func header(resp: in Web.Response, name: in String): String {
  for k in mapKeys(resp.headers) {
    if toLower(k) == toLower(name) {
      match mapGet(resp.headers, k) {
        case Some(v) -> return v
        case None -> ()
      }
    }
  }
  return ""
}

test "a page request without the token is refused" {
  val resp = get("/", newMap(), newMap())
  assertEqualInt(resp.status, 403, "no token, no cookie")
  val wrongQuery: Map[String, String] = newMap()
  wrongQuery.add(WebHost.accessQueryName, "ffff")
  assertEqualInt(get("/", wrongQuery, newMap()).status, 403, "the wrong token")
  val wrongCookie: Map[String, String] = newMap()
  wrongCookie.add("cookie", WebHost.accessCookieName + "=ffff")
  assertEqualInt(get("/", newMap(), wrongCookie).status, 403, "the wrong cookie")
}

test "the token in the query is traded for a cookie and a clean redirect" {
  val q: Map[String, String] = newMap()
  q.add(WebHost.accessQueryName, token)
  q.add("tab", "2")
  val resp = get("/orders", q, newMap())
  assertEqualInt(resp.status, 303, "redirect")
  assertEqual(header(resp, "Location"), "/orders?tab=2", "the URL without the token")
  val cookie = header(resp, "Set-Cookie")
  assertTrue(startsWith(cookie, WebHost.accessCookieName + "=" + token + ";"), cookie)
  assertTrue(contains(cookie, "HttpOnly"), "HttpOnly")
  assertTrue(contains(cookie, "SameSite=Lax"), "SameSite")
}

test "the redirect never leaves the host" {
  assertEqual(WebHost.localPath("/orders"), "/orders", "a local path is kept")
  assertEqual(WebHost.localPath("//evil.example/x"), "/", "protocol-relative")
  assertEqual(WebHost.localPath("/\\evil.example/x"), "/", "backslash form")
  assertEqual(WebHost.localPath("evil"), "/", "not a path")
}

test "the cookie admits the page" {
  val h: Map[String, String] = newMap()
  h.add("cookie", "theme=dark; " + WebHost.accessCookieName + "=" + token + "; other=1")
  val resp = get("/", newMap(), h)
  assertEqualInt(resp.status, 200, "admitted")
}

test "the runtime assets are not guarded" {
  assertEqualInt(get("/_ui/theme.css", newMap(), newMap()).status, 200, "theme")
}

test "the cookie header parser finds the access cookie only" {
  assertTrue(WebHost.presentsAccessCookie(Some(value = WebHost.accessCookieName + "=" + token), token), "alone")
  assertTrue(
    not WebHost.presentsAccessCookie(Some(value = "x" + WebHost.accessCookieName + "=" + token), token),
    "a cookie whose name merely ends with it"
  )
  assertTrue(not WebHost.presentsAccessCookie(None, token), "no header")
  assertTrue(not WebHost.presentsAccessCookie(Some(value = ""), token), "empty header")
}

test "the loader page waits for the server, then opens the app" {
  val html = Desktop.loaderHtml(
    "Acme <Books>",
    "http://127.0.0.1:5000/_ui/theme.css",
    "http://127.0.0.1:5000/?_access=ab"
  )
  assertTrue(contains(html, "<title>Acme &lt;Books&gt;</title>"), "escaped title")
  assertTrue(contains(html, "const probe = \"http://127.0.0.1:5000/_ui/theme.css\";"), "probe")
  assertTrue(contains(html, "const app = \"http://127.0.0.1:5000/?_access=ab\";"), "app")
}

test "a JavaScript string literal cannot end the script element" {
  assertEqual(Desktop.jsString("a\"b\\c"), "\"a\\\"b\\\\c\"", "quote and backslash")
  assertEqual(Desktop.jsString("</script>"), "\"\\u003c/script\\u003e\"", "angle brackets")
  assertEqual(Desktop.jsString("a\nb"), "\"a\\nb\"", "newline")
}

test "the default desktop config" {
  val cfg = Desktop.defaultConfig("Books")
  assertEqual(cfg.title, "Books", "title")
  assertEqualInt(cfg.port, 0, "a free port")
  assertEqual(cfg.startPath, "/", "start path")
}
