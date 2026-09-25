//! tests/session_tests.l — Ui.Session: the pure session loop driven through
//! host events, including effects, host commands and the confirm dialog.
@test_module
package Ui.SessionTests

import Std.Core
import Std.Testing
import Ui.Core.{View, Step, UiEffect, Navigate, Confirm, Notify, ToastLevel, stay, step1}
import Ui.Widgets.{button, column, field, heading, inputOpts, textInput}
import Ui.Diff.{Patch, Replace, SetText, SetProp}
import Ui.Protocol.{Event, inputVersionAt}
import Ui.Session
import Ui.Session.{Program, Output, HostCommand, NavigateTo, ShowToast}

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

func path(xs: in slice[Int]): List[Int] {
  val acc: List[Int] = newList()
  for x in xs {
    acc.add(x)
  }
  return acc
}

func click(o: in Output[Model, Msg, Effect], p: in List[Int]): Output[Model, Msg, Effect] {
  val ev = Event(renderVersion = o.session.version, path = p, name = "click", data = "", inputVersion = 0)
  return Session.handleEvent(program(), o.session, ev)
}

// Root is column[app, overlay]; app is column[heading, field, add, reset, save].
func appChild(i: in Int): List[Int] {
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
  assertEqualInt(inputVersionAt(o.session.inputVersions, inputPath), 3, "input version recorded")
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
