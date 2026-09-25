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
