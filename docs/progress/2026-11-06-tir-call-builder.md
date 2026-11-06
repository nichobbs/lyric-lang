# 2026-11-06 - The call builder (D367)

`buildCall` builds built-in calls (`IoBuiltin`), calls through function values
(`Callee.Indirect`) and calls to declared non-generic functions with their
arguments in parameter order and implicit widenings made explicit
(`XConvert(CvWiden)`), reading the new `SymbolTable.callSigByNode`. Over the
stdlib tests the builder now builds 242 of 1148 function bodies (20 before);
names that are not locals, `match`, method and constructor calls and generic
calls lead the rest. `tir_build_self_test.l` has 23 cases.
