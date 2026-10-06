# `?` on a bare constructor of another instantiation works on every target (#8181)

On `--target dotnet`, `?` applied to a bare union-case construction whose
success type differs from the enclosing function's (`two(s, Ok(value = "bb")?)`
or `val m = Ok(value = "bb")?` in a `Result[Int, String]` function, `Some(value
= "abc")?` in an `Option[Int]` one) compiled, but the CLR rejected the method
with `InvalidProgramException`; the JVM printed the right result, and native
rejected the program (N0007, "cannot infer type argument 'E'").

Root cause: the MSIL backend instantiates a bare construction that has no type
expected of it at the enclosing function's declared return type, and lets that
context win over the type its own argument gives a type parameter.  So
`Ok(value = "bb")` was built as `Result<int, string>` with a `string` payload,
and the match `Lyric.Propagate` lowers `?` into read it back as an `int`.  The
same happened without `?` to a local such as `val r = Some(value = "four")` in
an `Option[Int]` function.  An operand that fixes no success type
(`Err(error = x)?`, `None?`) had the converse problem where the value went to
a typed position: `two("a", Err(error = "z")?)` built the never-taken success
path at the function's success type and passed it as the `String` argument.

Fix:

- The type checker (`inferPropagate`) types the operand of `?` as the
  lowering uses it.  The operand must be of the enclosing function's monad,
  and a `Result` operand's error type must be assignable to the function's
  error type, since `?` re-wraps the operand's error in the function's `Err`:
  otherwise the use is the new **T0169** (`val x: Int = Err(error = 5)?` in a
  `Result[Int, String]` function was accepted, and an `Option` operand there
  failed in codegen).  An error type that widens to the function's (`Int`
  into `Result[_, Long]`) is bound at its own type and converted where
  `Lyric.Propagate` re-wraps it, including for `(r?)?`; before, the JVM
  stored the `Int` and a reader of the `Long` threw `ClassCastException`.
- The operand's success type is its own; an `if`/`match` operand takes each
  type argument from whichever branch fixes it (`unifyBranchTypes` now joins
  the branches' open type arguments).
- An operand that fixes no success type (`Err(error = x)?`, `None?`, or an
  `if`/`match` all of whose branches are such) can never be `Ok`/`Some`, so
  the `?` never yields a value.  Its success type is the one the position
  consuming the value expects: a binding's annotation, a call or method
  argument's parameter (a generic one instantiated from the type expected of
  the call's result, also when that call is itself an argument, at any
  depth: `lenOf(id(id(Err(error = "n")?)))`), a record field, a `List.add`
  element, `Bool` for a condition, the other operand of a binary operator, or
  the type the branches of an `if`/`match` join to.  Where nothing gives it one (a
  tuple element, an unannotated binding, a statement), the type checker
  records nothing: the JVM erases it and the dotnet backend builds it at the
  function's instantiation, as before.  The checker offers the function's own
  instantiation as a fallback (`SymbolTable.propagateFallbackSites`), which
  `pipeCheckAndMono` binds only for a native build, which needs every
  construction closed; it types only the path the `?` never takes.  An
  operand that is an argument of a generic call gets no fallback, so it never
  instantiates the callee at the wrong type.
- A call argument holding such a `?` is checked once: once the callee's
  signature is known, the open operands inside it are given their types by a
  walk over the already-checked argument, which also records the type
  arguments of each generic call on the way for `Lyric.Mono`.  Checking a
  nest of calls therefore costs time linear in its depth.
- An operand built from context, or one whose own type leaves a slot open, is
  recorded in `hoistOperandTypeSites`, so `Lyric.Mono` binds it to a local
  annotated with its type before the lowering, on every target.
  `Lyric.Propagate` looks through that typed local when deciding whether the
  operand awaits or is safe inside a protected region (F0045 is unchanged).
- The MSIL backend no longer lets a context type override a type argument a
  constructor's argument pins when the context cannot hold that argument (two
  different scalars that do not widen, a reference type into a scalar slot,
  or a scalar into `String`); a context of another reference type keeps it,
  as it may be a supertype (#3502) or an interface a scalar is boxed as.

Tests: `propagate_ctor_operand_self_test.l` (19 cases: `Ok`/`Err`/`Some`/
`None` operands as call arguments, generic arguments (also nested one and
two calls deep, and in a method's argument), record fields, `List.add` elements, binary
operands, conditions, interpolated segments, returned constructor fields,
tuple elements, initializers (annotated or not), statements and member
receivers; `if`/`match` operands whose first branch is `Err`/`None`,
parenthesised or not, and a local of one; generic and async functions;
evaluation order when an `Err` argument returns; an error type that widens,
also through `(r?)?`)
on dotnet, the JVM and native, and `propagate_ctor_operand_try_self_test.l`
(the `try` cases, on dotnet and the JVM; native has no `try`, D-N-003),
wired into the compiler, JVM-generics and native batches and the ilverify
consumer list; `typechecker_self_test.l` cases for the recorded operand
types, the native fallback, the widening, T0169, and depth-20 nests checked
in linear time; `propagate_self_test.l`
cases for F0045 through the typed local.

Not changed, tracked separately: reading a member of a never-produced `?`
value whose type nothing fixes (`val s = None?` then `s.length`) runs on the
JVM, is unverifiable IL on dotnet on the path never taken, and is N0007 on
native (#8257); `?` on an operand that is neither `Result` nor `Option` is
not diagnosed (#8249); an open local used at two incompatible instantiations
is not diagnosed (#8250); a single-file native build of a program that uses
`Result` without `import Std.Core` is N0007 (#8256).
