# Float-to-integer conversions saturate on every target (D-progress-1052)

An out-of-range `Double` or `Float` converted with `.toInt()`, `.toLong()`, `.toByte()` or
`.toNat()` now saturates and NaN gives 0 on native, matching .NET and the JVM; native used a
plain `fptosi`, which is poison out of range (#8375). New tests pin the rule on all three
targets, the `Std.Http` client impl reached through an aliased or qualified constructor
call (#8376), and a guarded `match` arm whose value is a bare `None`.
