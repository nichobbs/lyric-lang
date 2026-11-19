# docs/70 phase 3a: a `match` whose arms all diverge is `Never` (D348)

The checker typed a `match` of only diverging arms as a silent `TyError`; it is `Never`, as an `if` of diverging branches is, so a `Unit` function ending in one builds as TIR (`Msil.Codegen::panicExternSetterUnresolved`).
