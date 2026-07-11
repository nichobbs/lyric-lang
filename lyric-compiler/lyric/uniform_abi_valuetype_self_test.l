//! uniform_abi_valuetype_self_test.l — regression test for #5196: MSIL
//! backend paths that read/compare an extern value type (e.g. `System.Guid`,
//! backing `Std.Uuid.Uuid`) through an erased `object` slot missed box/unbox
//! (`Msil.Codegen.isValueType` matched only the six primitives;
//! `MValueTypeRef`/`MValueTypeGenericInst` fell through to "not a value
//! type"). Fixed by widening `isValueType` (and the matching `boxTypeRef`/
//! `coerceCallArgMsil` cases) to cover both extern-struct shapes, bringing
//! every box/unbox decision keyed on it (~30 call sites: comparisons,
//! `materializeBoxedElemMsil` for `List[T]` element reads, `castObjectToMsil`
//! for `Map[K,V]` value reads, compound assignment, …) into agreement with
//! `isValueTypeReceiverMsil` (which already handled both shapes for the
//! receiver/`call`-vs-`callvirt` decision).
//!
//! `match` directly on a restored function's `Option[Uuid]` result (a
//! non-generic-call codegen path — no monomorphization or box/unbox
//! involved) is covered here as a baseline; `isSome`/`isNone` themselves hit
//! an unrelated `Lyric.TestSynth` interaction inside a `@test_module`
//! (verified independently outside a test module) and are left uncovered
//! here rather than papering over that separate issue.
//!
//! NOT covered here: `unwrapOr(parseUuidOpt(...), nilUuid())` — the exact
//! #5196 repro shape — remains broken. That call never reaches any of the
//! box/unbox sites this fix touches: `Std.Core.unwrapOr` has no compiled
//! non-generic fallback (it is always monomorphized from source via
//! `Lyric.Mono`), and Mono's type-argument inference only reads literals and
//! explicitly-annotated locals, not a bare call expression passed inline as
//! an argument — so `T` is never inferred and the call is never emitted at
//! all (confirmed via `ilspycmd`/`ilverify`: the emitted IL has no `call` to
//! `unwrapOr` whatsoever, just the leftover args). That gap is in
//! `lyric-compiler/lyric/mono.l`, outside the MSIL backend this file
//! exercises; see `lyric-stdlib/tests/uuid_tests.l`'s header comment for the
//! full writeup and the annotated-local workaround
//! (`testParseRoundTripUnwrapOr`) that lets Mono infer `T = Uuid` and
//! monomorphize successfully.
//!
//!   lyric test lyric-compiler/lyric/uniform_abi_valuetype_self_test.l
@test_module
package Lyric.UniformAbiValueTypeSelfTest

import Std.Core
import Std.Collections
import Std.Uuid
import Std.Testing

test "#5196: match on a restored-returned Some Option[Uuid] (extern value-type T)" {
  val parsed = parseUuidOpt("550e8400-e29b-41d4-a716-446655440000")
  match parsed {
    case Some(u) -> assertEqual(uuidToString(u), "550e8400-e29b-41d4-a716-446655440000", "parseUuidOpt should return the parsed Uuid")
    case None -> assertTrue(false, "parseUuidOpt should return Some for valid input")
  }
}

test "#5196: match on a restored-returned None Option[Uuid] (extern value-type T)" {
  val rejected = parseUuidOpt("not-a-uuid")
  match rejected {
    case Some(_) -> assertTrue(false, "parseUuidOpt should return None for invalid input")
    case None -> assertTrue(true, "parseUuidOpt correctly returned None for invalid input")
  }
}

test "#5196: List[Uuid] add/index round-trips without corruption" {
  val u = newUuid()
  val s = uuidToString(u)
  val xs: List[Uuid] = newList()
  xs.add(u)
  val first = xs[0]
  assertEqual(uuidToString(first), s, "List[Uuid] element read must unbox the extern struct, not stay a raw object")
}

test "#5196: Map[String, Uuid] add/index round-trips without corruption" {
  val u = newUuid()
  val s = uuidToString(u)
  val m: Map[String, Uuid] = newMap()
  m.add("key", u)
  val got = m["key"]
  assertEqual(uuidToString(got), s, "Map[String, Uuid] value read must unbox the extern struct, not stay a raw object")
}

test "#5196: unwrapOr on a monomorphizable Option[Uuid] (annotated default) still works" {
  // Mirrors uuid_tests.l's testParseRoundTripUnwrapOr: an explicitly-typed
  // intermediate lets Mono infer T = Uuid and monomorphize `unwrapOr`
  // (see the header comment for why the bare inline-call form does not).
  val parsed = parseUuidOpt("550e8400-e29b-41d4-a716-446655440000")
  val default_: Uuid = nilUuid()
  val u = unwrapOr(parsed, default_)
  assertEqual(
    uuidToString(u),
    "550e8400-e29b-41d4-a716-446655440000",
    "unwrapOr should return the parsed Uuid unchanged"
  )
}
