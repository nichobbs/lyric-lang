# Native: a default expression of an imported package binds that package's names (#8850)

A parameter default is lowered in the calling package but means the names of the package
that declares it. The JVM already wrote each default's bare calls as the declaring
package's qualified path (`pipeCheckedDefaults`); native did not, so an imported
`pub func scaled(x, k = factor())` whose `factor` the declaring package alone imports
bound to the caller's own `factor` (the call printed `2000` where `20` was right).
The native bridge now applies `Lyric.Pipeline.qualifyDefaultCallees` to each own
package's checked file with that package's callee sites. `llvm_project_self_test.l` pins
it with an exact assertion (`20`; a first draft that matched `"20"` as a substring also
accepted `2000`). Recorded as D336 item 12.
