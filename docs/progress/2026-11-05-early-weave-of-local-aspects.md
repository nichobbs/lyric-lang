# Aspects declared in the package are woven before the check (docs/70 phase 3b S2, D391)

`Weaver.weaveFileEarly` wraps the functions that only aspects of the package
being built match, before the type checker runs, so the wrappers and advice
bodies are checked like user code and the checker's callee sites cover the
calls the weaver synthesises. Functions a `from`-instance also matches stay for
the late weave; the outermost wrapper carries `@woven` so the elaborator and
the late weave leave it alone. See D391.
