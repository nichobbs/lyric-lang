# Generic calls from record and protected-type members, and mono gaps (#8271, #8370, #8301, #8280, #7531, #7161, #7210, #7162)

`Lyric.Mono` never rewrote the bodies of a record's in-body methods, so any
generic call in one dangled: T0123 on dotnet, a missing class on the JVM,
N0007 on native.  A record method calling `ident(self.v)` failed even in a
non-generic record.

- **Record method bodies are rewritten** like `impl` and interface-default
  bodies (`monoFile` phase 2, `IRecord` arm).
- **A call at a generic record's own type parameter** (`func echo(self: in
  Box[T]): T = ident(self.v)`, inferred `A = T`) cannot be a top-level
  specialisation, because `T` is in scope only inside the record.  The
  specialisation is added to the record as a `__spec_<Record>_<name>` method
  taking the receiver, and the call becomes `self.__spec_...(args)`
  (`memberSpecCallMono`).  Backends already reify the record's `T`, so no
  backend change is needed on dotnet or native.  The JVM registry of record
  method signatures is collected before the middle end, so
  `registerMonoMemberSigsJvm` registers these methods from the post-mono
  file; without it the call linked against the `()Object` guess.  The same
  path types `mapOption(o, { v: T -> 3 })` from a generic member (#8301) on
  dotnet and the JVM.
- **Generic protected types** were skipped by `Lyric.Mono` altogether; their
  members are now rewritten, and a call at the type's own parameter becomes a
  function of the protected type called by name from its entries and
  functions.
- **An enclosing type parameter as an explicit type argument** (#8280):
  `firstOf[T](...)` inside `func g[T]` no longer reports T0020 (the checker
  treats an in-scope type parameter as a type in an index), and specialising
  `g` turns `firstOf[T]` into a type application over the substituted types.
- **Protected-entry results type generic arguments** (#7531): `inferMethodReturnTE`
  resolves a protected type's entries and functions.
- **`EForall`/`EExists` in `substTypesExpr`** (#7161, #7210) substitute the
  binder types and recurse into `where`/body.
- **Enum, opaque and protected types as explicit type arguments** (#7162).

Verified by `mono_self_test.l`, `typechecker_self_test.l` and the new
`generic_member_calls_self_test.l` (dotnet, JVM and native) and
`generic_member_calls_std_self_test.l` (dotnet and JVM).

Not covered, tracked on the issues: method-level type parameters on record
methods whose argument is `inout` of a value type (#8241), `impl[T]` and
interface-default members at an enclosing parameter, and native's handling of
an imported generic called from a generic record's method.
