# 2026-11-09 - TIR builder: package-qualified built-in calls (D551)

docs/70 phase 3a, #8613. `Console.println(x)` (package name, import alias or full path) is
recorded as the `println` built-in, as the checker already types it. Stdlib census: bodies
built 965 -> 967 of 1165, I0003 0, `a call the checker did not resolve` 24 -> 20.
