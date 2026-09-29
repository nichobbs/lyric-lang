//! unannotated_list_result_self_test.l — runtime regression test for a value
//! whose runtime representation differs from the type the checker gives it
//! (#7755 review).
//!
//! `val seeds = newList()` has no type hint where it is constructed, so it is
//! built as the erased `List<object>` although the type checker types it
//! `List[Seed]` (from the `Result[List[Seed], String]` it is returned in).
//! The MSIL backend's consumer-side narrowing must not cast such a value to
//! `List<Seed>` — CLR generics are invariant, so the cast throws — and so
//! narrows only types with a single runtime representation
//! (`Msil.Codegen.narrowObjectToDeclaredTypeMsil`).  `lyric-proto`'s
//! `decodeMessage` (`Ok(value = fields)`) failed this way.  `sumSeeds` reads
//! the list the way `lyric-proto`'s `collectFixed32` does.
//!
//! The producer still stores the `List<object>` where the constructor
//! expects a `List<Seed>`, which is unverifiable IL, so this file is not in
//! `scripts/ilverify-selfhosted.sh`'s list; building the list with its
//! checked element type is a separate follow-up.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/unannotated_list_result_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/unannotated_list_result_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.UnannotatedListResultSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Seed {
  n: Int
}

func buildSeeds(): Result[List[Seed], String] {
  val seeds = newList()
  seeds.add(Seed(n = 1))
  seeds.add(Seed(n = 2))
  Ok(value = seeds)
}

func sumSeeds(seeds: in List[Seed]): Int {
  var t = 0
  val arr = seeds.toArray()
  for s in arr {
    t = t + s.n
  }
  t
}

test "an unannotated list returned inside a Result[List[Seed], String]" {
  match buildSeeds() {
    case Ok(seeds) -> assertEqualInt(sumSeeds(seeds), 3, "summed through a List[Seed] parameter")
    case Err(e) -> assertTrue(false, e)
  }
}
