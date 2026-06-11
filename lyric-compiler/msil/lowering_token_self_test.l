//! lowering_token_self_test.l — unit tests for listTokensForLowering and
//! dictTokensForLowering cache-hit/miss logic (#2473).
//!
//! Creates a minimal `LoweringCtx` with the required open-generic TypeRefs
//! pre-seeded (matching what `newCodegenCtx` does), then calls
//! `listTokensForLowering` and `dictTokensForLowering` twice with the same
//! element type to verify the cache hit path is taken (same token values
//! returned).  A second call with a different element type verifies the miss
//! path allocates fresh tokens.
//!
//! Written as a plain `func main` program rather than `@test_module` because
//! importing `Msil.Lowering` (which imports `Msil.Kernel`) triggers the
//! `Msil.Kernel.ByteWriter` vs `Std.Stream.ByteWriter` name collision
//! that blocks `@test_module` compilation (#3085).
//!
//! Run via the F# bootstrap emitter (avoids #3085):
//!
//!   ./bin/lyric run lyric-compiler/msil/lowering_token_self_test.l
//!
//! Migration to native `lyric test` is blocked by #3085.
package Msil.LoweringTokenSelfTest

import Msil.Lowering
import Std.Core
import Std.Collections

func check(label: in String, ok: in Bool): Unit {
  if ok {
    println(label + "=true")
  } else {
    println(label + "=FAIL")
  }
}

// Seed the mandatory open-generic TypeRefs needed by listTokensForLowering /
// dictTokensForLowering (mirrors the newCodegenCtx seeding in codegen.l).
func seedCollectionTypeRefs(ctx: in LoweringCtx): Unit {
  val arRuntime = ctxAddAssemblyRef(ctx, "System.Runtime", 10, 0)
  val arCollections = ctxAddAssemblyRef(ctx, "System.Collections", 10, 0)
  ctxAddTypeRef(ctx, "System.Collections.Generic", "List`1", arCollections)
  ctxAddTypeRef(ctx, "System.Collections.Generic", "Dictionary`2", arCollections)
}

pub func main(): Int {
  val ctx = newLoweringCtx("Test", 1, 0)
  seedCollectionTypeRefs(ctx)

  // Test: listTokensForLowering cache hit returns same struct
  val lt1a = listTokensForLowering(ctx, MInt)
  val lt1b = listTokensForLowering(ctx, MInt)
  check("list_cache_hit_ctor", lt1a.ctor == lt1b.ctor)
  check("list_cache_hit_add", lt1a.add == lt1b.add)
  check("list_cache_hit_getitem", lt1a.getItem == lt1b.getItem)
  check("list_cache_hit_count", lt1a.getCount == lt1b.getCount)
  check("list_cache_hit_typespec", lt1a.typeSpec == lt1b.typeSpec)

  // Test: listTokensForLowering with different element type allocates fresh tokens
  val lt2 = listTokensForLowering(ctx, MString)
  check("list_cache_miss_different_typespec", lt1a.typeSpec != lt2.typeSpec)

  // Test: dictTokensForLowering cache hit returns same struct
  val dt1a = dictTokensForLowering(ctx, MString, MInt)
  val dt1b = dictTokensForLowering(ctx, MString, MInt)
  check("dict_cache_hit_ctor", dt1a.ctor == dt1b.ctor)
  check("dict_cache_hit_add", dt1a.add == dt1b.add)
  check("dict_cache_hit_containskey", dt1a.containsKey == dt1b.containsKey)
  check("dict_cache_hit_remove", dt1a.remove == dt1b.remove)
  check("dict_cache_hit_trygetvalue", dt1a.tryGetValue == dt1b.tryGetValue)
  check("dict_cache_hit_typespec", dt1a.typeSpec == dt1b.typeSpec)

  // Test: dictTokensForLowering with different key type allocates fresh tokens
  val dt2 = dictTokensForLowering(ctx, MInt, MString)
  check("dict_cache_miss_different_typespec", dt1a.typeSpec != dt2.typeSpec)

  0
}
