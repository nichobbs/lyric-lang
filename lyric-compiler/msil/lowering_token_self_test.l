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
//! Run in CI via native `lyric test`, linking the already-compiled compiler
//! DLLs as restored deps (the msil_self_test_m2a.l precedent; the #3085
//! short-name collision that previously blocked `@test_module` compilation
//! was fixed by codegen scope-tier resolution):
//!
//!   lyric test --target dotnet lyric-compiler/msil/lowering_token_self_test.l
@test_module
package Msil.LoweringTokenSelfTest

import Msil.Lowering
import Std.Core
import Std.Collections
import Std.Testing

// Seed the mandatory open-generic TypeRefs needed by listTokensForLowering /
// dictTokensForLowering (mirrors the newCodegenCtx seeding in codegen.l).
func seedCollectionTypeRefs(ctx: in LoweringCtx): Unit {
  val _ = ctxAddAssemblyRef(ctx, "System.Runtime", 10, 0)
  val arCollections = ctxAddAssemblyRef(ctx, "System.Collections", 10, 0)
  val _ = ctxAddTypeRef(ctx, "System.Collections.Generic", "List`1", arCollections)
  val _ = ctxAddTypeRef(ctx, "System.Collections.Generic", "Dictionary`2", arCollections)
}

test "listTokensForLowering cache hit returns same tokens" {
  val ctx = newLoweringCtx("Test", 1, 0)
  seedCollectionTypeRefs(ctx)
  val lt1a = listTokensForLowering(ctx, MInt)
  val lt1b = listTokensForLowering(ctx, MInt)
  assertEqualInt(lt1a.ctor, lt1b.ctor, "list_cache_hit_ctor")
  assertEqualInt(lt1a.add, lt1b.add, "list_cache_hit_add")
  assertEqualInt(lt1a.getItem, lt1b.getItem, "list_cache_hit_getitem")
  assertEqualInt(lt1a.getCount, lt1b.getCount, "list_cache_hit_count")
  assertEqualInt(lt1a.typeSpec, lt1b.typeSpec, "list_cache_hit_typespec")
}

test "listTokensForLowering miss allocates fresh tokens" {
  val ctx = newLoweringCtx("Test", 1, 0)
  seedCollectionTypeRefs(ctx)
  val lt1 = listTokensForLowering(ctx, MInt)
  val lt2 = listTokensForLowering(ctx, MString)
  assertTrue(lt1.typeSpec != lt2.typeSpec, "list_cache_miss_different_typespec")
}

test "dictTokensForLowering cache hit returns same tokens" {
  val ctx = newLoweringCtx("Test", 1, 0)
  seedCollectionTypeRefs(ctx)
  val dt1a = dictTokensForLowering(ctx, MString, MInt)
  val dt1b = dictTokensForLowering(ctx, MString, MInt)
  assertEqualInt(dt1a.ctor, dt1b.ctor, "dict_cache_hit_ctor")
  assertEqualInt(dt1a.add, dt1b.add, "dict_cache_hit_add")
  assertEqualInt(dt1a.containsKey, dt1b.containsKey, "dict_cache_hit_containskey")
  assertEqualInt(dt1a.remove, dt1b.remove, "dict_cache_hit_remove")
  assertEqualInt(dt1a.tryGetValue, dt1b.tryGetValue, "dict_cache_hit_trygetvalue")
  assertEqualInt(dt1a.typeSpec, dt1b.typeSpec, "dict_cache_hit_typespec")
}

test "dictTokensForLowering miss allocates fresh tokens" {
  val ctx = newLoweringCtx("Test", 1, 0)
  seedCollectionTypeRefs(ctx)
  val dt1 = dictTokensForLowering(ctx, MString, MInt)
  val dt2 = dictTokensForLowering(ctx, MInt, MString)
  assertTrue(dt1.typeSpec != dt2.typeSpec, "dict_cache_miss_different_typespec")
}
