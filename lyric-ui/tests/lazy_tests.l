//! tests/lazy_tests.l — `Lazy` subtrees (docs/65 §13.5, D153): rendered
//! once per fingerprint, skipped by diffing while it is unchanged, and
//! transparent to event paths, the wire tree and `Ui.Testing`.
@test_module
package Ui.LazyTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{View, Step, Empty, stay}
import Ui.Widgets.{button, column, heading, lazyView, text}
import Ui.Diff.{Patch, SetText, Insert, toWire, resolveLazy, diff, WElement}
import Ui.Protocol.{Event, NodeRef, At}
import Ui.Session
import Ui.Session.{Program, Output}
import Ui.Testing as UiTest

record Model {
  count: Int
  items: Int
}

union Msg {
  case Bump
  case More
}

union Effect {
  case NoEffect
}

func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Bump -> stay[Model, Effect](Model(count = m.count + 1, items = m.items))
    case More -> stay[Model, Effect](Model(count = m.count, items = m.items + 1))
  }
}

// The list re-renders only when `items` changes; `renders` counts how
// often it actually renders.
func listView(items: in Int, renders: in List[Int]): View[Msg] {
  renders.add(items)
  val cs: List[View[Msg]] = newList()
  var i = 0
  while i < items {
    cs.add(text[Msg]("Item " + i.toString()))
    i += 1
  }
  cs.add(button[Msg]("More", More))
  return column[Msg](cs)
}

func program(renders: in List[Int]): Program[Model, Msg, Effect] {
  val view = { m: Model ->
    val cs: List[View[Msg]] = newList()
    cs.add(heading[Msg](1, "Count " + m.count.toString()))
    val items = m.items
    cs.add(lazyView[Msg]("list", items.toString(), { -> listView(items, renders) }))
    column[Msg](cs)
  }
  return Program(update = update, view = view, uiEffect = { _: Effect -> None })
}

func at(xs: in slice[Int]): List[NodeRef] {
  val acc: List[NodeRef] = newList()
  for x in xs {
    acc.add(At(index = x))
  }
  return acc
}

func click(
  p: in Program[Model, Msg, Effect], o: in Output[Model, Msg, Effect], path: in slice[Int]
): Output[Model, Msg, Effect] {
  val ev = Event(renderVersion = o.session.version, path = at(path), name = "click", data = "", inputVersion = 0)
  return Session.handleEvent(p, o.session, ev)
}

func started(renders: in List[Int]): Output[Model, Msg, Effect] {
  return Session.start(program(renders), stay[Model, Effect](Model(count = 0, items = 2)))
}

test "a lazy subtree renders once and is skipped while its fingerprint is unchanged" {
  val renders: List[Int] = newList()
  val p = program(renders)
  val o = started(renders)
  assertEqualInt(renders.count, 1, "rendered at start")
  val dispatched = Session.dispatch(p, o.session, Bump)
  assertEqualInt(renders.count, 1, "not rendered again for a change it does not depend on")
  assertEqualInt(dispatched.patches.count, 1, "only the heading changed")
  match dispatched.patches[0] {
    case SetText(_, v) -> assertEqual(v, "Count 1", "heading text")
    case _ -> assertTrue(false, "expected SetText")
  }
}

test "a changed fingerprint renders the subtree again and patches it" {
  val renders: List[Int] = newList()
  val p = program(renders)
  val o = Session.dispatch(p, started(renders).session, More)
  assertEqualInt(renders.count, 2, "rendered again")
  assertEqualInt(renders[1], 3, "with the new input")
  var inserts = 0
  for q in o.patches {
    match q {
      case Insert(_, _, _) -> {
        inserts += 1
      }
      case _ -> ()
    }
  }
  assertEqualInt(inserts, 1, "one item inserted")
}

test "events reach handlers inside a memoised subtree" {
  val renders: List[Int] = newList()
  val p = program(renders)
  // Session root column > app column > lazy list (index 1) > More button
  // (after the two items, index 2).
  val o = click(p, started(renders), [0, 1, 2])
  assertFalse(o.dropped, "the click was handled")
  assertEqualInt(o.session.model.items, 3, "More ran")
}

test "lazy and memo nodes are transparent on the wire and to Ui.Testing" {
  val renders: List[Int] = newList()
  val v: View[Msg] = lazyView[Msg]("k", "1", { -> listView(1, renders) })
  val nothing: View[Msg] = Empty
  val resolved = resolveLazy(v, nothing)
  match toWire(resolved) {
    case WElement(kind, _, _, _, children) -> {
      assertEqual(kind, "column", "the subtree's own element")
      assertEqualInt(children.count, 2, "item and button")
    }
    case _ -> assertTrue(false, "expected an element")
  }
  assertTrue(UiTest.hasText(resolved, "Item 0"), "text found through the memo")
  assertEqualInt(diff(resolved, resolveLazy(v, resolved)).count, 0, "same fingerprint: no patches")
  assertEqualInt(renders.count, 1, "rendered once across both resolutions")
}
