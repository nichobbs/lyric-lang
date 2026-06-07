//! union_list_match_self_test.l — regression for #2126.
//!
//! The self-hosted MSIL emitter bound a `for x in list.toArray()` loop variable
//! as erased `object` rather than the list's element type, so `match x` saw an
//! untyped scrutinee and silently took the first union case (and a field read on
//! `x` returned garbage).  These cases exercise the fixed path: iterating a
//! `List[Union]` via `toArray()` and matching the element — directly and via a
//! record field — must select the correct case.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/union_list_match_self_test.l
@test_module
package Lyric.UnionListMatchSelfTest

import Std.Core
import Std.Collections
import Std.Testing

union Ref {
  case Tag(name: String)
  case Rev(sha: String)
}

union Src {
  case Reg(version: String)
  case Git(url: String, ref: Ref, subdir: Option[String])
}

record Entry {
  name: String
  source: Src
}

func refLabel(r: in Ref): String {
  match r {
    case Tag(name) -> "tag:" + name
    case Rev(sha) -> "rev:" + sha
  }
}

test "for over toArray + match selects the correct union case (not the first)" {
  val xs: List[Src] = newList()
  xs.add(Git(url = "u", ref = Tag(name = "v1.0"), subdir = None))
  var got = "none"
  for s in xs.toArray() {
    match s {
      case Reg(v) -> {
        got = "reg:" + v
      }
      case Git(url, r, subdir) -> {
        got = refLabel(r)
      }
    }
  }
  assertEqual(got, "tag:v1.0", "Git element matched as Git, ref read as Tag")
}

test "for over toArray of records + field access + nested match" {
  val es: List[Entry] = newList()
  es.add(Entry(name = "a", source = Reg(version = "1.2.3")))
  es.add(Entry(name = "b", source = Git(url = "u", ref = Rev(sha = "abc"), subdir = None)))
  var acc = ""
  for e in es.toArray() {
    match e.source {
      case Reg(v) -> {
        acc = acc + "reg:" + v + ";"
      }
      case Git(url, r, subdir) -> {
        acc = acc + refLabel(r) + ";"
      }
    }
  }
  assertEqual(acc, "reg:1.2.3;rev:abc;", "record-field union round-trips through the loop")
}

test "first union case still matches when it is the actual case" {
  val xs: List[Src] = newList()
  xs.add(Reg(version = "9.9"))
  var got = "none"
  for s in xs.toArray() {
    match s {
      case Reg(v) -> {
        got = "reg:" + v
      }
      case Git(url, r, subdir) -> {
        got = "git"
      }
    }
  }
  assertEqual(got, "reg:9.9", "Reg element still matches Reg")
}

// #2363 Stage 4: union and case names that contain `_` must construct and match
// correctly.  Case classes are emitted `Union_Case`, so the parent union is
// recovered from the registered map (NOT by splitting the name on `_`, which
// would be ambiguous here: `My_Status_Not_Ready` must resolve to `My_Status`,
// not `My_Status_Not`).
union My_Status {
  case Not_Ready(why: String)
  case All_Set(code: Int)
}

func statusLabel(s: in My_Status): String {
  match s {
    case Not_Ready(why) -> "wait:" + why
    case All_Set(code) -> "ok:" + toString(code)
  }
}

test "union and case names containing underscores construct and match" {
  val a: My_Status = Not_Ready(why = "soon")
  val b: My_Status = All_Set(code = 7)
  assertEqual(statusLabel(a), "wait:soon", "underscore case Not_Ready round-trips")
  assertEqual(statusLabel(b), "ok:7", "underscore case All_Set round-trips")
  // Also exercise the list-iteration + match path with underscore names.
  val xs: List[My_Status] = newList()
  xs.add(b)
  xs.add(a)
  var acc = ""
  for s in xs.toArray() {
    acc = acc + statusLabel(s) + ";"
  }
  assertEqual(acc, "ok:7;wait:soon;", "underscore union round-trips through the loop")
}
