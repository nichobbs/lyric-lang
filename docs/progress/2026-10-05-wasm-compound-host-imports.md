# wasm32 component: compound values across host imports (docs/35 W4 follow-up)

`@wasmImport` externs may take and return records, enums, unions, `Option`, `Result`, `List`
and tuples (D-progress-1046). Test: a host module implementing swap/older/first/safe-div/
next-color/grow/note/tag/pair/many against records, options, lists, results, enums, a
variant joining f64/i64/i32/f32 slots, a string-and-record call, a tuple result and an
18-parameter spilled import, run through `jco` under node, plus repeated calls. Open in
#8117: cross-package types, `fetch`-backed `Std.Http`.
