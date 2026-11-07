# Native: a default expression of an imported package binds that package's names (#8850)

`llvm_project_self_test.l` has a project whose imported package declares
`pub func scaled(x, k = factor())` with `factor` imported from a third package the
caller does not import, while the caller declares its own different `factor`. Native
prints the product with the declaring package's `factor`: the checker's callee site
(D336 item 11, `sitedSig`) binds the default's call in the declaring package, so the JVM's
`pipeCheckedDefaults` qualification does not need porting. No compiler change; the test
pins the behaviour.
