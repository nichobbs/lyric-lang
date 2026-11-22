# Checker kinds the TIR gate stopped (D742-D745)

An open receiver is typed from the method's arguments (D742), a bare `T` argument after a container fixed `T` keeps the binding (D743), an explicit value-generic callee is recorded (D744) and a package-qualified distinct factory is typed (D745). Self-tests: `open_receiver`, `await_hoist_typed`, `stdlib_generic_iface`, `fixed_array`, `distinct_ops`.
