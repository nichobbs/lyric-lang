//! tests/protocol_tests.l — Ui.Protocol: host message decoding and patch
//! encoding.
@test_module
package Ui.ProtocolTests

import Std.Core
import Std.String
import Std.Testing
import Ui.Core.{View}
import Ui.Widgets.{button}
import Ui.Diff
import Ui.Diff.{Patch, SetProp, SetText, replaceAll}
import Ui.Protocol
import Ui.Protocol.{ClientMessage, Hello, EventMsg, Sync, ValueEcho, NodeRef, At, Keyed}

union Msg {
  case Go
}

func ints(a: in Int, b: in Int): List[Int] {
  val acc: List[Int] = newList()
  acc.add(a)
  acc.add(b)
  return acc
}

test "decodes an event" {
  match Protocol.decodeClient("{\"t\":\"event\",\"v\":4,\"p\":[0,\"cust-42\",1],\"e\":\"input\",\"d\":\"Acme\",\"iv\":7}") {
    case Ok(EventMsg(ev)) -> {
      assertEqualInt(ev.renderVersion, 4, "render version")
      assertEqualInt(ev.path.count, 3, "path length")
      match ev.path[0] {
        case At(i) -> assertEqualInt(i, 0, "index step")
        case _ -> assertTrue(false, "expected index")
      }
      match ev.path[1] {
        case Keyed(k) -> assertEqual(k, "cust-42", "key step")
        case _ -> assertTrue(false, "expected key")
      }
      assertEqual(ev.name, "input", "event name")
      assertEqual(ev.data, "Acme", "data")
      assertEqualInt(ev.inputVersion, 7, "input version")
    }
    case _ -> assertTrue(false, "expected an event")
  }
}

test "decodes hello and sync" {
  match Protocol.decodeClient("{\"t\":\"hello\",\"pv\":2,\"url\":\"/customers/7\"}") {
    case Ok(Hello(pv, url, sid)) -> {
      assertEqualInt(pv, 2, "protocol version")
      assertEqual(url, "/customers/7", "url")
      assertEqual(sid, "", "no session id")
    }
    case _ -> assertTrue(false, "expected hello")
  }
  match Protocol.decodeClient("{\"t\":\"hello\",\"pv\":2,\"url\":\"/\",\"sid\":\"abc123\"}") {
    case Ok(Hello(_, _, sid)) -> assertEqual(sid, "abc123", "session id")
    case _ -> assertTrue(false, "expected hello")
  }
  match Protocol.decodeClient("{\"t\":\"sync\"}") {
    case Ok(Sync) -> assertTrue(true, "sync")
    case _ -> assertTrue(false, "expected sync")
  }
}

test "rejects malformed and unknown messages" {
  for bad in ["not json", "{}", "{\"t\":\"dance\"}", "{\"t\":\"event\",\"v\":1,\"p\":[\"\"],\"e\":\"click\"}", "{\"t\":\"event\",\"v\":1,\"p\":[-1],\"e\":\"click\"}", "{\"t\":\"event\",\"v\":1,\"p\":[true],\"e\":\"click\"}", "{\"t\":\"hello\"}"] {
    match Protocol.decodeClient(bad) {
      case Ok(_) -> assertTrue(false, "should reject " + bad)
      case Err(_) -> assertTrue(true, "rejected")
    }
  }
}

test "value updates carry the recorded input version" {
  val ivs: List[ValueEcho] = newList()
  ivs.add(ValueEcho(pathKey = Protocol.pathKey(ints(0, 2)), version = 5))
  val ps: List[Patch] = newList()
  ps.add(SetProp(path = ints(0, 2), name = "value", value = "Acme"))
  ps.add(SetProp(path = ints(0, 3), name = "value", value = "x"))
  val json = Protocol.encodePatches(9, ps, ivs)
  assertTrue(contains(json, "\"v\":9"), "render version: " + json)
  assertTrue(contains(json, "\"iv\":5"), "input version on the recorded path: " + json)
  assertFalse(contains(json, "\"iv\":0"), "no input version elsewhere: " + json)
}

test "encodes a full render" {
  val v: View[Msg] = button[Msg]("Save", Go)
  val patches: List[Patch] = replaceAll(v)
  val json = Protocol.encodePatches(1, patches, newList())
  assertTrue(contains(json, "\"op\":\"replace\""), json)
  assertTrue(contains(json, "\"k\":\"button\""), json)
  assertTrue(contains(json, "\"label\":\"Save\""), json)
  assertTrue(contains(json, "\"e\":[\"click\"]"), json)
}

test "escapes text safely" {
  val ps: List[Patch] = newList()
  ps.add(SetText(path = ints(0, 0), value = "<b>\"quoted\"</b>\n"))
  val json = Protocol.encodePatches(2, ps, newList())
  assertTrue(contains(json, "\\\"quoted\\\""), json)
  assertTrue(contains(json, "\\n"), json)
}

test "host commands encode" {
  assertTrue(contains(Protocol.encodeNavigate("/c/1"), "\"url\":\"/c/1\""), "navigate")
  assertTrue(contains(Protocol.encodeToast("Saved", "success"), "\"level\":\"success\""), "toast")
  assertTrue(contains(Protocol.encodeBack(), "\"t\":\"back\""), "back")
}

test "session ids encode and event path keys are unambiguous" {
  assertTrue(contains(Protocol.encodeSession("abc"), "\"id\":\"abc\""), "session message")
  val a: List[NodeRef] = newList()
  a.add(Keyed(key = "1;k1:x"))
  val b: List[NodeRef] = newList()
  b.add(Keyed(key = "1"))
  b.add(Keyed(key = "x"))
  assertFalse(Protocol.refsKey(a) == Protocol.refsKey(b), "length prefix keeps keys apart")
  val c: List[NodeRef] = newList()
  c.add(At(index = 1))
  val d: List[NodeRef] = newList()
  d.add(Keyed(key = "1"))
  assertFalse(Protocol.refsKey(c) == Protocol.refsKey(d), "index and key differ")
}
