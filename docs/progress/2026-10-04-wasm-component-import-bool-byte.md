# wasm32 component: Bool and Byte host imports (docs/35 W4 follow-up)

A `@wasmImport` extern in the component shape may use `Bool` and `Byte` parameters and results
(D-progress-1044). Test: a component whose imports negate a `Bool` and increment a `Byte`
(wrapping at 255), run through `jco` under node. Records across imports remain open (#8117).
