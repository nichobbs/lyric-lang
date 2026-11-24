# Checker: a method call on a Result or Option naming a plain function is typed as that call (D785)

`r.f()` for a plain `func f(r: in Result[..])` had no callee and no type (a silent `TyError`), which the gate reports as I0002 (`monad-unknown-member-negative-test.sh`). It now resolves to the plain function like a call on a primitive receiver.
