//! tests/session_tests.l — Ui.Session: the pure session loop driven through
//! host events, including effects, host commands and the confirm dialog.
@test_module
package Ui.SessionTests

import Std.Core
import Std.Testing
import Ui.Core.{View, Step, UiEffect, Navigate, Confirm, Notify, ToastLevel, stay, step1}
import Ui.Widgets.{button, column, field, heading, inputOpts, keyed, row, text, textInput}
import Ui.Diff.{Patch, Replace, SetText, SetProp}
import Ui.Protocol
import Ui.Protocol.{Event, NodeRef, At, Keyed, echoVersionAt, pathKey}
import Ui.Session
import Ui.Session.{Program, Output, HostCommand, NavigateTo, ShowToast, InputVersion}

record Model {
  count: Int
  name: String
}

union Msg {
  case Increment
  case NameTyped(s: String)
  case ResetClicked
  case ResetConfirmed
  case SaveClicked
  case Saved(ok: Bool)
}

union Effect {
  case Persist(count: Int)
  case Ui(effect: UiEffect[Msg])
}

func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Increment -> stay[Model, Effect](Model(count = m.count + 1, name = m.name))
    case NameTyped(s) -> stay[Model, Effect](Model(count = m.count, name = s))
    case ResetClicked -> step1(m, Ui(effect = Confirm(question = "Reset the counter?", onYes = ResetConfirmed)))
    case ResetConfirmed -> stay[Model, Effect](Model(count = 0, name = m.name))
    case SaveClicked -> step1(m, Persist(count = m.count))
    case Saved(ok) -> if ok then step1(m, Ui(effect = Notify(message = "Saved", level = ToastLevel.Success))) else step1(m, Ui(effect = Navigate(url = "/error")))
  }
}

func view(m: in Model): View[Msg] {
  val cs: List[View[Msg]] = newList()
  cs.add(heading[Msg](1, "Count " + m.count.toString()))
  cs.add(field[Msg]("Name", newList(), textInput[Msg]("text", m.name, { s: String -> NameTyped(s = s) }, inputOpts())))
  cs.add(button[Msg]("Add", Increment))
  cs.add(button[Msg]("Reset", ResetClicked))
  cs.add(button[Msg]("Save", SaveClicked))
  return column[Msg](cs)
}

func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  return match e { case Ui(u) -> Some(value = u); case _ -> None }
}

func program(): Program[Model, Msg, Effect] {
  return Program(update = update, view = view, uiEffect = uiEffect)
}

func path(xs: in slice[Int]): List[NodeRef] {
  val acc: List[NodeRef] = newList()
  for x in xs {
    acc.add(At(index = x))
  }
  return acc
}

func ints(xs: in slice[Int]): List[Int] {
  val acc: List[Int] = newList()
  for x in xs {
    acc.add(x)
  }
  return acc
}

func versionOf(ivs: in List[InputVersion], key: in String): Int {
  for iv in ivs {
    if iv.key == key {
      return iv.version
    }
  }
  return 0
}

func click(o: in Output[Model, Msg, Effect], p: in List[NodeRef]): Output[Model, Msg, Effect] {
  val ev = Event(renderVersion = o.session.version, path = p, name = "click", data = "", inputVersion = 0)
  return Session.handleEvent(program(), o.session, ev)
}

// Root is column[app, overlay]; app is column[heading, field, add, reset, save].
func appChild(i: in Int): List[NodeRef] {
  return path([0, i])
}

func started(): Output[Model, Msg, Effect] {
  return Session.start(program(), stay[Model, Effect](Model(count = 0, name = "")))
}

test "start renders the whole tree" {
  val o: Output[Model, Msg, Effect] = started()
  assertEqualInt(o.patches.count, 1, "one patch")
  match o.patches[0] {
    case Replace(p, _) -> assertEqualInt(p.count, 0, "root replace")
    case _ -> assertTrue(false, "expected Replace")
  }
  assertEqualInt(o.session.version, 1, "version 1")
}

test "a click dispatches the handler's message and patches only the change" {
  val o: Output[Model, Msg, Effect] = click(started(), appChild(2))
  assertTrue(o.session.model.count == 1, "count incremented")
  assertEqualInt(o.patches.count, 1, "one patch")
  match o.patches[0] {
    case SetText(_, v) -> assertEqual(v, "Count 1", "heading text")
    case _ -> assertTrue(false, "expected SetText")
  }
  assertEqualInt(o.session.version, 2, "version bumped")
}

test "an input event records its input version" {
  val inputPath = path([0, 1, 0])
  val ev = Event(renderVersion = 1, path = inputPath, name = "input", data = "Acme", inputVersion = 3)
  val o: Output[Model, Msg, Effect] = Session.handleEvent(program(), started().session, ev)
  assertEqual(o.session.model.name, "Acme", "model updated")
  assertEqualInt(versionOf(o.session.inputVersions, Protocol.refsKey(inputPath)), 3, "input version recorded")
}

test "an event on a missing path is dropped" {
  val o: Output[Model, Msg, Effect] = click(started(), appChild(9))
  assertTrue(o.dropped, "dropped")
  assertEqualInt(o.patches.count, 0, "no patches")
}

test "an event with no matching handler is dropped" {
  val ev = Event(renderVersion = 1, path = appChild(0), name = "click", data = "", inputVersion = 0)
  assertTrue(Session.handleEvent(program(), started().session, ev).dropped, "heading has no click handler")
}

test "application effects are returned to the driver" {
  val o: Output[Model, Msg, Effect] = click(click(started(), appChild(2)), appChild(4))
  assertEqualInt(o.effects.count, 1, "one effect")
  match o.effects[0] {
    case Persist(n) -> assertEqualInt(n, 1, "persist count")
    case _ -> assertTrue(false, "expected Persist")
  }
}

test "ui effects become host commands" {
  val ok: Output[Model, Msg, Effect] = Session.dispatch(program(), started().session, Saved(ok = true))
  assertEqualInt(ok.effects.count, 0, "no app effects")
  match ok.commands[0] {
    case ShowToast(m, level) -> {
      assertEqual(m, "Saved", "toast text")
      assertEqual(level, "success", "toast level")
    }
    case _ -> assertTrue(false, "expected ShowToast")
  }
  val bad: Output[Model, Msg, Effect] = Session.dispatch(program(), started().session, Saved(ok = false))
  match bad.commands[0] {
    case NavigateTo(url) -> assertEqual(url, "/error", "navigate url")
    case _ -> assertTrue(false, "expected NavigateTo")
  }
}

test "confirm shows a dialog; OK dispatches the confirmed message" {
  val two: Output[Model, Msg, Effect] = click(click(started(), appChild(2)), appChild(2))
  val asked: Output[Model, Msg, Effect] = click(two, appChild(3))
  assertTrue(asked.session.model.count == 2, "count unchanged while asking")
  match asked.session.dialog {
    case Some(d) -> assertEqual(d.question, "Reset the counter?", "question")
    case None -> assertTrue(false, "expected a dialog")
  }
  // Overlay is root child 1: dialog[text, row[cancel, ok]].
  val answered: Output[Model, Msg, Effect] = click(asked, path([1, 1, 1]))
  assertTrue(answered.session.model.count == 0, "reset")
  match answered.session.dialog {
    case Some(_) -> assertTrue(false, "dialog closed")
    case None -> assertTrue(true, "dialog closed")
  }
}

test "confirm Cancel closes the dialog without dispatching" {
  val asked: Output[Model, Msg, Effect] = click(click(started(), appChild(2)), appChild(3))
  val cancelled: Output[Model, Msg, Effect] = click(asked, path([1, 1, 0]))
  assertTrue(cancelled.session.model.count == 1, "count kept")
  match cancelled.session.dialog {
    case Some(_) -> assertTrue(false, "dialog closed")
    case None -> assertTrue(true, "dialog closed")
  }
  assertTrue(cancelled.patches.count > 0, "overlay removed")
}

test "resync replaces the whole tree" {
  val o: Output[Model, Msg, Effect] = click(started(), appChild(2))
  val ps = Session.resync(o.session)
  assertEqualInt(ps.count, 1, "one patch")
}

test "a value patch after typing carries the input's version" {
  val inputPath = path([0, 1, 0])
  val typed = Event(renderVersion = 1, path = inputPath, name = "input", data = "Acme", inputVersion = 3)
  val o1: Output[Model, Msg, Effect] = Session.handleEvent(program(), started().session, typed)
  // The model now says "Acme"; the value patch echoing it carries iv 3.
  val clear: Output[Model, Msg, Effect] = Session.dispatch(program(), o1.session, NameTyped(s = "Acme Pty"))
  assertEqualInt(clear.patches.count, 1, "one value patch")
  assertEqualInt(echoVersionAt(clear.echoes, ints([0, 1, 0])), 3, "echo version")
}

test "detach drops the tree and resume renders it again" {
  val o: Output[Model, Msg, Effect] = click(started(), appChild(2))
  val d = Session.detach(o.session)
  assertTrue(d.model.count == 1, "model kept")
  assertEqualInt(Session.resync(d).count, 1, "resync of a detached session is one patch")
  val r: Output[Model, Msg, Effect] = Session.resume(program(), d)
  assertEqualInt(r.patches.count, 1, "full render")
  match r.patches[0] {
    case Replace(p, _) -> assertEqualInt(p.count, 0, "root replace")
    case _ -> assertTrue(false, "expected Replace")
  }
  assertEqualInt(r.session.version, o.session.version + 1, "new render version")
  assertEqualInt(r.effects.count, 0, "resuming runs no effects")
  // The resumed tree handles events as before.
  assertTrue(click(r, appChild(2)).session.model.count == 2, "clicks work after resume")
}

// ─── Keyed rows (D138, Q-UI-005) ──────────────────────────────────────────────
record Rows {
  names: List[String]
  deleted: String
}

union RowMsg {
  case Delete(name: String)
  case Remove(name: String)
  case Rename(name: String, to: String)
}

union RowEffect {
  case NoRowEffect
}

func removed(names: in List[String], name: in String): List[String] {
  val acc: List[String] = newList()
  for n in names {
    if n != name {
      acc.add(n)
    }
  }
  return acc
}

func updateRows(m: in Rows, msg: in RowMsg): Step[Rows, RowEffect] {
  return match msg {
    case Delete(n) -> stay[Rows, RowEffect](Rows(names = removed(m.names, n), deleted = n))
    case Remove(n) -> stay[Rows, RowEffect](Rows(names = removed(m.names, n), deleted = m.deleted))
    case Rename(_, _) -> stay[Rows, RowEffect](m)
  }
}

// app = column[row(key=name)[text, button Delete, input]...]
func viewRows(m: in Rows): View[RowMsg] {
  val cs: List[View[RowMsg]] = newList()
  for n in m.names {
    val name = n
    val parts: List[View[RowMsg]] = newList()
    parts.add(text[RowMsg](name))
    parts.add(button[RowMsg]("Delete", Delete(name = name)))
    parts.add(textInput[RowMsg]("text", name, { s: String -> Rename(name = name, to = s) }, inputOpts()))
    cs.add(keyed[RowMsg](name, row[RowMsg](parts)))
  }
  return column[RowMsg](cs)
}

func noUiEffect(e: in RowEffect): Option[UiEffect[RowMsg]] {
  return None
}

func rowsProgram(): Program[Rows, RowMsg, RowEffect] {
  return Program(update = updateRows, view = viewRows, uiEffect = noUiEffect)
}

func threeRows(): Output[Rows, RowMsg, RowEffect] {
  val names: List[String] = newList()
  names.add("ann")
  names.add("bob")
  names.add("cat")
  return Session.start(rowsProgram(), stay[Rows, RowEffect](Rows(names = names, deleted = "")))
}

func rowRef(key: in String, child: in Int): List[NodeRef] {
  val acc: List[NodeRef] = newList()
  acc.add(At(index = 0))
  acc.add(Keyed(key = key))
  acc.add(At(index = child))
  return acc
}

test "a keyed event reaches its row after an earlier row is removed" {
  // The host renders three rows; before its click on cat's Delete arrives,
  // the session removes ann (cat moves from index 2 to 1).
  val o = threeRows()
  val shifted: Output[Rows, RowMsg, RowEffect] = Session.dispatch(rowsProgram(), o.session, Remove(name = "ann"))
  val ev = Event(
    renderVersion = o.session.version,
    path = rowRef("cat", 1),
    name = "click",
    data = "",
    inputVersion = 0
  )
  val after: Output[Rows, RowMsg, RowEffect] = Session.handleEvent(rowsProgram(), shifted.session, ev)
  assertFalse(after.dropped, "delivered")
  assertEqual(after.session.model.deleted, "cat", "the row the user clicked")
}

test "a keyed event for a row that is gone is dropped, not misrouted" {
  val o = threeRows()
  val gone: Output[Rows, RowMsg, RowEffect] = Session.dispatch(rowsProgram(), o.session, Remove(name = "bob"))
  val ev = Event(
    renderVersion = o.session.version,
    path = rowRef("bob", 1),
    name = "click",
    data = "",
    inputVersion = 0
  )
  val after: Output[Rows, RowMsg, RowEffect] = Session.handleEvent(rowsProgram(), gone.session, ev)
  assertTrue(after.dropped, "dropped")
  assertEqual(after.session.model.deleted, "", "nothing deleted")
}

test "a key shared by two siblings does not resolve" {
  val names: List[String] = newList()
  names.add("dup")
  names.add("dup")
  val o = Session.start(rowsProgram(), stay[Rows, RowEffect](Rows(names = names, deleted = "")))
  val ev = Event(renderVersion = 1, path = rowRef("dup", 1), name = "click", data = "", inputVersion = 0)
  assertTrue(Session.handleEvent(rowsProgram(), o.session, ev).dropped, "ambiguous key dropped")
}

test "input versions follow a moved row and are pruned with a removed one" {
  val o = threeRows()
  val typed = Event(renderVersion = 1, path = rowRef("cat", 2), name = "input", data = "cat", inputVersion = 4)
  val o1: Output[Rows, RowMsg, RowEffect] = Session.handleEvent(rowsProgram(), o.session, typed)
  val moved: Output[Rows, RowMsg, RowEffect] = Session.dispatch(rowsProgram(), o1.session, Remove(name = "ann"))
  assertEqualInt(versionOf(moved.session.inputVersions, Protocol.refsKey(rowRef("cat", 2))), 4, "kept across the move")
  val gone: Output[Rows, RowMsg, RowEffect] = Session.dispatch(rowsProgram(), moved.session, Remove(name = "cat"))
  assertEqualInt(gone.session.inputVersions.count, 0, "pruned with its row")
}
