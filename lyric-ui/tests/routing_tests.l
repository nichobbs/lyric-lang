//! tests/routing_tests.l — Ui.Routing path splitting and percent encoding.
@test_module
package Ui.RoutingTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Routing

func segs(url: in String): List[String] {
  return match Routing.pathSegments(url) { case Some(s) -> s; case None -> panic("expected segments for " + url) }
}

test "pathSegments drops the query, the fragment and empty segments" {
  val s = segs("/customers//42/?tab=notes#top")
  assertEqualInt(s.count, 2, "two segments")
  assertEqual(s[0], "customers", "first")
  assertEqual(s[1], "42", "second")
  assertEqualInt(segs("/").count, 0, "the root has none")
  assertEqualInt(segs("").count, 0, "nor does the empty path")
}

test "segments are percent-decoded as UTF-8" {
  val s = segs("/tags/caf%C3%A9%20au%20lait")
  assertEqual(s[1], "café au lait", "decoded")
  assertTrue(match Routing.pathSegments("/bad/%E9") { case None -> true; case Some(_) -> false }, "invalid UTF-8")
  assertTrue(match Routing.pathSegments("/bad/%4") { case None -> true; case Some(_) -> false }, "truncated escape")
  assertTrue(match Routing.pathSegments("/bad/%zz") { case None -> true; case Some(_) -> false }, "non-hex escape")
}

test "encodeSegment escapes everything but unreserved characters" {
  assertEqual(Routing.encodeSegment("a-b_c.d~e"), "a-b_c.d~e", "unreserved")
  assertEqual(Routing.encodeSegment("café au/lait"), "caf%C3%A9%20au%2Flait", "UTF-8 and reserved")
  val parts: List[String] = newList()
  parts.add("tags")
  parts.add("a/b")
  assertEqual(Routing.joinPath(parts), "/tags/a%2Fb", "joined")
  assertEqual(Routing.joinPath(newList()), "/", "no segments is the root")
}

test "encode then decode is the identity" {
  for s in ["plain", "with space", "ünïcödé", "100%", "a?b#c"] {
    val one: List[String] = newList()
    one.add(s)
    assertEqual(segs(Routing.joinPath(one))[0], s, "round trip of " + s)
  }
}

test "numeric segments" {
  assertTrue(match Routing.intSegment("42") { case Some(n) -> n == 42; case None -> false }, "an Int")
  assertTrue(match Routing.intSegment("3000000000") { case None -> true; case Some(_) -> false }, "too big for an Int")
  assertTrue(match Routing.longSegment("3000000000") { case Some(n) -> n == 3000000000; case None -> false }, "a Long")
  assertTrue(match Routing.longSegment("4x") { case None -> true; case Some(_) -> false }, "not a number")
}

test "queryPresent and queryValue read the first pair of a name" {
  assertTrue(Routing.queryPresent("/a?x=1&y=2", "y"), "present")
  assertFalse(Routing.queryPresent("/a?x=1", "y"), "absent")
  assertFalse(Routing.queryPresent("/a#frag?y=1", "y"), "a fragment hides the query")
  assertTrue(Routing.queryPresent("/a?flag", "flag"), "a pair without = is present")
  assertEqual(optionOr(Routing.queryValue("/a?flag", "flag"), "<none>"), "", "and has the empty value")
  assertEqual(optionOr(Routing.queryValue("/a?x=1&x=2", "x"), "<none>"), "1", "the first of repeated names wins")
  assertEqual(optionOr(Routing.queryValue("/a?q=caf%C3%A9+au%20lait", "q"), "<none>"), "café au lait", "decoded")
  assertEqual(optionOr(Routing.queryValue("/a?q=1%2B1", "q"), "<none>"), "1+1", "%2B is a literal plus")
  assertEqual(optionOr(Routing.queryValue("/a?a%20b=2", "a b"), "<none>"), "2", "names are decoded too")
  assertEqual(optionOr(Routing.queryValue("/a?x=1#y=2", "y"), "<none>"), "<none>", "the fragment is dropped")
}

test "a malformed query value is present but has no value" {
  assertTrue(Routing.queryPresent("/a?q=%zz", "q"), "present")
  assertEqual(optionOr(Routing.queryValue("/a?q=%zz", "q"), "<none>"), "<none>", "bad escape")
  assertEqual(optionOr(Routing.queryValue("/a?q=%E9", "q"), "<none>"), "<none>", "invalid UTF-8")
}

test "withQuery appends encoded pairs and skips None" {
  val one = Routing.withQuery("/a", "q", Some(value = "x y"))
  assertEqual(one, "/a?q=x%20y", "first pair")
  assertEqual(Routing.withQuery(one, "page", Some(value = "2")), "/a?q=x%20y&page=2", "second pair")
  assertEqual(Routing.withQuery("/a", "q", None), "/a", "None leaves the url alone")
  assertEqual(Routing.withQuery("/a", "q", Some(value = "1+1&")), "/a?q=1%2B1%26", "reserved characters")
  assertEqual(
    optionOr(Routing.queryValue(Routing.withQuery("/a", "q", Some(value = "ü + &=")), "q"), "<none>"),
    "ü + &=",
    "round trip"
  )
}

func optionOr(o: in Option[String], fallback: in String): String {
  return match o { case Some(v) -> v; case None -> fallback }
}
