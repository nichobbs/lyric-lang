@test_module
package Ui.Native.ClientTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, Patch, Replace, Insert, Remove, Move, SetProp, RemoveProp, SetText, SetEvents}
import Ui.Protocol.{NodeRef, At, Keyed, encodePatches, encodeToast, encodeNavigate, encodeBack, ValueEcho}
import Ui.Native.Client

func ints(a: Int, b: Int, c: Int): List[Int] {
  val xs: List[Int] = newList()
  xs.add(a)
  if b >= 0 {
    xs.add(b)
  }
  if c >= 0 {
    xs.add(c)
  }
  xs
}

func one(n: WireNode): List[WireNode] {
  val xs: List[WireNode] = newList()
  xs.add(n)
  xs
}

func names(a: String, b: String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs.add(b)
  xs
}

func patches1(p: Patch): List[Patch] {
  val xs: List[Patch] = newList()
  xs.add(p)
  xs
}

func patches2(p: Patch, q: Patch): List[Patch] {
  val xs: List[Patch] = newList()
  xs.add(p)
  xs.add(q)
  xs
}

union Msg {
  case Typed(s: String)
  case Clicked
}

func el(kind: String, key: String, props: List[Prop], events: List[String], children: List[WireNode]): WireNode {
  WElement(kind = kind, key = key, props = props, events = events, children = children)
}

func textOf(s: String): WireNode {
  WText(value = s)
}

func propsOf(name: String, value: String): List[Prop] {
  val ps: List[Prop] = newList()
  ps.add(Prop(name = name, value = value))
  ps
}

// column[heading, input, button, column[row0 .. rowN]] with keyed rows, built by hand.
func screenWire(name: String, count: Int): WireNode {
  val rows: List[WireNode] = newList()
  var i = 0
  while i < count {
    rows.add(el("paragraph", "r" + i.toString(), newList(), newList(), one(textOf("row " + i.toString()))))
    i = i + 1
  }
  val body: List[WireNode] = newList()
  body.add(el("heading", "", propsOf("level", "1"), newList(), one(textOf("Hello " + name))))
  body.add(el("textInput", "", propsOf("value", name), names("input", "change"), newList()))
  body.add(el("button", "", propsOf("label", "Go"), names("click", "click"), newList()))
  body.add(el("column", "", newList(), newList(), rows))
  el("column", "", newList(), newList(), body)
}

func decodePatch(text: String): Client.ServerMessage {
  match Client.decodeServer(text) {
    case Ok(m) -> m
    case Err(e) -> {
      assertTrue(false, e)
      Client.BackMsg
    }
  }
}

func opsOf(m: Client.ServerMessage): List[Client.Op] {
  match m {
    case Client.PatchMsg(_, ops) -> ops
    case _ -> {
      assertTrue(false, "not a patch message")
      newList()
    }
  }
}

func one2patch(n: WireNode): List[Patch] {
  val xs: List[Patch] = newList()
  xs.add(Replace(path = newList(), node = n))
  xs
}

func roundTrip(tree: WireNode, patches: List[Patch]): WireNode {
  val none: List[ValueEcho] = newList()
  Client.applyServer(tree, opsOf(decodePatch(encodePatches(1, patches, none))), { p: List[Int] -> 0 })
}

test "every patch kind survives the wire and means what the reference applier says" {
  val none: List[ValueEcho] = newList()
  val first = screenWire("a", 3)
  var mirror = roundTrip(WEmpty, one2patch(first))
  assertTrue(first == mirror, "replace the whole tree")

  val steps: List[List[Patch]] = newList()
  val inserted = WElement(
    kind = "paragraph",
    key = "r9",
    props = newList(),
    events = newList(),
    children = one(WText(value = "new"))
  )
  steps.add(patches1(Insert(path = ints(3, -1, -1), index = 1, node = inserted)))
  steps.add(patches1(Move(path = ints(3, -1, -1), from = 0, to = 2)))
  steps.add(patches1(Remove(path = ints(3, -1, -1), index = 1)))
  steps.add(
    patches2(
      SetProp(path = ints(1, -1, -1), name = "value", value = "typed"),
      SetText(path = ints(0, 0, -1), value = "Hello z")
    )
  )
  steps.add(
    patches2(
      RemoveProp(path = ints(1, -1, -1), name = "value"),
      SetEvents(path = ints(2, -1, -1), events = names("click", "submit"))
    )
  )
  steps.add(patches1(Replace(path = ints(3, 0, -1), node = WText(value = "swapped"))))
  var expected = first
  for patches in steps {
    expected = Ui.Diff.applyPatches(expected, patches)
    mirror = roundTrip(mirror, patches)
    assertTrue(expected == mirror, "after a step")
  }
}

test "a stale value echo is dropped, a current one applied" {
  val none: List[ValueEcho] = newList()
  val first = screenWire("a", 0)
  val mirror = roundTrip(WEmpty, one2patch(first))
  val echoes: List[ValueEcho] = newList()
  val text = encodePatches(2, one2patch(first), echoes)
  // The patch carries no iv here; a patch with iv 3 against a local edit 5 must be skipped.
  val withIv = Client.Op(
    patch = Ui.Diff.SetProp(path = ints(1, -1, -1), name = "value", value = "stale"),
    inputVersion = 3
  )
  val ops: List[Client.Op] = newList()
  ops.add(withIv)
  val kept = Client.applyServer(mirror, ops, { p: List[Int] -> 5 })
  assertTrue(kept == mirror, "stale echo skipped")
  val applied = Client.applyServer(mirror, ops, { p: List[Int] -> 3 })
  assertTrue(applied != mirror, "current echo applied")
  assertTrue(text.length > 0, "encoded")
}

test "navigation, back and toast messages decode" {
  match decodePatch(encodeNavigate("/customers/7")) {
    case Client.NavigateMsg(url) -> assertEqual(url, "/customers/7", "url")
    case _ -> assertTrue(false, "navigate")
  }
  match decodePatch(encodeBack()) {
    case Client.BackMsg -> ()
    case _ -> assertTrue(false, "back")
  }
  match decodePatch(encodeToast("Saved", "success")) {
    case Client.ToastMsg(m, level) -> {
      assertEqual(m, "Saved", "message")
      assertEqual(level, "success", "level")
    }
    case _ -> assertTrue(false, "toast")
  }
}

test "malformed messages are errors" {
  match Client.decodeServer("{") {
    case Ok(_) -> assertTrue(false, "should fail")
    case Err(_) -> ()
  }
  match Client.decodeServer("{\"t\":\"nope\"}") {
    case Ok(_) -> assertTrue(false, "should fail")
    case Err(e) -> assertTrue(e.length > 0, "names the type")
  }
  match Client.decodeServer("{\"t\":\"patch\",\"v\":1,\"ops\":[{\"op\":\"remove\",\"p\":[0]}]}") {
    case Ok(_) -> assertTrue(false, "remove without an index")
    case Err(_) -> ()
  }
}

test "event paths use keys where nodes have them" {
  val tree = screenWire("a", 3)
  val path = ints(3, 1, -1)
  val refs = Client.eventPath(tree, path)
  assertEqualInt(refs.count, 2, "steps")
  match refs[0] {
    case At(i) -> assertEqualInt(i, 3, "column")
    case Keyed(_) -> assertTrue(false, "unkeyed")
  }
  match refs[1] {
    case Keyed(k) -> assertEqual(k, "r1", "keyed row")
    case At(_) -> assertTrue(false, "keyed")
  }
}

test "nodeAt resolves paths and rejects bad ones" {
  val tree = screenWire("a", 1)
  assertTrue(Client.nodeAt(tree, ints(0, -1, -1)).isSome(), "heading")
  assertTrue(Client.nodeAt(tree, ints(9, -1, -1)).isNone(), "acc of range")
  assertTrue(Client.nodeAt(tree, newList()).isSome(), "root")
}
