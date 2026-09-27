# JVM: qualified type-associated calls, slice `toArray`, un-annotated slice bindings, literal `split` (#7478, #7480, #7524, #7362)

Four places where the JVM backend (`lyric-compiler/jvm/codegen/`) lowered an
expression without the static type the type checker gives it, so the next
call resolved against the wrong receiver and the build failed with J008, or
ran with the wrong result:

- **Package-qualified type-associated calls (#7478).**
  `Std.Http.Url.tryFrom(s)` and `Lyric.Docker.ContainerId.tryFrom(s)` parse
  as a member chain whose last receiver segment is a type.  Only a
  single-segment `Type.member(...)` receiver consulted the dot-named function
  registry, so the package prefix was lowered as a value ("reference 'Std'
  resolves to no local").  `qualifiedDotNamedSigJvm` (04_calls.l) resolves
  the receiver's package segments and type through the declaring package's
  own keys (`<pkg>/<Type>.<member>[@argc]` for a hand-written dot-named
  function, `<pkg>::<Type>.<member>` for a synthesized distinct/range
  `from`/`tryFrom`), and `scrutineeGenericArgs` uses the same lookup, so
  `case Ok(u)` over the result binds `u` to the real type.
- **`.toArray()` on a slice (#7480).**  A `slice[T]` is already an array; the
  call now yields the receiver, as MSIL does for an `MArray` receiver.  It
  had fallen to the "primitive-typed receiver" panic, whose message now
  names a slice receiver as such.
- **Un-annotated list-literal bindings (#7524).**  The checker types
  `val xs = [1, 2, 3]` as `slice[Int]`, but the local kept the literal's
  construction-time `ArrayList`, so `.append`/`.concat`/`.slice` reached
  `ArrayList` auto-FFI.  An un-annotated `val`/`let`/`var` bound to a list
  literal is now stored in the erased slice representation (`Object[]`),
  exactly as the annotated `val xs: slice[Int] = [...]` is; the element type
  is recorded from the literal as before.
- **Un-annotated `List[T].toArray()` bindings (#7362).**  `toArray` is a
  slice-builtin intrinsic like `.append`, so `scrutineeGenericArgs` now
  carries the receiver's element type to the result: `val bs = bl.toArray()`
  records `Byte`, and `bs[0].toInt()` resolves on `Byte` instead of
  `java.lang.Object`.

Getting lyric-generator-sdk to build on the JVM exposed a silent miscompile
behind these: `s.split(sep)` passed `sep` to `java.lang.String.split`, which
takes a regular expression and drops trailing empty parts, so
`"Std.Json".split(".")` returned no parts.  It is now lowered as
`sep.isEmpty() ? new String[] { s } : s.split(Pattern.quote(sep), -1)`,
the literal-separator contract of `Std.String.split` that dotnet routes
through (docs/01 §12.1).

#7479 (an interface unwrapped from `Result[Iface, E]` returned by a method on
a record field) already compiles and runs on `main`: the field-chain
receiver resolution added for #7337 (`receiverClassOf`'s `EMember` arm)
recovers the call's declared return instantiation.  Its repro is kept as a
regression case.

Regression test `lyric-compiler/jvm/static_type_recovery_jvm_self_test.l`
runs every case on both targets, wired into
`scripts/ci/jvm-generics-self-tests-batch.sh` (`--target jvm`) and
`scripts/ci/compiler-self-tests-batch.sh` (`--target dotnet`).

lyric-docker and lyric-generator-sdk now build on `--target jvm` (#7511
items 2 and 3).  lyric-generator-sdk passes all 75 cases there and joins
`scripts/ci/jvm-ecosystem-suites.sh`.  lyric-docker passes 91 of 96: the
five `tryMakeDockerClient`/`makeDockerClient` cases set `DOCKER_HOST` with
`Std.Environment.setVar`, a no-op on the JVM, and then reach
`Std.Http.clientWithUnixSocket`, which the JVM does not support (#2663), so
the suite stays out of JVM CI.
