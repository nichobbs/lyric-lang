# Checker: a member read on a List, Map or Set is T0113 (2026-11-10)

A field-style read such as `xs.size` on a `List`, `Map` or `Set` now reports T0113 ("no member 'size' on
type 'List'; a List has only the members ...") like the method-call form, instead of checking silently
(#8930). Dot-named and UFCS functions still bind. Covered in `typechecker_self_test.l`. A test for two
packages' unions sharing a case name on MSIL and JVM (#8481) is added to `emitter_project_self_test.l`.
