# wasm32 component: types from other project packages (docs/35 W4 follow-up)

Exports and host imports may name `pub` types of other packages of the project
(D-progress-1047). Test: four packages (a model, one importing it whole, one through an alias
with qualified union cases, one through a renamed selector) exporting records, a union, an enum,
lists and options of those types, run through `jco` under node; a negative case for a function
named like a type of its interface. The native backend now lowers package-qualified enum and
union-case chains (`Pkg.Enum.Case`). Open in #8117: `fetch`-backed `Std.Http`.
