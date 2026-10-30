//! tests/routes_tests.l - the generated `parseRoute` / `routeUrl` of
//! `Customers.Routes` at run time, including the `@query` parameters of
//! `CustomerSearch` (docs/65 §6.1, #7907).
@test_module
package Customers.RoutesTests

import Std.Core
import Std.Testing
import Customers.Domain.{CustomerId}
import Customers.Routes.{Route, parseRoute, routeUrl}

func expectSearch(url: in String): Route {
  return match parseRoute(url) { case Some(r) -> r; case None -> panic("expected a route for " + url) }
}

func termOf(r: in Route): String {
  return match r {
    case CustomerSearch(term, _) -> match term { case Some(t) -> t; case None -> "<none>" }
    case _ -> "<not a search>"
  }
}

func pageOf(r: in Route): Int {
  return match r { case CustomerSearch(_, page) -> match page { case Some(p) -> p; case None -> -1 }; case _ -> -2 }
}

test "path routes are unchanged by the query support" {
  assertTrue(match parseRoute("/customers") { case Some(Route.CustomerList) -> true; case _ -> false }, "list")
  assertTrue(match parseRoute("/customers/7") { case Some(Route.EditCustomer(_)) -> true; case _ -> false }, "edit")
  assertTrue(match parseRoute("/nowhere") { case None -> true; case Some(_) -> false }, "unknown")
  assertEqual(routeUrl(Route.CustomerList), "/customers", "list url")
}

test "query parameters are optional and read by name" {
  assertEqual(termOf(expectSearch("/customers/search")), "<none>", "no term")
  assertEqualInt(pageOf(expectSearch("/customers/search")), -1, "no page")
  val both = expectSearch("/customers/search?term=ada+lovelace&page=3")
  assertEqual(termOf(both), "ada lovelace", "term")
  assertEqualInt(pageOf(both), 3, "page")
  assertEqual(termOf(expectSearch("/customers/search?page=2&term=x%26y#frag")), "x&y", "order and fragment")
}

test "an unusable query value makes the route not match" {
  assertTrue(
    match parseRoute("/customers/search?page=abc") { case None -> true; case Some(_) -> false },
    "non-numeric page"
  )
  assertTrue(match parseRoute("/customers/search?term=%zz") { case None -> true; case Some(_) -> false }, "bad escape")
}

test "routeUrl writes Some parameters after the path and skips None" {
  assertEqual(routeUrl(Route.CustomerSearch(term = None, page = None)), "/customers/search", "none")
  assertEqual(
    routeUrl(Route.CustomerSearch(term = Some(value = "ada lovelace & co"), page = Some(value = 2))),
    "/customers/search?term=ada%20lovelace%20%26%20co&page=2",
    "both"
  )
  val r = Route.CustomerSearch(term = Some(value = "ü=1&+"), page = None)
  assertEqual(termOf(expectSearch(routeUrl(r))), "ü=1&+", "parse of routeUrl is the route")
}
