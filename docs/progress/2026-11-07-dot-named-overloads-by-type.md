# Dot-named overloads that both fit by argument count are chosen by type (#8880)

The checker picks among `Type.f` overloads by the argument types (D345), records
the site of a path-form call, and the JVM and MSIL backends lower the declaration
the site names by its own parameter count. Verified by `emitter_project_self_test.l`
on both backends.
