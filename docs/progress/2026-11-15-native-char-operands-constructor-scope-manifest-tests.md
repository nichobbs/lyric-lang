# Native: stringified `Char` operands from the type checker, constructors resolved by package scope, `lyric test --manifest --target native` (#9089, #9088, #6815 item 3(b))

Three gaps that kept ecosystem HTTP backends off `--target native`.

## `String + Char` whatever bound the `Char` (#9089, D606)

`"" + c` with `c` bound by `case Some(c)` failed native codegen ("mixed
String/non-String operands"), so `import Std.Xml` did not build on native.
`Char` and `Int` both lower to `i32` there and the backend keeps no static
types; it told a `Char` from an `Int` by the operand's shape (a literal, an
annotated local), so a `Char` bound by a pattern, a tuple, a `for`, an inferred
lambda parameter, a generic field or a `Map` lookup was rejected at `String +`
and printed as its code point by `.toString()` and interpolation, and
`String + <Int>` was rejected outright.

- `Lyric.TypeChecker.recordCharOperand`: for a native check
  (`SymbolTable.markCharOperands`), each stringified operand whose checked type
  is `Char` is recorded in `argConversionSites` as the identity `.toChar()`,
  at the positions structural `toString` already records (`recordShowOperand`:
  `String` `+` and `+=`, `toString(x)`/`println`/`print`/`formatN` arguments, a
  `.toString()` receiver, an interpolated segment). `Lyric.Mono.desugarCheckedFile`
  spells it, and the native backend already reads `.toChar()` as a `Char`.
  Nothing is recorded for dotnet or the JVM.
- `Lyric.Mono` reports each specialisation whose type arguments mention `Char`
  (`MonoResult.charSpecs`); a native build re-checks those that may stringify
  a value, so an operand typed by a type parameter bound to `Char` is marked
  too (the mechanism of #7842).
- A bundled standard library package is checked but not desugared on native;
  `Lyric.Pipeline.lowerCharOperandSites` applies the `Char` marks to it, and a
  package with one is not stored in the stdlib check cache (#7971).
- `Lyric.LlvmCodegen.concatOperand`: `String + x` and `s += x` stringify any
  scalar, an `Int` included; `s += <scalar>` on a variable or a field did not
  lower at all before.
- Not covered: a generic function of another package that native instantiates
  itself is keyed by erased types, so one instantiation serves `Int` and
  `Char`. `String + x` on an `i32` there stays a compile-time error, with a
  message that says why; `.toString()` in such a function renders a `Char` as
  its code point, as before (#9131).

`string_concat_operand_self_test.l` (13 cases: every binding form, every scalar
operand type, `Std.Xml`'s entity decoder) passes on dotnet, the JVM and native.

## Constructors resolved by package scope (#9088)

A native project build resolved a constructor call one registry at a time
(record, then union case, ...), each with a bundle-wide first-registered-wins
bare key. `Held(freed = n)`, a union case of the package being lowered, was
built as the record `Held` of a package it does not import ("missing field
'since' constructing record"). `tryLowerConstruct` now resolves the name one
scope at a time, as the type checker does: the calling package's own
declaration of any kind, then an imported package's, then the key as written.
A function or generic function of a package further away no longer captures a
nearer constructor of the same name (`constructorScopeLevel`), and a generic
union case is keyed by `<pkg>.<Case>` like a plain one. The MSIL and JVM
backends still fail on the same collisions at run time (#9130).

`llvm_project_self_test.l` gains three tests: the reported shape, and two
packages that reuse each other's names for another kind of declaration (case
and record, case and function, records of two layouts, cases of two unions,
generic case and record, generic record and case, enum cases at other
ordinals, distinct type and case), built in every package order, called
qualified and bare.

While writing them: the same two-package program fails on dotnet
(`InvalidProgramException` in the package that declares the union) and on the
JVM (`VerifyError`); those backends are not changed here.

## `lyric test --manifest --target native` (#6815 item 3(b), D607)

The command was refused. `cmdTestManifest` now takes the target: for native it
collects the project's packages as before, compiles path and workspace
dependencies from source (`collectTransitiveDepSources`, as `lyric build`
does), and for each `[project.tests]` entry builds one executable with
`Emitter.emitNativeProject` and runs it. Header, TAP, summary, exit code,
`--filter`, `--suite`, `--fail-fast`, `--doctests`, the feature flags, file-level
`@cfg` gating, the merge of a test module into a `[project.packages]` package
and `F0054` are the shared code of the other targets. `lyric test --target
native` with no file discovers the manifest. A native test binary that stops
before its summary (a failed assertion aborts it) gets `not ok <n> - <title>`
for the test it stopped in and a count of the tests that did not run, in the
single-file form too.

`scripts/ci/native-manifest-test-e2e.sh` covers a workspace member with a
workspace and a path dependency (from the root and from the member's
directory), a merged test module, `@cfg` gating and `--features`, `--filter`,
a failing entry, `--fail-fast`, `[package] targets` and a registry dependency.
`lyric-ecosystem`'s `net` (31 tests), `aws-sigv4` (25) and `redis` (78, two
integration modules gated) run with it and match the script that emulated it.
