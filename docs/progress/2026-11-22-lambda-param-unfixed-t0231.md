# T0231: a lambda parameter nothing fixes (D757)

`val f = { x -> false }` is a checker error; annotate the parameter or the binding. Docs: docs/01 5.4, book chapter 4 and appendix B. Tests: `typechecker_self_test.l`, `func_val_local_rettype_self_test.l`, reject corpus `lambda_param_unfixed`.
