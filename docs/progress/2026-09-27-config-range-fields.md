# 2026-09-27 — Range fields in `config` blocks

D-progress-995, #7229.

A `config { }` field may now be a range of `Int`, `Long`, `Float` or
`Double` (`port: Int range 1 ..= 65535 = 8080`; also `lo ..< hi`, `lo ..`
and `..= hi`). Malformed ranges are G0009 and out-of-range defaults G0010.
On dotnet and the JVM an out-of-range env value, including `NaN`, stops
startup with exit 78 and a G0004 message naming the field, env var and
range. Aspect config blocks check their literal values against the same
ranges at compile time, including a `from`-instance override of a ranged
template field.
