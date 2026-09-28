//! dot_named_mangle_owner_match_jvm_self_test.l — regression test for the
//! narrow false positive in JVM dot-named method-name mangling (#7501)
//! disambiguation.
//!
//! The mangling fix (D-progress-1020) must tell apart a dot-named function
//! that shares its package's shared host class (needs the `TypeName$member`
//! mangle to avoid colliding with another same-named member) from a
//! synthesised PER-TYPE static that already lives on its own dedicated class
//! (a distinct/range-subtype's `from`/`tryFrom`, a wire factory's accessor —
//! never mangled). An earlier version of this fix told the two apart at each
//! CALL SITE by comparing the resolved signature's owner class (or its
//! simple name) against the receiver's own type name / the call's package
//! prefix. That comparison is exact for a package-qualified call, but for
//! the single-segment unqualified form (`Widget.make()`, no package prefix
//! in the call syntax) it degenerates to comparing `jvmSimpleName(sig.owner)`
//! against the receiver's type name — which is WRONG whenever a package's
//! own last dotted path segment happens to be spelled the same as a type it
//! declares: a plain dot-named function on the shared package class then
//! looks, by that comparison alone, indistinguishable from a per-type
//! static, and the call site wrongly skips the mangle.
//!
//! This package is deliberately named `P.Widget` — its JVM host class is
//! `P/Widget`, whose OWN simple name is `Widget`, exactly matching the
//! `Widget` record declared inside it. Before the fix (or under the
//! rejected owner-comparison heuristic), `Widget.make(...)`'s classfile name
//! would have wrongly stayed the bare `make` (mistaken for a per-type
//! static's own class), colliding with the unrelated free function `make()`
//! also declared here — both would land as `P/Widget.make` with the SAME
//! descriptor, `java.lang.ClassFormatError: Duplicate method name` at
//! class-load. The shipped fix stores the exact classfile name at
//! REGISTRATION time (`JvmFuncSig.jvmMethodName`) instead of guessing it at
//! the call site from owner/receiver-name comparisons, so it mangles
//! `Widget.make` into `Widget$make` regardless of the package/type name
//! coincidence, and the free `make()` keeps its own bare name — no
//! collision, both independently callable with the right values.
//!
//! A genuine per-type static (`Age.tryFrom(...)`, a distinct type's own
//! synthesised conversion) is exercised alongside it in the SAME package, to
//! confirm it still resolves correctly and un-mangled (its own class,
//! `P/Widget/Age`, is a real per-type class — not a false positive).
//!
//! Run in CI via the native `lyric test --target jvm`. Imports only
//! `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l
@test_module
package P.Widget

import Std.Core
import Std.Testing

record Widget {
  id: Int
}

func Widget.make(id: in Int): Widget {
  Widget(id = id)
}

// Unrelated free function sharing the exact bare name `Widget.make`'s
// classfile method name would have wrongly kept under the rejected
// owner-comparison heuristic — the collision this test pins.
func make(): Int {
  99
}

type Age = Int range 0 ..= 150

test "Widget.make and the unrelated free make() both compile and run (#7501)" {
  val w = Widget.make(5)
  assertEqualInt(w.id, 5, "Widget.make(5).id == 5")
  assertEqualInt(make(), 99, "the unrelated free make() still resolves to its own body")
}

test "a genuine per-type static (Age.tryFrom) in the same package still resolves" {
  match Age.tryFrom(42) {
    case Ok(a) -> assertEqualInt(a.value, 42, "Age.tryFrom(42) yields Age(42)")
    case Err(e) -> assertTrue(false, "Age.tryFrom(42) unexpectedly failed: " + e)
  }
  match Age.tryFrom(200) {
    case Ok(_) -> assertTrue(false, "Age.tryFrom(200) should have been rejected (out of range)")
    case Err(_) -> assertTrue(true, "Age.tryFrom(200) correctly rejected")
  }
}
