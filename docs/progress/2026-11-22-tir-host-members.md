# Host members the TIR gate stopped (D758, D759, D760)

Bitwise methods on a host enum, a property written as a call, writes to a static host property (compound too), the default value of a host struct and a generic overload beside a non-generic one build in the typed IR. Self-tests: `extern_enum_flags`, `import_extern`. Still open in `auto_ffi_self_test.l`: optional trailing host parameters, `Array.IndexOf`, `ValueTuple.Create`, a `Byte` constant read and a `UInt32` result (tracked on #8613).
