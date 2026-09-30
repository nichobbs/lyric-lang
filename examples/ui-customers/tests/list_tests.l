//! tests/list_tests.l — the customer list screen, tested with no UI host:
//! logic through `update` and view through `Ui.Testing` queries.
@test_module
package Customers.ListTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{WidgetKind}
import Ui.Testing as UiTest
import Customers.Domain.{Customer, CustomerId, CreditLimit, Tier}
import Customers.List.Logic as ListLogic
import Customers.List.Logic.{Model, Msg, Effect, CustomersLoaded, RetryClicked, LoadCustomers, Status}
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

func isLoad(e: in Effect): Bool {
  return match e { case LoadCustomers -> true; case _ -> false }
}

test "starts loading every customer" {
  val s = ListLogic.init()
  assertEqualInt(s.effects.count, 1, "one effect")
  assertTrue(isLoad(s.effects[0]), "load customers")
  assertTrue(UiTest.hasText(ListView.view(s.model), "Loading customers"), "spinner label")
}

test "shows each loaded customer with a link to its editor" {
  val cs: List[Customer] = newList()
  cs.add(customer(1, "Acme"))
  cs.add(customer(2, "Birchwood"))
  val s = ListLogic.update(ListLogic.init().model, CustomersLoaded(outcome = Ok(value = cs)))
  assertEqualInt(s.effects.count, 0, "no effects once loaded")
  val v = ListView.view(s.model)
  assertTrue(UiTest.hasText(v, "Acme"), "first customer")
  assertTrue(UiTest.hasText(v, "Birchwood@example.test"), "second customer's email")
  assertTrue(UiTest.hasText(v, "Preferred"), "tier label")
  val links = UiTest.findAll(v, WidgetKind.Link)
  assertEqualInt(links.count, 2, "one link per customer")
  match UiTest.lookupPropOf(links[1], "href") {
    case Some(href) -> assertEqual(href, "/customers/2", "the second link opens customer 2")
    case None -> assertTrue(false, "link has an href")
  }
}

test "a failed load offers a retry that loads again" {
  val failed = ListLogic.update(ListLogic.init().model, CustomersLoaded(outcome = Err(error = "connection reset"))).model
  val v = ListView.view(failed)
  assertTrue(UiTest.hasText(v, "Could not load the customers: connection reset"), "error banner")
  match UiTest.click(v, "Retry") {
    case Some(msg) -> {
      val s = ListLogic.update(failed, msg)
      assertEqualInt(s.effects.count, 1, "one effect")
      assertTrue(isLoad(s.effects[0]), "retry loads again")
    }
    case None -> assertTrue(false, "a Retry button")
  }
}
