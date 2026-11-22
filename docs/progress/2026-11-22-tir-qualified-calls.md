# Qualified calls and host array reads the TIR gate stopped (D749, D755, D756)

A call written through its own package's name resolves to the package's function (D749), a record shares its name with an enum case without losing its construction (D755) and a host array's `count` reads as its length (D756). Self-tests: `erased_receiver_jvm` (JVM), `auto_ffi`.
