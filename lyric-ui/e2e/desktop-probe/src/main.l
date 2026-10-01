//! DesktopProbe — proves a desktop window ran the UI runtime against its
//! session: the grid's viewport report can only come from the runtime in
//! the window, over the session socket.  See ../lyric.toml.
@runtime_checked
package DesktopProbe

import Std.Core
import Std.Collections
import Std.Console
import Ui.Core.{View, Step, RowRange, stay, step1}
import Ui.Widgets.{dataGrid, gridSpec, GridColumn}
import Ui.Host.{Instance, instance}
import Ui.Host.Desktop as Desktop
import Ui.Session.{Program}

record Model {
  reported: Bool
}

union Msg {
  case Viewport(r: RowRange)
  case Sorted(column: String)
}

union Effect {
  case Finish(r: RowRange)
}

func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Viewport(r) -> if m.reported {
      stay[Model, Effect](m)
    } else {
      step1[Model, Effect](Model(reported = true), Finish(r = r))
    }
    case Sorted(_) -> stay[Model, Effect](m)
  }
}

func view(m: in Model): View[Msg] {
  val cs: List[GridColumn] = newList()
  cs.add(GridColumn(id = "n", title = "Number", sortable = false))
  val rows: List[View[Msg]] = newList()
  return dataGrid[Msg](
    gridSpec("Numbers", cs, 1000, 0),
    rows,
    { r: RowRange -> Viewport(r = r) },
    { c: String -> Sorted(column = c) }
  )
}

func run(e: in Effect): Option[Msg] {
  match e {
    case Finish(r) -> {
      println("desktop-probe: the window reported rows " + r.first.toString() + "+" + r.count.toString())
      Desktop.close()
    }
  }
  return None
}

func screen(): Instance {
  val p = Program(update = update, view = view, uiEffect = { _: Effect -> None })
  return instance(p, stay[Model, Effect](Model(reported = false)), run)
}

func main(): Unit {
  Desktop.run(Desktop.defaultConfig("Desktop probe"), { _: String -> Some(value = screen()) })
}
