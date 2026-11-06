# Logical shr for UInt/ULong, and the JVM unix-socket HTTP test in CI (2026-11-06)

- `.shr` on a `UInt` or `ULong` receiver now shifts logically (docs/01 section 5) on `--target dotnet`
  (`MShrUn`) and `--target jvm` (`IUSHR`/`LUSHR`), selected by `spellsUnsigned` on the receiver the type
  checker already marks (`recordUnsignedOperand`). Signed receivers stay arithmetic. Native was fixed
  in D308 (#8707). Covered by `unsigned_typed_ops_self_test.l` on both targets (#8708).
- `lyric-stdlib/tests/http_unix_socket_jvm_tests.l` compiles again (its `addArg[T]` helper is retyped
  now that type parameters are rigid) and runs in the JVM test job, so the JVM unix-socket HTTP client
  has CI coverage (#8816).
