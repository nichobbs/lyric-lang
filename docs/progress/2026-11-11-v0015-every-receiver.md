# V0015 for a write to a non-var field through every receiver (D577, #9008)

The type checker now rejects a plain or compound assignment to a field not declared `var` through any receiver it can resolve to a
record: a `val`/`let` local, an `in` parameter, a field chain, `self`, a record of another file or package. Before, V0015 covered only
same-file `var` locals, `inout` parameters and `self`, and the rest compiled while the typed IR verifier rejected it. Six reject-corpus
cases and a runtime accept test (`field_write_self_test.l`) pin the rule; docs/01 §2.4 and the book's records chapter describe it.
The mode checker's V0015 pass and the `initonly`/`ACC_FINAL` audit are unchanged. Closes #9008.
