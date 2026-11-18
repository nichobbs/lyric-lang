# docs/70 phase 3a: `typeHasUnsolved` matches `TyError` by its payload (D455)

`case TyError -> true` was a variable pattern that matched every type, so `typeHasUnsolved` always returned true and was counted as a bare name the checker did not bind (I0002). It now matches `TyError(_)`.
