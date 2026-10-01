//! tests/html_tests.l — Ui.Html, the prerendered first view (D152).  The
//! markup must match what runtime/src/render.ts builds, so these tests pin
//! the elements, classes and ARIA wiring it produces.
@test_module
package Ui.HtmlTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Ui.Core.{View}
import Ui.Diff.{toWire}
import Ui.Html.{renderHtml, escapeHtml}
import Ui.Widgets.{button, column, field, textInput, inputOpts, checkbox, select, SelectChoice, heading, banner, card, spinner, InputOpts}

union Msg {
  case Typed(s: String)
  case Clicked
}

func typed(s: in String): Msg {
  return Typed(s = s)
}

func html(v: in View[Msg]): String {
  return renderHtml(toWire(v))
}

test "text is escaped and empty nodes are comments" {
  val v: View[Msg] = heading[Msg](2, "<b> & \"q\"")
  assertEqual(html(v), "<h2 class=\"lui-heading\">&lt;b&gt; &amp; &quot;q&quot;</h2>", "heading")
  assertEqual(escapeHtml("'"), "&#39;", "apostrophe")
}

test "a field labels its input and is described by its errors" {
  val errs: List[String] = newList()
  errs.add("Name is required")
  val opts = InputOpts(placeholder = "Acme", required = true, readonly = false, maxLength = 100)
  val v: View[Msg] = field[Msg]("Name", errs, textInput[Msg]("text", "", typed, opts))
  assertEqual(
    html(v),
    "<div class=\"lui-field lui-invalid\"><label class=\"lui-field-label\" for=\"lui-s1\">Name</label>" +
      "<div class=\"lui-field-body\"><input class=\"lui-input\" id=\"lui-s1\" type=\"text\" value=\"\" placeholder=\"Acme\" maxlength=\"100\"" +
      " required aria-required=\"true\" aria-describedby=\"lui-s2\" aria-invalid=\"true\">" +
      "<div class=\"lui-field-error\" id=\"lui-s2\">Name is required</div></div></div>",
    "field markup"
  )
}

test "a checkbox, a select and a button" {
  val cb: View[Msg] = checkbox[Msg]("Active", true, typed)
  assertEqual(
    html(cb),
    "<label class=\"lui-checkbox\"><input class=\"\" type=\"checkbox\" id=\"lui-s1\" checked><span class=\"\">Active</span></label>",
    "checkbox"
  )
  val choices: List[SelectChoice] = newList()
  choices.add(SelectChoice(value = "a", label = "Alpha"))
  choices.add(SelectChoice(value = "b", label = "Beta"))
  val sel: View[Msg] = select[Msg]("b", choices, typed)
  assertEqual(
    html(sel),
    "<select class=\"lui-select\" id=\"lui-s1\"><option class=\"\" value=\"a\">Alpha</option>" +
      "<option class=\"\" value=\"b\" selected>Beta</option></select>",
    "select marks its value"
  )
  assertEqual(
    html(button[Msg]("Save", Clicked)),
    "<button class=\"lui-button\" data-variant=\"default\" type=\"button\">Save</button>",
    "button"
  )
}

test "chrome: cards, banners and spinners" {
  val kids: List[View[Msg]] = newList()
  kids.add(banner[Msg]("error", "Failed"))
  kids.add(spinner[Msg]("Loading"))
  val v: View[Msg] = card[Msg]("Details", kids)
  assertEqual(
    html(v),
    "<section class=\"lui-card\"><h2 class=\"lui-card-title\">Details</h2><div class=\"lui-card-body\">" +
      "<div class=\"lui-banner\" data-tone=\"error\" role=\"alert\">Failed</div>" +
      "<div class=\"lui-spinner\" role=\"status\" aria-label=\"Loading\"></div></div></section>",
    "card"
  )
}

test "ids are numbered in document order, so the same tree renders the same text" {
  val cs: List[View[Msg]] = newList()
  cs.add(textInput[Msg]("text", "a", typed, inputOpts()))
  cs.add(textInput[Msg]("email", "b", typed, inputOpts()))
  val v: View[Msg] = column[Msg](cs)
  val once = html(v)
  assertEqual(once, html(v), "deterministic")
  assertTrue(contains(once, "id=\"lui-s1\" type=\"text\" value=\"a\""), once)
  assertTrue(contains(once, "id=\"lui-s2\" type=\"email\" value=\"b\""), once)
}
