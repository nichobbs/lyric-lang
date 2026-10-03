# Default thunks named by parameter types; same-count method overloads rejected; T0155 compares every form (#8085)

Review follow-up to #7827 (D168).

**Default thunk collision (#8085).** The thunk a parameter default compiles
into was named from the owner, the callable, its parameter count and the
parameter. Two overloads with the same count and the same defaulted
parameter (`scale(self, x: Int, factor: Int = 1)` and
`scale(self, x: String, factor: Int = 2)`) mapped to one name:
`synthesizeDefaultThunks` kept the first and `Lyric.ContractMeta` pointed
both overloads at it, so a restored consumer would silently take the wrong
default. `Lyric.Parser.defaultThunkName` now spells the callable's parameter
types into the name (`paramTypesKey`, e.g.
`__lyric_default__R__scale__R_String_Int__factor`), computed from the
declaration by both the synthesiser and the renderer, and a second default
reaching a name the pass already synthesised panics as an internal error
instead of being skipped. Thunk synthesis moved from the end of
`pipeCheckAndMono` to just after the checker's results are desugared, so a
public generic function's non-generic defaults (mono drops the function
from the file) are exported too.

**T0156.** Investigating the case showed that two methods of one name and
parameter count in one type never worked: both backends key a method by
name and count (MSIL threw `InvalidProgramException`, the JVM a
`ClassCastException`, even with every argument written), while two such
free functions were already T0001. The type checker now rejects them in a
record, exposed record, interface or `impl` (T0156); overloads of
different counts are unaffected.

**T0155.** The default comparison handled only some expression forms and
called every other form (an `if`, a `match`, an interpolated string, an
index) different, so identical defaults could warn. It now compares the
canonical span-free rendering (`Lyric.Fmt.exprInline`), ignoring enclosing
parentheses.

Tests: `restored_default_args_self_test.l` gains a restored method with two
overloads of different counts, each taking its own default (both targets);
`contract_meta_self_test.l` checks that same-count overloads render distinct
thunk names and spells `paramTypesKey` for every type form;
`typechecker_self_test.l` adds T0156 (record, interface, impl, and the valid
different-count case) and T0155 with identical interpolated and `if`
defaults.
