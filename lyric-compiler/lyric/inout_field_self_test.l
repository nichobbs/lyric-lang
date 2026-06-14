//! inout_field_self_test.l — regression for #3547.
//!
//! An `inout`/`out` argument that is a field access (`obj.field`) is a valid
//! assignable l-value, but the MSIL backend used to panic in codegen
//! ("out/inout argument must be an assignable variable") because
//! `emitByrefArgMsil` only handled bare locals/parameters.  This models
//! lyric-testing's `Testing.advance(ctx.clock, …)` pattern: the receiver is
//! lowered, the field token resolved, and `ldflda` pushes the field's managed
//! pointer so the callee writes through to `obj.field`.
//!
//! Run in CI via native `lyric test` (compiles in-process through the
//! self-hosted `Msil.Bridge`).  Imports only `Std.*`.
@test_module
package InoutFieldSelfTest

import Std.Core
import Std.Testing

record Counter {
  var n: Int
}

record Ctx {
  var c: Counter
}

record Holder {
  var value: Int
}

func bump(x: inout Counter): Unit {
  x.n = x.n + 1
}

func setTo(o: out Int, v: in Int): Unit {
  o = v
}

test "inout argument that is a field access mutates through (#3547)" {
  var ctx = Ctx(c = Counter(n = 0))
  bump(ctx.c)
  bump(ctx.c)
  bump(ctx.c)
  assertEqualInt(ctx.c.n, 3, "field-access inout mutated through three times")
}

test "out argument that is a field access is written through (#3547)" {
  var h = Holder(value = 0)
  setTo(h.value, 42)
  assertEqualInt(h.value, 42, "field-access out written through")
}
