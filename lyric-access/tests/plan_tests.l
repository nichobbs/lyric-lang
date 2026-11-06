@test_module
package Access.PlanTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Native.Access.{AccessTree, AccessNode, AccessUpdate, Role, Toggled, NotToggle, RoleWindow, RoleButton, RoleTextInput, RoleMultilineInput, RolePasswordInput, diffTrees}
import Access.Plan

func node(id: String, role: Role, value: String, kids: List[String]): AccessNode {
  AccessNode(
    id = id,
    role = role,
    name = id,
    description = "",
    value = value,
    level = 0,
    toggled = NotToggle,
    expanded = None,
    live = "",
    modal = false,
    disabled = false,
    invalid = false,
    required = false,
    readOnly = false,
    sort = "",
    rowCount = 0,
    colCount = 0,
    rowIndex = 0,
    colIndex = 0,
    selAnchor = -1,
    selCaret = -1,
    x = 0.0f32,
    y = 0.0f32,
    w = 10.0f32,
    h = 10.0f32,
    actions = newList(),
    childIds = kids
  )
}

func ids(xs: List[String]): List[String] {
  xs
}

func tree(nodes: List[AccessNode], focus: String): AccessTree {
  AccessTree(rootId = "root", focus = focus, nodes = nodes)
}

func screen(value: String, anchor: Int, caret: Int): AccessTree {
  val kids: List[String] = newList()
  kids.add("save")
  kids.add("name")
  val nodes: List[AccessNode] = newList()
  nodes.add(node("root", RoleWindow, "", kids))
  nodes.add(node("save", RoleButton, "", newList()))
  nodes.add(node("name", RoleTextInput, value, newList()).copy(selAnchor = anchor, selCaret = caret))
  tree(nodes, "name")
}

func planned(p: Plan.Plan, id: String): Option[Plan.PlannedNode] {
  for n in p.nodes {
    if n.node.id == id {
      return Some(value = n)
    }
  }
  None
}

test "numbers are stable, start at 1 and resolve back" {
  val n = Plan.newNumbering()
  val a = Plan.numberOf(n, "a")
  val b = Plan.numberOf(n, "b")
  assertEqualLong(a, 1, "line 74")
  assertEqualLong(b, 2, "line 75")
  assertEqualLong(Plan.numberOf(n, "a"), 1, "line 76")
  match Plan.resolveNumber(n, 2) {
    case Some(id) -> assertEqual(id, "b", "line 78")
    case None -> assertTrue(false, "line 79")
  }
}

test "an id that leaves the tree loses its number, and numbers are not reused" {
  val n = Plan.newNumbering()
  val _ = Plan.numberOf(n, "a")
  val _ = Plan.numberOf(n, "b")
  val live: List[String] = newList()
  live.add("a")
  Plan.retainOnly(n, live)
  assertTrue(Plan.resolveNumber(n, 2).isNone(), "line 90")
  assertEqualLong(Plan.numberOf(n, "b"), 3, "line 91")
  assertEqualLong(Plan.numberOf(n, "a"), 1, "line 92")
}

test "UTF-8 lengths of code points" {
  assertEqualInt(Plan.utf8Length(65), 1, "line 96")
  assertEqualInt(Plan.utf8Length(233), 2, "line 97")
  assertEqualInt(Plan.utf8Length(1488), 2, "line 98")
  assertEqualInt(Plan.utf8Length(20013), 3, "line 99")
  assertEqualInt(Plan.utf8Length(128512), 4, "line 100")
}

test "a value splits into one run per line, the break ending its line" {
  val n = Plan.newNumbering()
  val runs = Plan.runsOf(n, "area", "ab\ncé\n")
  assertEqualInt(runs.count, 3, "line 106")
  assertEqual(runs[0].text, "ab\n", "line 107")
  assertEqualInt(runs[0].lengths.count, 3, "line 108")
  assertEqual(runs[1].text, "cé\n", "line 109")
  assertEqualInt(runs[1].lengths[1], 2, "line 110")
  assertEqual(runs[2].text, "", "line 111")
  assertEqualInt(runs[2].lengths.count, 0, "line 112")
  assertEqual(runs[1].id, "area#run:1", "line 113")
}

test "an empty value has one empty run" {
  val n = Plan.newNumbering()
  val runs = Plan.runsOf(n, "x", "")
  assertEqualInt(runs.count, 1, "line 119")
  assertEqual(runs[0].text, "", "line 120")
}

test "a selection is placed on runs; an offset after a break starts the next line" {
  val n = Plan.newNumbering()
  val value = "ab\ncd"
  val runs = Plan.runsOf(n, "area", value)
  match Plan.selectionOf(runs, value, 1, 3) {
    case Some(s) -> {
      assertEqualLong(s.anchorRun, runs[0].num, "line 129")
      assertEqualInt(s.anchorIndex, 1, "line 130")
      assertEqualLong(s.focusRun, runs[1].num, "line 131")
      assertEqualInt(s.focusIndex, 0, "line 132")
    }
    case None -> assertTrue(false, "line 134")
  }
  match Plan.selectionOf(runs, value, 5, 5) {
    case Some(s) -> {
      assertEqualLong(s.focusRun, runs[1].num, "line 138")
      assertEqualInt(s.focusIndex, 2, "line 139")
    }
    case None -> assertTrue(false, "line 141")
  }
  assertTrue(Plan.selectionOf(runs, value, -1, -1).isNone(), "line 143")
}

test "a plan numbers children and appends an input's runs" {
  val n = Plan.newNumbering()
  val p = Plan.planTree(n, screen("Ada", 0, 3))
  assertTrue(p.full, "line 149")
  assertEqualInt(p.nodes.count, 3, "line 150")
  assertEqualLong(p.rootNum, Plan.numberOf(n, "root"), "line 151")
  assertEqualLong(p.focusNum, Plan.numberOf(n, "name"), "line 152")
  match planned(p, "root") {
    case Some(r) -> {
      assertEqualInt(r.childNums.count, 2, "line 155")
      assertEqualLong(r.childNums[0], Plan.numberOf(n, "save"), "line 156")
    }
    case None -> assertTrue(false, "line 158")
  }
  match planned(p, "name") {
    case Some(input) -> {
      assertEqualInt(input.runs.count, 1, "line 162")
      assertEqualInt(input.childNums.count, 1, "line 163")
      assertEqualLong(input.childNums[0], input.runs[0].num, "line 164")
      match input.selection {
        case Some(s) -> assertEqualInt(s.focusIndex, 3, "line 166")
        case None -> assertTrue(false, "line 167")
      }
    }
    case None -> assertTrue(false, "line 170")
  }
}

test "a password input has no runs" {
  assertFalse(Plan.hasTextRuns(RolePasswordInput), "line 175")
  assertTrue(Plan.hasTextRuns(RoleMultilineInput), "line 176")
}

test "an update plan holds only what changed, and nothing when nothing did" {
  val n = Plan.newNumbering()
  val first = screen("Ada", -1, -1)
  val p1 = Plan.planTree(n, first)
  val up1 = diffTrees(None, first)
  match Plan.planUpdate(p1, up1) {
    case Some(u) -> assertTrue(u.full, "line 185")
    case None -> assertTrue(false, "line 186")
  }
  val p2 = Plan.planTree(n, first)
  assertTrue(Plan.planUpdate(p2, diffTrees(Some(value = first), first)).isNone(), "line 189")
  val second = screen("Adam", -1, -1)
  val p3 = Plan.planTree(n, second)
  match Plan.planUpdate(p3, diffTrees(Some(value = first), second)) {
    case Some(u) -> {
      assertFalse(u.full, "line 194")
      assertEqualInt(u.nodes.count, 1, "line 195")
      assertEqual(u.nodes[0].node.id, "name", "line 196")
      assertEqual(u.nodes[0].runs[0].text, "Adam", "line 197")
    }
    case None -> assertTrue(false, "line 199")
  }
}

test "a focus move alone is still sent" {
  val n = Plan.newNumbering()
  val a = screen("Ada", -1, -1)
  val b = a.copy(focus = "save")
  val p = Plan.planTree(n, b)
  match Plan.planUpdate(p, diffTrees(Some(value = a), b)) {
    case Some(u) -> {
      assertEqualInt(u.nodes.count, 0, "line 210")
      assertEqualLong(u.focusNum, Plan.numberOf(n, "save"), "line 211")
    }
    case None -> assertTrue(false, "line 213")
  }
}

test "numbers of runs that went away are dropped" {
  val n = Plan.newNumbering()
  val _ = Plan.planTree(n, screen("a\nb", -1, -1))
  val second = Plan.runId("name", 1)
  val num = Plan.numberOf(n, second)
  val _ = Plan.planTree(n, screen("a", -1, -1))
  assertTrue(Plan.resolveNumber(n, num).isNone(), "line 223")
}

test "a focus that is not in the tree falls back to the root" {
  val n = Plan.newNumbering()
  val p = Plan.planTree(n, tree(screen("a", -1, -1).nodes, "gone"))
  assertEqualLong(p.focusNum, p.rootNum, "line 232")
  assertTrue(Plan.resolveNumber(n, p.focusNum).isSome(), "line 233")
}
