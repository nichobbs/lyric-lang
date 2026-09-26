//! tests/host_tests.l — Ui.Host (the shared session driver) through an
//! in-memory outbox, and the Ui.Host.Web shell helpers.
@test_module
package Ui.HostTests

import Std.Core
import Std.String
import Std.Testing
import Ui.Core.{View, Step, UiEffect, Notify, ToastLevel, stay, step1}
import Ui.Widgets.{button, column, paragraph}
import Ui.Protocol.{decodeClient, ClientMessage}
import Ui.Host
import Ui.Host.{Instance, Outbox}
import Ui.Host.Web
import Ui.Session.{Program}

protected type Recorder {
  var sent: List[String] = newList()
  entry push(text: in String): Unit {
    sent.add(text)
  }
  func all(): List[String] {
    return sent
  }
}

record RecordingOutbox {
  rec: Recorder
}

impl Outbox for RecordingOutbox {
  func send(text: in String): Unit {
    self.rec.push(text)
  }
}

record Model {
  status: String
}

union Msg {
  case Save
  case Saved
}

union Effect {
  case Persist
  case Ui(effect: UiEffect[Msg])
}

func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Save -> step1(Model(status = "saving"), Persist)
    case Saved -> step1(
      Model(status = "saved"),
      Ui(effect = Notify(message = "Done", level = ToastLevel.Success))
    )
  }
}

func view(m: in Model): View[Msg] {
  val cs: List[View[Msg]] = newList()
  cs.add(paragraph[Msg](m.status))
  cs.add(button[Msg]("Save", Save))
  return column[Msg](cs)
}

func program(): Program[Model, Msg, Effect] {
  return Program(
    update = update,
    view = view,
    uiEffect = { e: Effect -> match e { case Ui(u) -> Some(value = u); case _ -> None } }
  )
}

func msg(text: in String): ClientMessage {
  return match decodeClient(text) { case Ok(m) -> m; case Err(e) -> panic("test message did not decode: " + e) }
}

test "start sends the initial render" {
  val rec = Recorder()
  val inst = Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
  inst.start(RecordingOutbox(rec = rec))
  val sent = rec.all()
  assertEqualInt(sent.count, 1, "one message")
  assertTrue(contains(sent[0], "\"op\":\"replace\""), sent[0])
  assertTrue(contains(sent[0], "idle"), sent[0])
}

test "a click sends the busy state before the effect result" {
  val rec = Recorder()
  val outbox = RecordingOutbox(rec = rec)
  val inst = Host.instance(
    program(),
    stay[Model, Effect](Model(status = "idle")),
    { e: Effect -> match e { case Persist -> Some(value = Saved); case _ -> None } }
  )
  inst.start(outbox)
  // Root column[app, overlay]; app column[paragraph, button].
  inst.receive(msg("{\"t\":\"event\",\"v\":1,\"p\":[0,1],\"e\":\"click\"}"), outbox)
  val sent = rec.all()
  assertEqualInt(sent.count, 4, "render, saving patch, saved patch, toast")
  assertTrue(contains(sent[1], "\"v\":\"saving\""), sent[1])
  assertTrue(contains(sent[2], "\"v\":\"saved\""), sent[2])
  assertTrue(contains(sent[3], "\"t\":\"toast\""), sent[3])
}

test "a stale event sends nothing" {
  val rec = Recorder()
  val outbox = RecordingOutbox(rec = rec)
  val inst = Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
  inst.start(outbox)
  inst.receive(msg("{\"t\":\"event\",\"v\":1,\"p\":[0,7],\"e\":\"click\"}"), outbox)
  assertEqualInt(rec.all().count, 1, "only the initial render")
}

test "sync resends the whole tree" {
  val rec = Recorder()
  val outbox = RecordingOutbox(rec = rec)
  val inst = Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
  inst.start(outbox)
  inst.receive(msg("{\"t\":\"sync\"}"), outbox)
  val sent = rec.all()
  assertEqualInt(sent.count, 2, "render + resync")
  assertTrue(contains(sent[1], "\"op\":\"replace\""), sent[1])
}

test "static pages render their message" {
  val rec = Recorder()
  Host.staticPage("Not found", "There is no page at /x.").start(RecordingOutbox(rec = rec))
  assertTrue(contains(rec.all()[0], "There is no page at /x."), rec.all()[0])
}

test "shell helpers" {
  assertEqual(Web.hostnameOf("example.com:8080"), "example.com", "strip port")
  assertEqual(Web.hostnameOf("example.com"), "example.com", "no port")
  assertEqual(Web.hostnameOf("[::1]:8080"), "[::1]", "ipv6")
  assertEqual(Web.escapeHtml("<a href=\"x\">&'"), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;", "escape")
  val html = Web.shellHtml("Cust <omers>", "ws://h:8081/_ui")
  assertTrue(contains(html, "<title>Cust &lt;omers&gt;</title>"), "escaped title")
  assertTrue(contains(html, "data-ws=\"ws://h:8081/_ui\""), "socket url")
}

test "session socket url follows the page scheme" {
  assertEqual(Web.sessionSocketUrl("", None, "h:8080", 8081, "/_ui"), "ws://h:8081/_ui", "plain http")
  assertEqual(
    Web.sessionSocketUrl("", Some(value = "https"), "h", 8081, "/_ui"),
    "wss://h:8081/_ui",
    "behind tls proxy"
  )
  assertEqual(
    Web.sessionSocketUrl("", Some(value = " HTTPS , http"), "h", 8081, "/_ui"),
    "wss://h:8081/_ui",
    "first of several proxies"
  )
  assertEqual(
    Web.sessionSocketUrl("", Some(value = "http, https"), "h", 8081, "/_ui"),
    "ws://h:8081/_ui",
    "client-facing hop was http"
  )
  assertEqual(
    Web.sessionSocketUrl("wss://app.example.com/_ui", Some(value = "http"), "h", 8081, "/_ui"),
    "wss://app.example.com/_ui",
    "configured url wins"
  )
  val cfg = Web.defaultConfig("t").copy(publicWsUrl = "wss://app.example.com/_ui")
  assertEqual(cfg.publicWsUrl, "wss://app.example.com/_ui", "config override")
  assertEqual(Web.defaultConfig("t").publicWsUrl, "", "derived by default")
}

test "detach then resume re-renders from the kept model" {
  val rec = Recorder()
  val outbox = RecordingOutbox(rec = rec)
  val inst = Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
  inst.start(outbox)
  inst.receive(msg("{\"t\":\"event\",\"v\":1,\"p\":[0,1],\"e\":\"click\"}"), outbox)
  inst.detach({ -> true })
  inst.resume(outbox)
  val sent = rec.all()
  val last = sent[sent.count - 1]
  assertTrue(contains(last, "\"op\":\"replace\""), last)
  assertTrue(contains(last, "saving"), "model kept: " + last)
}

test "detach is skipped when the session was resumed first" {
  val rec = Recorder()
  val outbox = RecordingOutbox(rec = rec)
  val inst = Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
  inst.start(outbox)
  inst.detach({ -> false })
  // The tree is still there, so an event against it is handled.
  inst.receive(msg("{\"t\":\"event\",\"v\":1,\"p\":[0,1],\"e\":\"click\"}"), outbox)
  assertEqualInt(rec.all().count, 2, "render and the click's patch")
}

func dummy(): Instance {
  return Host.instance(program(), stay[Model, Effect](Model(status = "idle")), { _: Effect -> None })
}

test "the session registry resumes within the grace period only" {
  val reg = Host.SessionRegistry()
  assertTrue(reg.admit("s1", dummy(), "c1", 1000, 500, 10), "room")
  assertFalse(reg.isDetached("s1"), "attached")
  match reg.release("c1", 1100) {
    case Some(d) -> assertEqual(d.sessionId, "s1", "released session")
    case None -> assertTrue(false, "expected a release")
  }
  assertTrue(reg.isDetached("s1"), "detached")
  match reg.attach("s1", "c2", 1500, 500) {
    case Host.ResumedSession(_) -> assertTrue(true, "resumed within grace")
    case Host.Unknown -> assertTrue(false, "expected resume")
  }
  assertFalse(reg.isDetached("s1"), "attached again")
  match reg.release("c2", 2000) {
    case Some(_) -> assertTrue(true, "released")
    case None -> assertTrue(false, "expected a release")
  }
  match reg.attach("s1", "c3", 2600, 500) {
    case Host.ResumedSession(_) -> assertTrue(false, "expired")
    case Host.Unknown -> assertTrue(true, "unknown after the grace period")
  }
  assertEqualInt(reg.liveCount(), 0, "expired session removed")
}

test "a close from a superseded connection does not detach the session" {
  val reg = Host.SessionRegistry()
  assertTrue(reg.admit("s1", dummy(), "old", 0, 10_000, 10), "admitted s1")
  // The browser reconnects before the old socket's close arrives.
  match reg.attach("s1", "new", 10, 500) {
    case Host.ResumedSession(_) -> ()
    case Host.Unknown -> assertTrue(false, "expected resume")
  }
  match reg.release("old", 20) {
    case Some(_) -> assertTrue(false, "old connection no longer carries the session")
    case None -> assertTrue(true, "ignored")
  }
  assertFalse(reg.isDetached("s1"), "still attached to the new connection")
  match reg.sessionOf("new") {
    case Some(id) -> assertEqual(id, "s1", "new connection carries it")
    case None -> assertTrue(false, "expected a session")
  }
}

test "the session registry evicts the longest-detached session when full" {
  val reg = Host.SessionRegistry()
  assertTrue(reg.admit("a", dummy(), "ca", 0, 10_000, 10), "admitted a")
  assertTrue(reg.admit("b", dummy(), "cb", 0, 10_000, 10), "admitted b")
  assertTrue(reg.admit("c", dummy(), "cc", 0, 10_000, 10), "admitted c")
  match reg.release("cb", 100) {
    case _ -> ()
  }
  match reg.release("ca", 200) {
    case _ -> ()
  }
  assertTrue(reg.admit("d", dummy(), "cd", 300, 10_000, 3), "room made by eviction")
  assertEqualInt(reg.liveCount(), 3, "one evicted, one added")
  match reg.instanceOf("b") {
    case Some(_) -> assertTrue(false, "b was detached longest")
    case None -> assertTrue(true, "b evicted")
  }
  match reg.instanceOf("a") {
    case Some(_) -> assertTrue(true, "a kept")
    case None -> assertTrue(false, "a should be kept")
  }
}

test "a full registry of connected sessions admits no more" {
  val reg = Host.SessionRegistry()
  assertTrue(reg.admit("a", dummy(), "ca", 0, 10_000, 10), "admitted a")
  assertTrue(reg.admit("b", dummy(), "cb", 0, 10_000, 10), "admitted b")
  assertFalse(reg.admit("c", dummy(), "cc", 10, 10_000, 2), "every session is connected")
  assertEqualInt(reg.liveCount(), 2, "nothing evicted or added")
}
