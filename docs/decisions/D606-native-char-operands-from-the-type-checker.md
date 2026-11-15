# D606 - On native, the type checker says which stringified operands are a `Char` (#9089)

**Status:** shipped.

## Context

`--target native` lowers `Char` and `Int` to the same `i32` and the code
generator keeps no static types (`Lyric.LlvmCodegen` works from the syntax tree
and the IR types of the values it has lowered). The text of `"" + c`,
`c.toString()`, `"${c}"` or `println(c)` depends on which of the two `c` is.
The backend answered from the operand's shape: a literal, a local or parameter
annotated `Char`, a field a record declares `Char`, a call of a function
declared to return `Char`. A `Char` bound by a pattern, a tuple, a `for`, an
inferred lambda parameter, a generic field or a collection lookup was not
recognised: `String +` rejected it (and therefore rejected every `Int` too, in
case it was a `Char`), and `.toString()` and interpolation printed its code
point. `Std.Xml` did not build on native.

`UInt`/`ULong` had the same problem against `Int`/`Long` and D-progress
entries for #7812 and #7842 solved it in the middle end: the type checker
records each operand whose lowering depends on signedness and
`Lyric.Mono.desugarCheckedFile` spells it as the identity `.toUInt()` /
`.toULong()`.

## Decision

1. `Char` operands are marked the same way. When the check is for native
   (`SymbolTable.markCharOperands`, set from the `nativeIntrinsics` flag the
   native bridge already passes), each stringified operand whose checked type
   is `Char` is recorded in `SymbolTable.argConversionSites` as the identity
   `.toChar()`. The positions are those of structural `toString`
   (`recordShowOperand`): both operands of a `String` `+`, the value of a
   `String` `+=`, the arguments of `toString`/`println`/`print`/`formatN`, a
   `.toString()` receiver, an interpolated segment. An operand that is a
   `Char` literal or already a `.toChar()` call is left alone.
2. Nothing is recorded for dotnet or the JVM, whose values carry their type.
   Their output is unchanged.
3. A specialisation whose type arguments mention `Char` is reported by
   `Lyric.Mono` (`MonoResult.charSpecs`); a native build re-checks those whose
   body may stringify a value, in the scope of the package that declares the
   generic, so an operand typed by a type parameter is marked where the
   parameter is `Char`. This is the re-check of #7842, with its M0007 when the
   specialisation does not check.
4. A bundled standard library package of a native build is type-checked but
   does not go through the middle end's desugar. It gets the `Char` marks alone
   (`Lyric.Pipeline.lowerCharOperandSites`); a package that has one is checked
   on every build, not served from the check cache (#7971), because a cache
   entry stands for "checked, nothing to lower".
5. With every `Char` marked, an unmarked `i32` operand of `String +` is an
   `Int` and is stringified as one, as on dotnet and the JVM. `s += x` does the
   same on a variable and on a field.
6. One case stays an error. A generic function of another package is
   instantiated by the native code generator itself, keyed by erased types, so
   one instantiation serves `Int` and `Char` arguments. Inside it an `i32`
   operand of `String +` is rejected with a message naming that cause, as it
   was rejected before, instead of being rendered as a number.

## Alternatives

- Extending the backend's own tracking to patterns, tuples, loops and lambdas
  one binding form at a time. Each form needs the type the checker already
  has, and the next unhandled form fails the same way.
- A distinct IR type for `Char`. It would also separate the instantiations of
  item 6, but it changes the layout tables, the C ABI classification and every
  `i32` match in the code generator; the TIR lowering (docs/70 phase 4) reads
  `Char` from `TExpr.ty` and makes it unnecessary.
- Marking on every target. The managed backends do not need it, and a
  `.toChar()` on a `Char` would add a range check to their output.

## Left open

Item 6: `.toString()`, interpolation and `println` of a value typed by a type
parameter in a generic of another package still render a `Char` as its code
point on native, and `String +` there is an error. Both end when native
generics are specialised by the middle end or lowered from TIR.
