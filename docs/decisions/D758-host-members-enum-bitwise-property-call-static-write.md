# Host members the checker leaves untyped: enum bitwise methods, property call forms, static writes (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder.

## Context

Three forms on a host value the checker leaves unchecked (docs/01 section 2.11) had no builder case, so the TIR gate (D347) stopped them (`extern_enum_flags_self_test.l`, `import_extern_self_test.l`):
- `KeyStorageFlags.UserKeySet.or(KeyStorageFlags.Exportable)`: the bitwise methods (`and`, `or`, `xor`, `shl`, `shr`) on a host enum value;
- `sb.Length()`, `Encoding.UTF8()`, `ts.TotalSeconds()`: a property written as a call;
- `Environment.ExitCode = 42` and `Environment.ExitCode += 1`: a write to a static property of a host class.

## Decision

- A bitwise method on a receiver of a host type that declares no member of that name taking one argument is the built-in `hostEnum.<name>` and has the receiver's type; a real host method of that name (`BigInteger.or`) stays an ordinary host call (`hostEnumBitwiseRecv`).
- `recv.name()` where the host type has no method of that name with no arguments but has a property or field of it is the read of that member (`hostPropertyCallForm`), for a value and for the class named by an `extern type`.
- `Host.name = value` writes the static setter or public static field (`HMPropertySet` / `HMFieldSet`, `isStatic`), and `Host.name op= value` reads, applies the operator and writes (`buildHostStaticSet`); the assignment is `Unit`.

## Results

`extern_enum_flags_self_test.l` 6 of 6 and `import_extern_self_test.l` 22 of 22.
