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
