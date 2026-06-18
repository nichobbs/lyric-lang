// #1727 (inference slice): the monomorphizer now (a) receives the stdlib's
// pure-Lyric generic `pub func`s as imported generics, (b) rewrites impl- and
// interface-method bodies, and (c) infers types through `self.field`
// projections and `Map`/`List` indexing.  Together these let a call like
// `unwrapOr(self.items[i], d)` specialise into a concrete copy so its return
// type stays concrete and a consumer `match` finds the right arm.
//
// Scope: pure-Lyric stdlib generics whose type argument is inferable at the
// call site (here via the `default` argument), exercised from free functions
// and impl methods over reference-typed payloads.  Generics whose bodies call
// a kernel extern (`mapGet` -> `tryGetValue`), value-type specialisations, and
// non-inferable call shapes (`isSome(None)`) need further self-hosted codegen
// work and are tracked separately.
//
// MSIL target only; JVM-target parity for same-package generic specialization
// is tracked in #1707.

@test_module
package Lyric.StdlibGenericMonoSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ── Free-function call sites ────────────────────────────────────────────────

test "unwrapOr on Some/None specialises and round-trips (String)" {
  assertEqual(unwrapOr(Some(value = "hit"), "fb"), "hit", "Some -> payload")
  assertEqual(unwrapOr(None, "fb"), "fb", "None -> fallback")
}

test "unwrapOr specialises independently per call site" {
  assertEqual(unwrapOr(Some(value = "a"), "x"), "a", "Some(a)")
  assertEqual(unwrapOr(Some(value = "b"), "x"), "b", "Some(b)")
}

// ── Impl-method call sites: exercises the Phase-2 IImpl rewrite plus
//    self-typing and List/Map index inference feeding the generic call. ───────

record Bag {
  opts: List[Option[String]]
}

interface Reader {
  func firstOr(b: in Bag, fallback: in String): String
}

record BagReader {}

impl Reader for BagReader {
  // `b.opts[0]` is `Option[String]` (List index inference + `self`-free member
  // projection on the parameter `b`); `unwrapOr` must specialise to
  // `unwrapOr__String` so its `String` return is concrete and this method's
  // own `match`-free return type checks.
  func firstOr(b: in Bag, fallback: in String): String {
    if b.opts.count > 0 {
      unwrapOr(b.opts[0], fallback)
    } else {
      fallback
    }
  }
}

test "impl method specialises unwrapOr on a List[Option[String]] field" {
  val opts: List[Option[String]] = newList()
  opts.add(Some(value = "present"))
  val bag = Bag(opts = opts)
  val r: Reader = BagReader()
  assertEqual(r.firstOr(bag, "missing"), "present", "firstOr -> Some payload")
}

// ── ESelf inference path ─────────────────────────────────────────────────────
//
// The previous impl test projects through a *named parameter* `b.opts`, which
// resolves via the regular field-projection arm in `inferExprTE`.  This case
// reaches the generic call through `self.store.items[i]` instead, exercising
// the `ESelf -> mapGet(env, "self")` branch that PR #1753 added specifically
// for this pattern.

record Store { items: List[Option[String]] }

interface Lookup {
  func first(fallback: in String): String
}

record StoreImpl { store: Store }

impl Lookup for StoreImpl {
  func first(fallback: in String): String {
    if self.store.items.count > 0 {
      unwrapOr(self.store.items[0], fallback)
    } else {
      fallback
    }
  }
}

test "impl method specialises unwrapOr via self.field projection" {
  val items: List[Option[String]] = newList()
  items.add(Some(value = "found"))
  val store = Store(items = items)
  val l: Lookup = StoreImpl(store = store)
  assertEqual(l.first("absent"), "found", "self.store.items[0] -> Some payload")
  // None arm of the same specialisation: the impl method returns the fallback
  // when `items[0]` is None, exercising the None branch of unwrapOr__String.
  val items2: List[Option[String]] = newList()
  items2.add(None)
  val store2 = Store(items = items2)
  val l2: Lookup = StoreImpl(store = store2)
  assertEqual(l2.first("missing"), "missing", "self.store.items[0] -> None -> fallback")
}
