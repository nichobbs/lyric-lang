//! Generics shaped like `Ui.Widgets`' builders: `paragraph`'s type parameter
//! appears only in its return type, and `keyed` passes a view through.
package NestedLib

import Std.Core
import Std.Collections

pub union View[Msg] {
  case Text(value: String)
  case Element(key: String, children: List[View[Msg]])
}

pub func paragraph[Msg](s: in String): View[Msg] {
  val kids: List[View[Msg]] = newList()
  val t: View[Msg] = Text(value = s)
  kids.add(t)
  Element(key = "", children = kids)
}

pub func keyed[Msg](key: in String, v: in View[Msg]): View[Msg] {
  match v {
    case Element(_, children) -> Element(key = key, children = children)
    case Text(_) -> v
  }
}

pub func keyOf[Msg](v: in View[Msg]): String {
  match v {
    case Element(key, _) -> key
    case Text(_) -> ""
  }
}
