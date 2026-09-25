//! tests/diff_tests.l — Ui.Diff: patch generation checked against the
//! reference applier (apply(toWire(a), diff(a, b)) must equal toWire(b)).
@test_module
package Ui.DiffTests

import Std.Core
import Std.Testing
import Ui.Core.{View, Prop}
import Ui.Widgets.{button, column, heading, inputOpts, keyed, paragraph, primaryButton, spinner, textInput}
import Ui.Diff
import Ui.Diff.{WireNode, WElement, WText, WEmpty, Patch, diff, applyPatches, toWire}

union Msg {
  case Clicked(id: Int)
  case Typed(s: String)
}

// Structural equality of wire nodes, ignoring property order (a host keeps
// properties as a map).
func wireEq(a: in WireNode, b: in WireNode): Bool {
  return match a {
    case WText(x) -> match b { case WText(y) -> x == y; case _ -> false }
    case WEmpty -> match b { case WEmpty -> true; case _ -> false }
    case WElement(k1, key1, p1, e1, c1) -> match b {
      case WElement(k2, key2, p2, e2, c2) -> k1 == k2 and key1 == key2 and
        propsEq(p1, p2) and
        stringsEq(e1, e2) and
        childrenEq(c1, c2)
      case _ -> false
    }
  }
}

func propsEq(a: in List[Prop], b: in List[Prop]): Bool {
  if a.count != b.count {
    return false
  }
  for p in a {
    var found = false
    for q in b {
      if q.name == p.name and q.value == p.value {
        found = true
      }
    }
    if not found {
      return false
    }
  }
  return true
}

func stringsEq(a: in List[String], b: in List[String]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  return true
}

func childrenEq(a: in List[WireNode], b: in List[WireNode]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if not wireEq(a[i], b[i]) {
      return false
    }
    i = i + 1
  }
  return true
}

// Diffs a -> b, checks the round trip, and returns the patch count.
func roundTrip(a: in View[Msg], b: in View[Msg], what: in String): Int {
  val patches: List[Patch] = diff(a, b)
  val applied = applyPatches(toWire(a), patches)
  assertTrue(wireEq(applied, toWire(b)), what + ": applied patches reproduce the new tree")
  return patches.count
}

func items(keys: in List[String]): View[Msg] {
  val cs: List[View[Msg]] = newList()
  for k in keys {
    val p: View[Msg] = paragraph[Msg](k)
    cs.add(keyed(k, p))
  }
  return column[Msg](cs)
}

func strs(a: in String, b: in String, c: in String, d: in String): List[String] {
  val acc: List[String] = newList()
  for s in [a, b, c, d] {
    if s.length > 0 {
      acc.add(s)
    }
  }
  return acc
}

func btn(label: in String, id: in Int): View[Msg] {
  return button[Msg](label, Clicked(id = id))
}

func col2(a: in View[Msg], b: in View[Msg]): View[Msg] {
  val cs: List[View[Msg]] = newList()
  cs.add(a)
  cs.add(b)
  return column[Msg](cs)
}

test "identical trees produce no patches" {
  val v = col2(heading[Msg](1, "Customers"), btn("Save", 1))
  assertEqualInt(roundTrip(v, v, "identical"), 0, "no patches")
}

test "changed text produces a single SetText" {
  val a = col2(heading[Msg](1, "Customers"), btn("Save", 1))
  val b = col2(heading[Msg](1, "Suppliers"), btn("Save", 1))
  assertEqualInt(roundTrip(a, b, "text"), 1, "one patch")
}

test "changed and removed props produce SetProp and RemoveProp" {
  val a = primaryButton[Msg]("Save", Clicked(id = 1), true)
  val b = primaryButton[Msg]("Store", Clicked(id = 1), false)
  // label changes, busy is removed, and the click handler returns.
  assertEqualInt(roundTrip(a, b, "props"), 3, "SetProp + RemoveProp + SetEvents")
}

test "different widget kinds are replaced" {
  val a = col2(paragraph[Msg]("x"), btn("Go", 1))
  val b = col2(spinner[Msg]("Loading"), btn("Go", 1))
  assertEqualInt(roundTrip(a, b, "replace"), 1, "one Replace")
}

test "positional children: append and truncate" {
  val one: List[View[Msg]] = newList()
  one.add(paragraph[Msg]("a"))
  val three: List[View[Msg]] = newList()
  three.add(paragraph[Msg]("a"))
  three.add(paragraph[Msg]("b"))
  three.add(paragraph[Msg]("c"))
  assertEqualInt(roundTrip(column[Msg](one), column[Msg](three), "append"), 2, "two inserts")
  assertEqualInt(roundTrip(column[Msg](three), column[Msg](one), "truncate"), 2, "two removes")
}

test "keyed children: reorder uses moves, not rewrites" {
  val a = items(strs("a", "b", "c", "d"))
  val b = items(strs("d", "a", "b", "c"))
  assertEqualInt(roundTrip(a, b, "rotate"), 1, "one move")
}

test "keyed children: insert and remove in the middle" {
  val a = items(strs("a", "b", "c", ""))
  val b = items(strs("a", "x", "c", ""))
  assertEqualInt(roundTrip(a, b, "swap middle"), 2, "remove b + insert x")
}

test "keyed children: reverse" {
  assertTrue(roundTrip(items(strs("a", "b", "c", "d")), items(strs("d", "c", "b", "a")), "reverse") >= 0, "round trip")
}

test "keyed children: clear and refill" {
  assertTrue(roundTrip(items(strs("a", "b", "", "")), items(strs("", "", "", "")), "clear") >= 0, "round trip")
  assertTrue(roundTrip(items(strs("", "", "", "")), items(strs("c", "d", "", "")), "refill") >= 0, "round trip")
}

test "duplicate keys fall back to positional reconciliation" {
  val cs: List[View[Msg]] = newList()
  val pa: View[Msg] = paragraph[Msg]("a")
  val pb: View[Msg] = paragraph[Msg]("b")
  cs.add(keyed("k", pa))
  cs.add(keyed("k", pb))
  val a = column[Msg](cs)
  assertTrue(roundTrip(a, items(strs("k", "", "", "")), "duplicate keys") >= 0, "round trip")
}

test "nested changes patch the deepest node only" {
  val inner1 = col2(paragraph[Msg]("x"), paragraph[Msg]("y"))
  val inner2 = col2(paragraph[Msg]("x"), paragraph[Msg]("z"))
  val a: View[Msg] = col2(heading[Msg](2, "h"), inner1)
  val b: View[Msg] = col2(heading[Msg](2, "h"), inner2)
  val patches: List[Patch] = diff(a, b)
  assertEqualInt(patches.count, 1, "one patch")
  match patches[0] {
    case Diff.SetText(path, v) -> {
      assertEqual(v, "z", "new text")
      assertEqualInt(path.count, 3, "column -> inner column -> paragraph -> text")
    }
    case _ -> assertTrue(false, "expected SetText")
  }
}

test "changed handlers alone do not produce patches" {
  // Same event set, different message: handlers never cross the wire.
  assertEqualInt(roundTrip(btn("Go", 1), btn("Go", 2), "handler message"), 0, "no patches")
}

test "inputs: value changes are SetProp on the input" {
  val a: View[Msg] = textInput[Msg]("text", "Ac", { s: String -> Typed(s = s) }, inputOpts())
  val b: View[Msg] = textInput[Msg]("text", "Acme", { s: String -> Typed(s = s) }, inputOpts())
  val patches: List[Patch] = diff(a, b)
  assertEqualInt(patches.count, 1, "one patch")
  match patches[0] {
    case Diff.SetProp(_, name, value) -> {
      assertEqual(name, "value", "prop name")
      assertEqual(value, "Acme", "prop value")
    }
    case _ -> assertTrue(false, "expected SetProp")
  }
}
