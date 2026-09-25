//! Ui.Diff — compares two `View` trees and produces the patch list a host
//! applies to move from the first to the second (docs/65-ui-library-sketch.md §9).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! Paths are child-index lists from the root.  Patches are ordered so that a
//! host applying them one after another always sees valid indices:
//!
//!   - within one element, removals come first (highest index down), then
//!     moves and inserts left to right, then recursion into each child;
//!   - a child's own patches use its final index.
//!
//! Children are reconciled by key when every child in both lists has a
//! non-empty, unique key; otherwise by position.
@runtime_checked
package Ui.Diff

import Std.Core
import Ui.Core.{View, Element, Text, Empty, Handler, Prop, WidgetKind, kindName, eventName, lookupProp}

// ─── Wire nodes ───────────────────────────────────────────────────────────────
/// The handler-free projection of a `View`: what a host needs to render a
/// node.  Handlers are listed by event name only.
pub union WireNode {
  case WElement(kind: String, key: String, props: List[Prop], events: List[String], children: List[WireNode])
  case WText(value: String)
  case WEmpty
}

/// The wire projection of `v`.
pub func toWire[Msg](v: in View[Msg]): WireNode {
  return match v {
    case Element(kind, key, props, handlers, children) -> {
      val cs: List[WireNode] = newList()
      for c in children {
        cs.add(toWire(c))
      }
      WElement(kind = kindName(kind), key = key, props = props, events = eventsOf(handlers), children = cs)
    }
    case Text(s) -> WText(value = s)
    case Empty -> WEmpty
  }
}

/// The distinct event names of `hs`, in first-occurrence order.
pub func eventsOf[Msg](hs: in List[Handler[Msg]]): List[String] {
  val acc: List[String] = newList()
  for h in hs {
    val n = eventName(h)
    if not containsString(acc, n) {
      acc.add(n)
    }
  }
  return acc
}

// ─── Patches ──────────────────────────────────────────────────────────────────
/// One edit to the host's tree.
pub union Patch {
  case Replace(path: List[Int], node: WireNode)
  case Insert(path: List[Int], index: Int, node: WireNode)
  case Remove(path: List[Int], index: Int)
  case Move(path: List[Int], from: Int, to: Int)
  case SetProp(path: List[Int], name: String, value: String)
  case RemoveProp(path: List[Int], name: String)
  case SetText(path: List[Int], value: String)
  case SetEvents(path: List[Int], events: List[String])
}

/// The patches that turn `old` into `new`.  An empty result means the two
/// trees render identically.
pub func diff[Msg](before: in View[Msg], after: in View[Msg]): List[Patch] {
  val acc: List[Patch] = newList()
  val root: List[Int] = newList()
  diffNode(before, after, root, acc)
  return acc
}

/// A single-patch list replacing the whole tree with `v` (initial render and
/// resynchronisation after a reconnect).
pub func replaceAll[Msg](v: in View[Msg]): List[Patch] {
  val acc: List[Patch] = newList()
  val root: List[Int] = newList()
  acc.add(Replace(path = root, node = toWire(v)))
  return acc
}

pub func diffNode[Msg](before: in View[Msg], after: in View[Msg], path: in List[Int], acc: in List[Patch]): Unit {
  match before {
    case Text(a) -> match after {
      case Text(b) -> if a != b { acc.add(SetText(path = path, value = b)) }
      case _ -> acc.add(Replace(path = path, node = toWire(after)))
    }
    case Empty -> match after { case Empty -> (); case _ -> acc.add(Replace(path = path, node = toWire(after))) }
    case Element(k1, key1, props1, hs1, cs1) -> match after {
      case Element(k2, key2, props2, hs2, cs2) -> if kindName(k1) == kindName(k2) and key1 == key2 {
        diffProps(props1, props2, path, acc)
        val e1 = eventsOf(hs1)
        val e2 = eventsOf(hs2)
        if not sameStrings(e1, e2) {
          acc.add(SetEvents(path = path, events = e2))
        }
        diffChildren(cs1, cs2, path, acc)
      } else {
        acc.add(Replace(path = path, node = toWire(after)))
      }
      case _ -> acc.add(Replace(path = path, node = toWire(after)))
    }
  }
}

pub func diffProps(before: in List[Prop], after: in List[Prop], path: in List[Int], acc: in List[Patch]): Unit {
  for p in after {
    match lookupProp(before, p.name) {
      case Some(v) -> if v != p.value { acc.add(SetProp(path = path, name = p.name, value = p.value)) }
      case None -> acc.add(SetProp(path = path, name = p.name, value = p.value))
    }
  }
  for p in before {
    match lookupProp(after, p.name) {
      case Some(_) -> ()
      case None -> acc.add(RemoveProp(path = path, name = p.name))
    }
  }
}

pub func diffChildren[Msg](
  before: in List[View[Msg]],
  after: in List[View[Msg]],
  path: in List[Int],
  acc: in List[Patch],
): Unit {
  if isKeyed(before) and isKeyed(after) {
    diffKeyed(before, after, path, acc)
  } else {
    diffPositional(before, after, path, acc)
  }
}

pub func diffPositional[Msg](
  before: in List[View[Msg]],
  after: in List[View[Msg]],
  path: in List[Int],
  acc: in List[Patch],
): Unit {
  var i = before.count - 1
  while i >= after.count {
    acc.add(Remove(path = path, index = i))
    i = i - 1
  }
  var j = 0
  while j < after.count {
    if j < before.count {
      diffNode(before[j], after[j], childPath(path, j), acc)
    } else {
      acc.add(Insert(path = path, index = j, node = toWire(after[j])))
    }
    j = j + 1
  }
}

pub func diffKeyed[Msg](
  before: in List[View[Msg]], after: in List[View[Msg]], path: in List[Int], acc: in List[Patch]
): Unit {
  val newKeys: List[String] = newList()
  for c in after {
    newKeys.add(keyOf(c))
  }
  // `cur` mirrors the host's child list as patches are emitted.
  var cur: List[View[Msg]] = newList()
  for c in before {
    cur.add(c)
  }
  var i = cur.count - 1
  while i >= 0 {
    if not containsString(newKeys, keyOf(cur[i])) {
      acc.add(Remove(path = path, index = i))
      cur.removeAt(i)
    }
    i = i - 1
  }
  var target = 0
  while target < after.count {
    val want = keyOf(after[target])
    val at = indexOfKey(cur, want, target)
    if at < 0 {
      acc.add(Insert(path = path, index = target, node = toWire(after[target])))
      cur = insertAt(cur, target, after[target])
    } else {
      if at != target {
        acc.add(Move(path = path, from = at, to = target))
        val moved = cur[at]
        cur.removeAt(at)
        cur = insertAt(cur, target, moved)
      }
      diffNode(cur[target], after[target], childPath(path, target), acc)
    }
    target = target + 1
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
/// The key of `v` (empty when `v` is unkeyed or not an element).
pub func keyOf[Msg](v: in View[Msg]): String {
  return match v { case Element(_, key, _, _, _) -> key; case _ -> "" }
}

/// True when every child has a non-empty key and no key repeats.
pub func isKeyed[Msg](cs: in List[View[Msg]]): Bool {
  val seen: List[String] = newList()
  for c in cs {
    val k = keyOf(c)
    if k.length == 0 or containsString(seen, k) {
      return false
    }
    seen.add(k)
  }
  return true
}

pub func indexOfKey[Msg](cs: in List[View[Msg]], key: in String, from: in Int): Int {
  var i = from
  while i < cs.count {
    if keyOf(cs[i]) == key {
      return i
    }
    i = i + 1
  }
  return -1
}

/// `path` extended with child index `i` (a fresh list; `path` is unchanged).
pub func childPath(path: in List[Int], i: in Int): List[Int] {
  val acc: List[Int] = newList()
  for p in path {
    acc.add(p)
  }
  acc.add(i)
  return acc
}

// `List.insert` is not available on every backend (native lowers only
// add/set/removeAt/clear), so insertion rebuilds the list.
pub func insertAt[T](xs: in List[T], index: in Int, x: in T): List[T] {
  val acc: List[T] = newList()
  var i = 0
  while i < xs.count {
    if i == index {
      acc.add(x)
    }
    acc.add(xs[i])
    i = i + 1
  }
  if index >= xs.count {
    acc.add(x)
  }
  return acc
}

pub func containsString(xs: in List[String], x: in String): Bool {
  for s in xs {
    if s == x {
      return true
    }
  }
  return false
}

pub func sameStrings(a: in List[String], b: in List[String]): Bool {
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

// ─── Reference applier ────────────────────────────────────────────────────────
/// Applies `patches` to `root` in order, the way a host must.  This is the
/// executable specification of patch semantics: the diff tests check that
/// `applyPatches(toWire(a), diff(a, b))` equals `toWire(b)`, and a host
/// written in Lyric (the future client WASM host, docs/65 §13.1) can use it
/// directly.  A patch whose path does not resolve leaves the tree unchanged.
pub func applyPatches(root: in WireNode, patches: in List[Patch]): WireNode {
  var cur = root
  for p in patches {
    cur = applyPatch(cur, p)
  }
  return cur
}

pub func applyPatch(root: in WireNode, p: in Patch): WireNode {
  return match p {
    case Replace(path, node) -> updateAt(root, path, 0, { _: WireNode -> node })
    case Insert(path, index, node) -> updateAt(
      root,
      path,
      0,
      { n: WireNode ->
        withChildren(n, insertAt(childrenOfWire(n), index, node))
      }
    )
    case Remove(path, index) -> updateAt(
      root,
      path,
      0,
      { n: WireNode -> withChildren(n, removeAtCopy(childrenOfWire(n), index)) }
    )
    case Move(path, from, to) -> updateAt(
      root,
      path,
      0,
      { n: WireNode -> withChildren(n, moveCopy(childrenOfWire(n), from, to)) }
    )
    case SetProp(path, name, value) -> updateAt(root, path, 0, { n: WireNode -> setPropOf(n, name, value) })
    case RemoveProp(path, name) -> updateAt(root, path, 0, { n: WireNode -> removePropOf(n, name) })
    case SetText(path, value) -> updateAt(root, path, 0, { _: WireNode -> WText(value = value) })
    case SetEvents(path, events) -> updateAt(root, path, 0, { n: WireNode -> setEventsOf(n, events) })
  }
}

pub func updateAt(n: in WireNode, path: in List[Int], depth: in Int, f: in (WireNode) -> WireNode): WireNode {
  if depth == path.count {
    return f(n)
  }
  val cs = childrenOfWire(n)
  val i = path[depth]
  if i < 0 or i >= cs.count {
    return n
  }
  val acc: List[WireNode] = newList()
  var j = 0
  while j < cs.count {
    if j == i {
      acc.add(updateAt(cs[j], path, depth + 1, f))
    } else {
      acc.add(cs[j])
    }
    j = j + 1
  }
  return withChildren(n, acc)
}

/// The children of a wire node (empty for text and empty nodes).
pub func childrenOfWire(n: in WireNode): List[WireNode] {
  return match n { case WElement(_, _, _, _, cs) -> cs; case _ -> { val none: List[WireNode] = newList(); none } }
}

pub func withChildren(n: in WireNode, cs: in List[WireNode]): WireNode {
  return match n {
    case WElement(kind, key, props, events, _) -> WElement(
      kind = kind,
      key = key,
      props = props,
      events = events,
      children = cs
    )
    case _ -> n
  }
}

pub func setPropOf(n: in WireNode, name: in String, value: in String): WireNode {
  return match n {
    case WElement(kind, key, props, events, cs) -> {
      val ps: List[Prop] = newList()
      var replaced = false
      for p in props {
        if p.name == name {
          ps.add(Prop(name = name, value = value))
          replaced = true
        } else {
          ps.add(p)
        }
      }
      if not replaced {
        ps.add(Prop(name = name, value = value))
      }
      WElement(kind = kind, key = key, props = ps, events = events, children = cs)
    }
    case _ -> n
  }
}

pub func removePropOf(n: in WireNode, name: in String): WireNode {
  return match n {
    case WElement(kind, key, props, events, cs) -> {
      val ps: List[Prop] = newList()
      for p in props {
        if p.name != name {
          ps.add(p)
        }
      }
      WElement(kind = kind, key = key, props = ps, events = events, children = cs)
    }
    case _ -> n
  }
}

pub func setEventsOf(n: in WireNode, events: in List[String]): WireNode {
  return match n {
    case WElement(kind, key, props, _, cs) -> WElement(
      kind = kind,
      key = key,
      props = props,
      events = events,
      children = cs
    )
    case _ -> n
  }
}

pub func removeAtCopy[T](xs: in List[T], index: in Int): List[T] {
  val acc: List[T] = newList()
  var i = 0
  while i < xs.count {
    if i != index {
      acc.add(xs[i])
    }
    i = i + 1
  }
  return acc
}

pub func moveCopy[T](xs: in List[T], from: in Int, to: in Int): List[T] {
  if from < 0 or from >= xs.count {
    return xs
  }
  val moved = xs[from]
  return insertAt(removeAtCopy(xs, from), to, moved)
}
