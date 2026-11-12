# 2026-11-12 - TIR: opaque type fields (D592)

A field of an opaque type reads in its own package: `typeEntries` and `fieldRefOf` cover `OMField` members. Two tests
added to `tir_build_self_test.l` (a plain and a generic opaque type), one for a `Float` host parameter; the host overload
score now ranks an integer-to-float widening below the language's own (D600 follow-up).
