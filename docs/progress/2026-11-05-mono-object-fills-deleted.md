# Mono's Object fills in result-type inference are deleted (docs/70 phase 3a, D382)

`ctorFill` and `importedFill` filled an unpinned type argument with `Object`
when `Lyric.Mono` typed a call's result. The checker now reports every such
call and construction (T0224, D381), so both fills and the opacity tracking
behind `importedFill` are removed. See D382.
