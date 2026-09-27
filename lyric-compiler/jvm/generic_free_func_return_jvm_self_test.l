//! generic_free_func_return_jvm_self_test.l — executable
//! regression test for #7337: `match mapGet(m, key) { case Some(v) -> v.field
//! }`, where `m` is a `Map[K, V]`-typed field reached through a chained
//! field-access/index receiver, failed with `error[J007]: member '<f>'
//! cannot be resolved on an erased (statically Object) receiver`.
//!
//! `Std.Collections.mapGet[K, V](m: in Map[K, V], key: in K): Option[V]`
//! declares its return as `Option[V]` — `V` being `mapGet`'s OWN generic
//! parameter, not a resolved type. `Jvm.Codegen.returnTypeGenericArgsFiltered`
//! already (correctly) refuses to trust a bare reference to a function's own
//! type parameter as if it were a concrete type, so `mapGet`'s registered
//! `JvmFuncSig.retGenericArgs` is empty — a `match mapGet(...) { case
//! Some(v) -> ... }` had no way to recover `V`'s concrete class for THIS
//! call, leaving `v` erased `Object` and any field read on it a J007.
//!
//! The fix (`Jvm.Codegen.inferGenericReturnArgsFromCallArgs`) recovers the
//! substitution from the CALL SITE's own arguments instead: unify `mapGet`'s
//! declared `m: in Map[K, V]` parameter shape against the actual argument
//! expression's own recovered instantiation (`Jvm.Codegen.
//! scrutineeGenericArgs`), positionally solving `V`. Recovering that
//! argument's instantiation in turn required teaching `Jvm.Codegen.
//! receiverClassOf` to recurse through a chained `EMember`/`EIndex` receiver
//! (`evt.records[0].dynamodb.keys`, the lambda_tests.l/lambda_dispatch_tests.l
//! shape that reported this) instead of only resolving a bare local/`self`
//! receiver.
//!
//! Reproduces the exact reported shapes at both nesting depths:
//!   - a Map field reached through one level of indexing + one field hop
//!     (`Lambda.LambdaTests`'s `evt.records[0].dynamodb.keys`,
//!     `attr.s`).
//!   - a Map field reached through a direct field hop with no indexing
//!     (`Lambda.DispatchTests`'s `event.records[0].sns.messageAttributes`,
//!     `attr.attributeType` / `attr.value`).
//!
//! Run in CI via native `lyric test` on **both targets** (like
//! `bitwise_self_test.l`): `--target jvm` is the load-bearing run (the actual
//! erasure bug); `--target dotnet` exercises the same shapes on the CLR,
//! which never erases generics so it always passed. Imports only `Std.*`, so
//! no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm    lyric-compiler/jvm/generic_free_func_return_jvm_self_test.l
//!   lyric test --target dotnet lyric-compiler/jvm/generic_free_func_return_jvm_self_test.l
@test_module
package Lyric.GenericFreeFuncReturnFromFieldChainJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Attr {
  s: Option[String]
  n: Option[Int]
}

record Detail {
  keys: Map[String, Attr]
}

record StreamRecord {
  detail: Detail
}

record Event {
  records: List[StreamRecord]
}

record DirectDetail {
  messageAttributes: Map[String, Attr]
}

record DirectRecord {
  detail: DirectDetail
}

func firstKeyAttr(evt: in Event): Option[Attr] {
  mapGet(evt.records[0].detail.keys, "id")
}

func attrByName(rec: in DirectRecord, name: in String): Option[Attr] {
  mapGet(rec.detail.messageAttributes, name)
}

test "mapGet on a Map field reached through index + field hops (#7337, Lambda.LambdaTests shape)" {
  val attrs: Map[String, Attr] = newMap()
  attrs.add("id", Attr(s = Some(value = "pk-1"), n = None))
  val rec = StreamRecord(detail = Detail(keys = attrs))
  val recs: List[StreamRecord] = newList()
  recs.add(rec)
  val evt = Event(records = recs)
  match firstKeyAttr(evt) {
    case Some(attr) -> {
      match attr.s {
        case Some(v) -> assertEqual(v, "pk-1", "key attribute string value")
        case None -> assertTrue(false, "attr.s must be Some")
      }
    }
    case None -> assertTrue(false, "must have id key")
  }
}

test "mapGet on a Map field reached through a direct field hop, no indexing (#7337, Lambda.DispatchTests shape)" {
  val attrs: Map[String, Attr] = newMap()
  attrs.add("Test", Attr(s = Some(value = "TestString"), n = None))
  val rec = DirectRecord(detail = DirectDetail(messageAttributes = attrs))
  match attrByName(rec, "Test") {
    case Some(attr) -> {
      match attr.s {
        case Some(v) -> assertEqual(v, "TestString", "message attribute value decoded")
        case None -> assertTrue(false, "attr.s must be Some")
      }
    }
    case None -> assertTrue(false, "messageAttributes must contain Test")
  }
}

test "mapGet destructured directly at the match site (no intermediate binding)" {
  val attrs: Map[String, Attr] = newMap()
  attrs.add("k", Attr(s = None, n = Some(value = 42)))
  match mapGet(attrs, "k") {
    case Some(attr) -> {
      match attr.n {
        case Some(v) -> assertEqualInt(v, 42, "attr.n decoded")
        case None -> assertTrue(false, "attr.n must be Some")
      }
    }
    case None -> assertTrue(false, "must have key k")
  }
}
