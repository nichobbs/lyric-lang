# Checker: package- and alias-qualified callees record their callee (D688)

`Core.unwrapOr[Int](o, 5)` and `Buf.fromSlice(xs)` through `import Std.Buffer as Buf` record the function declared at the signature's span. Shape: `qualified_generic_and_alias_calls`.
