//! tests/list_tests.l — the customer list screen, tested with no UI host:
//! logic through `update` and view through `Ui.Testing` queries.
@test_module
package Customers.ListTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{WidgetKind, RowRange}
import Ui.Grid.{RowQuery}
import Ui.Testing as UiTest
import Customers.Domain.{Customer, CustomerId, CreditLimit, Tier, CustomerOrder, CustomerPage}
import Customers.List.Logic as ListLogic
import Customers.List.Logic.{Model, Msg, Effect, RowsLoaded, RetryClicked, Scrolled, Sorted, FetchRows, Status}
import Customers.List.View as ListView

func customer(id: in Long, name: in String): Customer {
  return Customer(
    id = CustomerId.from(id),
    name = name,
    email = name + "@example.test",
    creditLimit = CreditLimit.from(1000),
    tier = Tier.Preferred,
    notes = None
  )
}

func queryOf(e: in Effect): RowQuery {
  return match e {
    case FetchRows(q) -> q
    case _ -> {
      assertTrue(false, "expected a fetch")
      RowQuery(seq = 0, first = 0, count = 0, sortColumn = "", ascending = true, filter = "")
    }
  }
}

func onlyQuery(effects: in List[Effect]): RowQuery {
  assertEqualInt(effects.count, 1, "one effect")
  return queryOf(effects[0])
}

// The screen after the first page (two customers) arrives.
func loadedModel(): Model {
  val s = ListLogic.init()
  val q = onlyQuery(s.effects)
  val cs: List[Customer] = newList()
  cs.add(customer(1, "Acme"))
  cs.add(customer(2, "Birchwood"))
  return ListLogic.update(s.model, RowsLoaded(seq = q.seq, first = 0, outcome = Ok(value = CustomerPage(total = 2, customers = cs)))).model
}

test "starts by fetching the first page" {
  val s = ListLogic.init()
  val q = onlyQuery(s.effects)
  assertEqualInt(q.first, 0, "from the top")
  assertEqualInt(q.count, ListLogic.pageSize, "one page")
  assertTrue(UiTest.hasText(ListView.view(s.model), "Loading customers"), "spinner label")
}

test "shows each loaded customer with a link to its editor" {
  val v = ListView.view(loadedModel())
  assertTrue(UiTest.hasText(v, "Acme"), "first customer")
  assertTrue(UiTest.hasText(v, "Birchwood@example.test"), "second customer's email")
  assertTrue(UiTest.hasText(v, "Preferred"), "tier label")
  assertEqualInt(UiTest.findAll(v, WidgetKind.DataGrid).count, 1, "a data grid")
  val links = UiTest.findAll(v, WidgetKind.Link)
  assertEqualInt(links.count, 2, "one link per customer")
  match UiTest.lookupPropOf(links[1], "href") {
    case Some(href) -> assertEqual(href, "/customers/2", "the second link opens customer 2")
    case None -> assertTrue(false, "link has an href")
  }
}

test "sorting by a column fetches in that order, and reverses on a second click" {
  val byName = ListLogic.update(loadedModel(), Sorted(column = "name"))
  val q = onlyQuery(byName.effects)
  assertEqual(q.sortColumn, "name", "sort column")
  assertTrue(q.ascending, "ascending")
  match ListLogic.orderFor(q.sortColumn) {
    case ByName -> ()
    case _ -> assertTrue(false, "name order")
  }
  val reversed = ListLogic.update(byName.model, Sorted(column = "name"))
  assertFalse(onlyQuery(reversed.effects).ascending, "descending")
}

test "scrolling within the loaded rows fetches nothing; a stale page is ignored" {
  val m = loadedModel()
  assertEqualInt(ListLogic.update(m, Scrolled(range = RowRange(first = 0, count = 2))).effects.count, 0, "loaded")
  val sorted = ListLogic.update(m, Sorted(column = "email"))
  val none: List[Customer] = newList()
  val stale = ListLogic.update(
    sorted.model,
    RowsLoaded(seq = 1, first = 0, outcome = Ok(value = CustomerPage(total = 0, customers = none)))
  )
  assertEqualInt(stale.model.grid.rows.count, 2, "the older answer is ignored")
}

test "a failed load offers a retry that loads again" {
  val s = ListLogic.init()
  val q = onlyQuery(s.effects)
  val failed = ListLogic.update(s.model, RowsLoaded(seq = q.seq, first = 0, outcome = Err(error = "connection reset"))).model
  val v = ListView.view(failed)
  assertTrue(UiTest.hasText(v, "Could not load the customers: connection reset"), "error banner")
  match UiTest.click(v, "Retry") {
    case Some(msg) -> {
      val again = ListLogic.update(failed, msg)
      assertEqualInt(onlyQuery(again.effects).first, 0, "retry loads again")
    }
    case None -> assertTrue(false, "a Retry button")
  }
}
