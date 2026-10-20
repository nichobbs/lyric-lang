# Callback members of `foreign record` (docs/67 G5 prerequisite, #7944, D193)

- Checker: a function type with a `NativeUserdata` parameter and `NativeUserdata` itself are valid
  foreign fields; a construction takes closures for them (the `extern func` rule).
- Codegen: callback fields are pointer slots; construction stores the trampoline address, and a
  closure for a `void*` field is stored as its own pointer.
- bindgen: function-pointer members become callback fields.
- Tests: checker, bindgen, and a C round trip where C calls back through a struct under ASan.
- Docs: D193, language reference §11.6, book chapter 13.
