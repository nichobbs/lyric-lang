# D887 - `T.default()` at a record, a distinct type or `String` is the zero value as ordinary nodes on TIR

**Status:** accepted, implemented in the TIR model, builder and monomorphiser (docs/70 phase 3c, §6.2, §7.2; found by the native-via-TIR census, phase 4a; mirrors #8531's AST rewrite)

## Decision

1. **The model records what a zero needs.** `TFieldSig.dflt: Option[TLit]` is a record field's declared default when it is a literal of the field's own scalar kind (`n: Int = 7`); a default that is any other expression is not recorded. `TSymEntry.isRecord` marks the entry of a record or exposed record (an opaque or protected type carries `fields` too and is not constructed from them). The entry of a distinct type carries its underlying type in `ty`. Both new fields have defaults, so no construction site changes; they are not yet written to a package interface (docs/70 phase 5).
2. **Mono writes the zero.** An `IoBuiltin("default")` node that was typed by a type parameter (`T.default()` under `where T: Default`) and whose type argument is, after substitution: a `String` is `""`; a distinct type `X` is `XConvert(CvWrapDistinct X, zero of the underlying type)`; a non-generic record is `XConstruct(R, fields)` with each field at its literal default, else its own zero, recursively (a scalar field is its literal zero, `""`, `false`, `'\0'`). Any other type argument (a scalar, a generic record instance, a union, a collection, an extern type), and a record with a field whose zero is not one of those, keeps the built-in. A bare `default()` that is not typed by a parameter (an `out` placeholder) is untouched.
3. The rewrite applies to a record declared in a package of the build; one read from a package interface has no `isRecord` and keeps the built-in until phase 5 writes the new fields.

## Effect

`generic_default_named_self_test.l` on `--target native` lowers every function from TIR with no "zero value" fallback (it passed 3/3 via TIR). `tir_mono_self_test.l` covers a record with a literal default, a distinct type and a `String`, and that only the `Int` specialisation keeps the built-in.
