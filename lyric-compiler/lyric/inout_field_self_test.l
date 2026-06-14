//! Regression test: an `inout`/`out` argument may be a field access
//! (`obj.field`), not just a bare local or parameter.
//! Run in CI via native `lyric test`; imports only `Std.*`.
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

test "inout argument that is a field access mutates through" {
  var ctx = Ctx(c = Counter(n = 0))
  bump(ctx.c)
  bump(ctx.c)
  bump(ctx.c)
  assertEqualInt(ctx.c.n, 3, "field-access inout mutated through three times")
}

test "out argument that is a field access is written through" {
  var h = Holder(value = 0)
  setTo(h.value, 42)
  assertEqualInt(h.value, 42, "field-access out written through")
}
