# TIR builder: a primitive binary operator's operands have one type

docs/70 phase 3c (#8613). The native via-TIR census found `SCALE + 1` (`val SCALE: Long`) and `Float`
against `Double` operands reaching TIR as an intrinsic call over two different primitive types, which the
native lowering refuses ("an operator on operands of different types (Long, Int)").

The checker accepts a literal or narrower numeric operand where the other operand is wider. The builder's
primitive binary-operator arm now passes the operands through `unifyPrimOperands`: the right operand is
converted to the left's type when that is a lossless conversion, otherwise the left to the right's, and the
conversion is explicit (`CvWiden`, or a retyped literal), so a backend never sees two types. Operands of one
type, or that do not convert, stay as built. Covered by two cases in `tir_build_self_test.l` (a `Long` and an
`Int` literal; a `Double` compared with a `Float`).
