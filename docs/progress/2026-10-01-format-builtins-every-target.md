# `format1`-`format4` format identically on every target (#7840)

The `format1`-`format4` builtins disagreed across targets:

```lyric
format1("a={0}", 42)
// dotnet: "a=42"   jvm: "a={0}"   native: no such function
```

Root causes:

- **The JVM builtins were stubs.** `lowerBuiltinOrStaticCall`
  (`jvm/codegen/04_calls.l`) lowered every arity to its template argument
  alone, so the arguments were never evaluated or substituted.
- **dotnet called `String.Format`.** That gave .NET's composite-format grammar
  (alignment `{0,5}`, format strings `{0:X}`) and current-culture number
  formatting, neither of which any other target had, and MSIL had no lowering
  for `format4` at all.
- **`format3`/`format4` had no type-checker signature**, so user code could
  not call them (noted on the issue while fixing #7852).
- **Native had no format builtins.**

Fix: the placeholder grammar is implemented once, in Lyric, and every backend
reaches it the same way.

- `Std.String.formatArgs(template: String, args: slice[String]): String`
  (`lyric-stdlib/std/string.l`, `@stable(since = "1.2")`) scans the template
  by code unit and builds the result with `StringBuilder`, so it is linear in
  the result.  `{n}` substitutes `args[n]`, `{{`/`}}` are literal braces, an
  unused argument is ignored, and a placeholder with no argument or any other
  brace panics with the offset and the template.  It is public, so a caller
  with more than four arguments can use it directly.
- `Lyric.Pipeline.pipeWeave` rewrites `formatN(t, a1, ..., aN)` to
  `Std.String.formatArgs(t, [toString(a1), ..., toString(aN)])` after weaving
  (so advice spliced in from another package is covered) and before the await
  hoist.  Each argument is stringified exactly as `toString` stringifies it,
  so the type checker's #7812 unsigned respelling (`x.toULong()`) makes a
  `UInt`/`ULong` at or above the sign bit render unsigned, a `Double` renders
  culture-invariant, and a `Byte` renders 0..255, on every target.  The
  template is evaluated first and each argument once, left to right.
- The type checker types all four arities from one helper,
  `formatBuiltinArity` (`parser/parser_ast.l`), and `isCodegenBuiltinName`
  lists `format3`/`format4`.
- The MSIL `String.Format` lowering and the JVM stubs are deleted.  The three
  `String.Format` MemberRef rows stay (unread) so later rows do not shift,
  the convention rows 4 and 5 already follow.
- The JVM and native bundlers link `Std.String` whenever a build calls a
  format builtin (`pipeUsesFormatBuiltin`), since nothing need import it.

Behaviour change on dotnet: alignment and format-string placeholders
(`{0,5}`, `{0:X}`) now panic as malformed instead of being passed to
`String.Format`; no source in the repository used them.  `Std.Format`'s
`padLeft`/`toHexString` cover those needs on every target.

Tests:

- `lyric-compiler/lyric/format_builtin_self_test.l` (new, dual target, 12
  cases): each arity; escaping; reordered and repeated placeholders; unused
  arguments; a missing argument and every malformed-brace shape panicking;
  `UInt`/`ULong` at and above the sign bit from locals, literals, fields,
  call results, slice elements, a generic field and a `UInt` range subtype;
  a non-literal template; non-ASCII text; evaluation order.  12/12 on dotnet
  and JVM.  Wired into `compiler-self-tests-batch.sh`,
  `jvm-generics-self-tests-batch.sh` and `ilverify-selfhosted.sh`.
- `byte_stringify_self_test.l` absorbs the `Byte` format cases from
  `byte_stringify_dotnet_self_test.l`, which is deleted; 10/10 on both
  targets.
- `llvm_stdlib_self_test.l` gains two native cases (every arity, escaping,
  unused arguments and non-ASCII text with no `Std.String` import; a missing
  argument panics).  `UInt`/`ULong` arguments are not covered on native,
  which does not lower those types yet (N0007).
