//! plan.l - Access.Plan: what the native host sends a platform accessibility adapter, worked
//! out without one (docs/67 G10, issue #8489).
//!
//! `Ui.Native.Access` builds the accessibility tree of a screen and diffs it against the last
//! one.  AccessKit, which the native host publishes it through, names nodes by 64-bit numbers,
//! keeps the text of an input in child "text run" nodes, and places a text selection by run and
//! character.  This package turns a tree into that shape: it numbers node ids (`Numbering`), splits
//! input values into runs at line breaks with the UTF-8 length of each character, and moves the
//! selection's code point offsets onto runs.  `planTree` gives the whole tree (what the adapter
//! hands over when an assistive technology first connects) and `planUpdate` the nodes an update
//! touches.  `resolveNumber` turns the number in an action request back into the host's id.
//!
//! Nothing here calls AccessKit, so it is tested on every target; `Access.Platform` (the `platform/`
//! project) feeds plans to the C API on `--target native`.
@pure
package Access.Plan

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding.{codepointToString}
import Ui.Native.Access.{AccessTree, AccessNode, AccessUpdate, Role, RoleTextInput, RoleMultilineInput, RoleSpinButton}

// ─── Numbering ────────────────────────────────────────────────────────────────
/// Numbers for node ids.  An id gets the next number the first time it is seen and keeps it
/// while it stays in the tree; an id that leaves the tree loses its number, and a number is never
/// given out twice, so a request that names a node which has since gone resolves to nothing.
/// Numbers start at 1.
pub ref record Numbering {
  var next: Long
  var byId: Map[String, Long]
  var byNumber: Map[Long, String]
}

pub func newNumbering(): Numbering {
  Numbering(next = 1, byId = newMap(), byNumber = newMap())
}

/// The number of `id`, given now if it has none.
pub func numberOf(n: in Numbering, id: in String): Long {
  match mapGet(n.byId, id) {
    case Some(v) -> v
    case None -> {
      val v = n.next
      n.next = n.next + 1
      n.byId.add(id, v)
      n.byNumber.add(v, id)
      v
    }
  }
}

/// The id whose number is `num`, while it is still in the tree.
pub func resolveNumber(n: in Numbering, num: in Long): Option[String] {
  mapGet(n.byNumber, num)
}

/// Forgets the numbers of ids not in `live`.
pub func retainOnly(n: in Numbering, live: in List[String]): Unit {
  val byId: Map[String, Long] = newMap()
  val byNumber: Map[Long, String] = newMap()
  for id in live {
    match mapGet(n.byId, id) {
      case Some(v) -> {
        byId.add(id, v)
        byNumber.add(v, id)
      }
      case None -> ()
    }
  }
  n.byId = byId
  n.byNumber = byNumber
}

// ─── Text runs ────────────────────────────────────────────────────────────────
/// One line of an input's text: its own node, the text (ending with the line break when one
/// follows), and the UTF-8 length of each character.
pub record PlannedRun {
  id: String
  num: Long
  text: String
  lengths: List[Int]
}

/// A text selection as AccessKit places it: run node and character index of each end.
pub record PlannedSelection {
  anchorRun: Long
  anchorIndex: Int
  focusRun: Long
  focusIndex: Int
}

/// The id of the `index`th text run of the input `id`.
pub func runId(id: in String, index: in Int): String {
  id + "#run:" + index.toString()
}

/// UTF-8 bytes of the code point `cp`.
pub func utf8Length(cp: in Int): Int {
  if cp < 128 {
    1
  } else if cp < 2048 {
    2
  } else if cp < 65536 {
    3
  } else {
    4
  }
}

/// Whether a node of this role publishes its value as text runs.  A password input publishes no
/// value at all (`Ui.Native.Access` leaves it empty), so it has no runs either.
pub func hasTextRuns(role: in Role): Bool {
  match role {
    case RoleTextInput -> true
    case RoleMultilineInput -> true
    case RoleSpinButton -> true
    case _ -> false
  }
}

record Line {
  text: String
  lengths: List[Int]
  /// Code point offset of the line's first character in the whole value.
  start: Int
}

func splitLines(value: String): List[Line] {
  val lines: List[Line] = newList()
  var text = StringBuilder.new()
  var lengths: List[Int] = newList()
  var start = 0
  var at = 0
  for cp in codePoints(value) {
    StringBuilder.append(text, codepointToString(cp))
    lengths.add(utf8Length(cp))
    at = at + 1
    if cp == 10 {
      lines.add(Line(text = StringBuilder.toString(text), lengths = lengths, start = start))
      text = StringBuilder.new()
      lengths = newList()
      start = at
    }
  }
  lines.add(Line(text = StringBuilder.toString(text), lengths = lengths, start = start))
  lines
}

/// The runs of an input whose value is `value`: one per line, the last one possibly empty, so an
/// empty value has one empty run and a caret after a final line break has a run to sit in.
pub func runsOf(n: in Numbering, id: in String, value: in String): List[PlannedRun] {
  val runs: List[PlannedRun] = newList()
  var k = 0
  for line in splitLines(value) {
    val rid = runId(id, k)
    runs.add(PlannedRun(id = rid, num = numberOf(n, rid), text = line.text, lengths = line.lengths))
    k = k + 1
  }
  runs
}

record Place {
  run: Long
  index: Int
}

// A code point offset as a run and an index in it.  An offset at the end of a line that ends with
// a break belongs to the start of the next line, which is where a caret after the break is drawn.
func placeOf(lines: List[Line], runs: List[PlannedRun], offset: Int): Place {
  var k = lines.count - 1
  while k > 0 and lines[k].start > offset {
    k = k - 1
  }
  val within = offset - lines[k].start
  val last = lines[k].lengths.count
  Place(run = runs[k].num, index = if within > last { last } else if within < 0 { 0 } else { within })
}

/// The selection of an input with value `value`, from `AccessNode.selAnchor`/`selCaret`.
pub func selectionOf(
  runs: in List[PlannedRun], value: in String, anchor: in Int, caret: in Int
): Option[PlannedSelection] {
  if anchor < 0 or caret < 0 or runs.count == 0 {
    return None
  }
  val lines = splitLines(value)
  if lines.count != runs.count {
    return None
  }
  val a = placeOf(lines, runs, anchor)
  val f = placeOf(lines, runs, caret)
  Some(value = PlannedSelection(anchorRun = a.run, anchorIndex = a.index, focusRun = f.run, focusIndex = f.index))
}

// ─── Plans ────────────────────────────────────────────────────────────────────
/// A node with its number, the numbers of its children (text runs last) and, for an input, its
/// runs and selection.
pub record PlannedNode {
  num: Long
  node: AccessNode
  childNums: List[Long]
  runs: List[PlannedRun]
  selection: Option[PlannedSelection]
}

/// What an adapter sends: `full` when it replaces whatever the platform has (the first send, or
/// the answer to an assistive technology connecting), the nodes, and the focused node's number.
pub record Plan {
  full: Bool
  rootNum: Long
  focusNum: Long
  nodes: List[PlannedNode]
}

func planNode(n: Numbering, node: AccessNode): PlannedNode {
  val kids: List[Long] = newList()
  for c in node.childIds {
    kids.add(numberOf(n, c))
  }
  if not hasTextRuns(node.role) {
    return PlannedNode(num = numberOf(n, node.id), node = node, childNums = kids, runs = newList(), selection = None)
  }
  val runs = runsOf(n, node.id, node.value)
  for r in runs {
    kids.add(r.num)
  }
  PlannedNode(
    num = numberOf(n, node.id),
    node = node,
    childNums = kids,
    runs = runs,
    selection = selectionOf(runs, node.value, node.selAnchor, node.selCaret)
  )
}

/// Every id `tree` publishes, text runs included: what `retainOnly` keeps after planning it.
pub func liveIds(tree: in AccessTree): List[String] {
  val ids: List[String] = newList()
  for node in tree.nodes {
    ids.add(node.id)
    if hasTextRuns(node.role) {
      var k = 0
      for _ in splitLines(node.value) {
        ids.add(runId(node.id, k))
        k = k + 1
      }
    }
  }
  ids
}

/// The whole of `tree`, numbered with `n`; ids that left the tree lose their numbers.
pub func planTree(n: in Numbering, tree: in AccessTree): Plan {
  val nodes: List[PlannedNode] = newList()
  for node in tree.nodes {
    nodes.add(planNode(n, node))
  }
  val live = liveIds(tree)
  retainOnly(n, live)
  val rootNum = numberOf(n, tree.rootId)
  val focusNum = if live.contains(tree.focus) { numberOf(n, tree.focus) } else { rootNum }
  Plan(full = true, rootNum = rootNum, focusNum = focusNum, nodes = nodes)
}

/// The nodes `update` changed, out of `whole` (the plan of the tree the update leads to).  `None`
/// when nothing changed, so there is nothing to send.
pub func planUpdate(whole: in Plan, update: in AccessUpdate): Option[Plan] {
  if update.full {
    return Some(value = whole)
  }
  if update.changed.count == 0 and not update.focusChanged {
    return None
  }
  val changed: Map[String, Bool] = newMap()
  for c in update.changed {
    changed.add(c.id, true)
  }
  val nodes: List[PlannedNode] = newList()
  for p in whole.nodes {
    match mapGet(changed, p.node.id) {
      case Some(_) -> nodes.add(p)
      case None -> ()
    }
  }
  Some(value = whole.copy(full = false, nodes = nodes))
}
