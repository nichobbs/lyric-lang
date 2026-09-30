# Module values, field defaults and parameter defaults are type-checked (#7811)

An annotated module-level `val`'s initialiser, a record, exposed-record or
opaque field's default, a protected type's field initialiser, and a
parameter's default (functions, record and protected members, interface
members, `impl` methods) were never checked against their declared type. A
module `val` read resolved only its declared type, and a default was only
counted (`hasDefault`) when a call omitted the argument, so the initialiser
itself was never inferred at all:

```lyric
val g: Long = "str"                 // compiled; printing g printed a pointer
record R { v: Long = "str" }        // compiled
func d(x: in Long = "s"): Unit {}   // compiled
```

Because the initialiser was never inferred, no implicit widening was
recorded there either, so the #7805 zero-extension never reached these
positions: `val gl: ULong = someUInt` printed `-294967296` on both targets,
and a `ULong` parameter defaulting to a `UInt` module value came out as
`-294967296` on dotnet and `18446744073414584320` on the JVM.

The type checker now checks each declared initialiser like an annotated local
binding's (`checkDeclaredInit`, `typechecker_checker.l`): inferred against the
declared type with `inferExprExpected`, `T0060` on a mismatch (naming the
position: `val binding declared as Long but initialiser has type String`,
`field 'R.v' declared as Long but its default has type String`, `parameter
'x' of 'd' declared as Long but its default has type String`), `T0015` for an
out-of-range integer literal, the inline-range bound check, and
`recordUnsignedWidening` for the conversion site. It runs once per item in
the T5 body-check pass, under the declaring package's scope, in an empty
local scope: a default sees the package's module-level names but not the
other parameters. A module `val` read still resolves only the declared type,
so an initialiser's diagnostics are reported once, at the declaration. A
`config { }` field default was already held to a literal of the field's type
(`G0010`) and is unchanged.

`Lyric.Mono.desugarCheckedFile` now rewrites parameter defaults (functions,
`impl` and interface members, including body-less interface signatures),
record and exposed-record field defaults and in-body methods, opaque field
defaults, and protected fields, entries and functions, so each recorded
widening becomes an explicit `.toULong()` in the declaration. Both backends
splice a default into every call that omits the argument, so every such call
widens correctly. Walking record in-body methods also fixes a #7805 gap: a
widening inside a record's own method (`val x: ULong = u` in `func
widen(self: in W, u: in UInt)`) was recorded but never rewritten, so it still
sign-extended.

On the JVM the bundle registers each package's function signatures and
record fields from its raw parsed file, before that package's middle end
runs, and a call or construction that omits a defaulted argument lowers the
registered default. Codegen now points a package's own registered defaults
at its middle-ended declarations before generating its code
(`refreshOwnDefaultsJvm`), and because the entry package's code is generated
before any bundled package's middle end, each bundled package that declares
a default is checked and desugared up front (`Lyric.Pipeline.
pipeCheckedDefaults`) so a call from another package splices the converted
default too. The MSIL bridge already generated code from middle-ended files.

Two places the new check had to learn about:

- `@asyncLocal val slot: AsyncLocal[T] = ()` (`Std.Task`'s ambient
  cancellation slot): the `()` is a placeholder the backend replaces with a
  constructed `AsyncLocal`, as it supplies an `@externTarget` function's
  body, so an `@asyncLocal` value's initialiser is not checked.
- A restored package's synthesised contract surface is re-checked without
  that package's imports (`checkContractSurface`), so a default such as
  `= None` did not resolve there; the surface's initialisers were checked
  when the package was built, so the contract-surface check skips them, as
  it already skips declaration-position type validation.

No existing stdlib, compiler or ecosystem declaration had a mismatched
initialiser.

Coverage: `typechecker_self_test.l` pins T0060 at each position (module
`val`, record / exposed-record / opaque / protected fields, function, record
method, interface and `impl` parameters), the single report per declaration,
T0015 and T0020 inside an initialiser, and the conversion sites recorded for
widening initialisers. `unsigned_widen_self_test.l` (dotnet and JVM, already
in CI) now checks module values, field defaults (record, exposed record,
protected), parameter defaults and a record method's binding at runtime with
values of at least 2^31, plus the signed chain.
`msil_project_bridge_self_test.l` and `jvm_cross_package_collision_self_test.l`
check a parameter default and a field default used from another package.

Follow-up: calling a record in-body method or an `impl` method with a
defaulted argument omitted (`a.add()` for `func add(self: in Acc, x: in Int
= 5)`) fails at run time on dotnet (`InvalidProgramException`) and at compile
time on the JVM (`J008` stackmap underflow), independently of this change;
the runtime test therefore covers defaults on free functions only.
