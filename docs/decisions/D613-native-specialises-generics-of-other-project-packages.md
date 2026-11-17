# D613 - Native specialises the generics of the project's other packages, so a `Char` type argument renders as a character (#9131)

**Status:** shipped. Completes D606 item 6.

## Context

D606 had the type checker mark each stringified `Char` operand for `--target
native`, where `Char` and `Int` are both `i32` and the code generator keeps no
static types. An operand typed by a type parameter is marked by re-checking the
specialisation that binds the parameter to `Char` (`MonoResult.charSpecs`). That
covers the generics `Lyric.Mono` specialises: the package being compiled's own.

A generic of another package was not handed to `Lyric.Mono` by the native
bridge (only the value-generic ones were, D167, D173). The code generator
instantiated it itself, keyed by erased types, so one instance served `Int` and
`Char`. Inside it `String + x` was rejected (N0007), and `x.toString()` and
`"${x}"` printed the code point of a `Char`. The dotnet and JVM targets
specialise these generics in the middle end, which is also what carries the
private helpers a generic reaches (#8427).

## Decision

1. The native project build hands `Lyric.Mono` the generic functions of the
   project's other packages (siblings and path or workspace dependencies, which
   a native build compiles from source) that may stringify a value or call one
   that does (`Lyric.Pipeline.pipeRenderingGenerics`), plus every value-generic
   function as before. The other generics are handed over for inference only
   (signature, no body), because `Lyric.Mono` infers a type argument inside a
   specialised body from less than the checker knows (a nested generic call's
   result, a pattern-bound variable) and an absent callee made that an M0004;
   they stay with the code generator, which has no use for the type argument's
   identity there. The union cases of every other package are declared to
   `Lyric.Mono` (`unionCtorInferenceDecls`) when something is specialised, as
   the other bridges do. Generics are read from the parsed files, so a private
   generic or non-generic helper a `pub` generic reaches travels with it under
   its package-unique `__priv_` name, as in the JVM bridge.
2. A call of such a generic is specialised at its type arguments like any
   other: `concatLeft[Char]` and `concatLeft[Int]` are two functions of the
   calling package, each checked in the scope of the package that declares the
   generic (`charSpecs`, D606 item 3). `String + x`, `x.toString()` and
   interpolation then render a `Char` as the character and an `Int` as its
   digits, as on dotnet and the JVM.
3. The bundled standard library is not handed over, as before (its
   value-generic functions only). Its generics keep going through the code
   generator's own instantiation, with the intrinsics the backend implements by
   name left alone.
4. The code generator's compile-time error for `String + x` where `x` is an
   `i32` inside a function it instantiated itself stays, and now says the
   function is a generic of the bundled standard library or a method of a
   generic record, which are the two cases that still reach it.

## Alternatives

- A distinct IR type for `Char` (D606's second alternative): it also separates
  the instances, but changes layout tables, C ABI classification and every
  `i32` match in the code generator. The TIR lowering (docs/70 phase 4) reads
  `Char` from `TExpr.ty` and makes it unnecessary.
- Handing over only the generics whose bodies may stringify a value. It leaves
  a generic that calls such a generic erased and needs a call-graph closure;
  specialising all of them is what the other targets do.
- Keying the code generator's instances by the checker's `Char`/`Int`
  distinction. The generic is checked once over its type parameters, so the
  distinction is not there to read.

## Left open

- Methods of a generic record (`record Box[T] { func label(self: in Box[T]) }`)
  are instantiated by the code generator on native and render a `Char` as its
  code point. The same program fails on dotnet with a `NullReferenceException`
  in `Box`1.label()`; both are separate defects, filed as follow-ups.
- A generic of the bundled standard library that stringifies a value of its
  type parameter. None of the standard library's generics does today.
