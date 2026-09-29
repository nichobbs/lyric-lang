# Unannotated `newList()`/`newMap()`/`None` locals take their type from their uses (#7788)

```
func decodeMessage(data: in slice[Byte]): Result[List[DecodedField], String] {
  val fields = newList()
  ...
  fields.add(step.field)
  ...
  Ok(value = fields)
}
```

Nothing where `fields` is constructed fixes its element type. The type checker
typed it `List[<error>]`, which every later use accepted. The JVM erases
generics, so it was indifferent. The MSIL backend builds a reified generic and
had no element type at the construction site, so it built `List<object>`. It
then stored that where the `Ok` payload is declared `List<DecodedField>`,
which is unverifiable IL. Any consumer that used the payload as the
`List<DecodedField>` its type says it is threw `InvalidCastException`: a typed
binding's `.count`, a `for`, an index. `lyric-proto`'s `decodeMessage` is this
exact shape. An unannotated `None` returned as a `Result[Option[Pt], String]`
payload was `Option_None<object>`, which a `match` on `Option[Pt]` never
recognised ("match not exhaustive").

An unannotated `val`/`var`/`let` bound to one of these constructions (bare or
qualified) is now an *open binding* whenever its inferred type still has
holes. The checker records its uses as it checks the function
(`SymbolTable.openBindingSites`).

- **Sinks** are positions with a declared type the binding flows into: call
  arguments, returned and trailing values, typed binding initializers,
  assignment values (all through `inferExprExpected`), and constructor
  fields, including those of a nested construction. For
  `Ok(value = Some(value = xs))` against a `Result[Option[List[Seed]], E]`,
  each field's declared type is instantiated at the expected type's
  arguments.
- **Stores** are `xs.add(x)`, `xs.add(i, x)`, `m.add(k, v)`, `xs[i] = x`,
  `m[k] = v` and `o = Some(x)`.

Only closed types of the binding's own constructor count. There is one
exception: a store's type may mention the enclosing function's own type
parameters (`xs.add(x)` with `x: T`), which `Lyric.Mono` substitutes when it
specialises the body. `typeExprForOpenBinding` spells such a type. A sink's
type never counts when it mentions a type parameter, because a generic
callee's parameter `List[T]` names the callee's `T`.

At the end of the file, `resolveOpenBindingSites` turns each binding's uses
into an annotation:

- the first sink, unless two sinks disagree;
- otherwise the stores, when they agree.

The annotation goes into the channel the function-valued locals of #7711
already use, now named `localBindingTypeSites`. `Lyric.Mono.desugarCheckedFile`
writes it onto the binding, so every backend sees
`val fields: List[DecodedField] = newList()`. MSIL builds that as
`List<DecodedField>` through its existing annotated-accumulator path. A
binding whose uses disagree or say nothing keeps its previous behaviour, and
no new diagnostic is reported. The rule is in the language reference §4.3 and
the book's §12.4.

The same commit adds an `originScope` guard to Mono's other span-keyed
checker sites (`copySites`, `funcRefSites`, `argConversionSites`,
`funcValueCallSites`, `localBindingTypeSites`, `tuplePatternBindingSites`),
matching the guard `callResultTypes`/`lambdaTypes` already have
(`checkerSitesApplyMono`). These maps are filled only by
`desugarCheckedFile`, whose state never enters another package's generic
body, so no collision can occur today. The guard makes that invariant local.

`lyric-compiler/lyric/unannotated_list_result_self_test.l`, dual-target, now
has eleven cases:

- the original `Result[List[Seed], String]`;
- the returned list read through a typed binding's `.count`, a `for` and an
  index on a `List[Seed]` parameter;
- an unannotated `None` returned inside `Result[Option[Pt], String]`;
- a `None` var later assigned `Some`;
- a list returned, passed as an argument and stored in a record field;
- a nested payload;
- stores only;
- a map (`add` and an index store) and `newListWithCapacity`;
- `Int` stores into a list returned as `List[Long]`;
- a generic function that stores its `T` parameter, instantiated at `Int` and
  at a record;
- a qualified `Host.newList()` through `import Std.CollectionsHost as Host`.

Results:

- dotnet before, on the base compiler: 3/9 of the first nine cases passed,
  with 9 ilverify errors. The failures were `InvalidCastException` on
  `List<object>`/`Dictionary<object,object>` and "match not exhaustive" for
  the `None`.
- The two cases added last (the generic function and the qualified call) were
  measured on a build that had the rest of this change but not their support.
  Both failed with `InvalidCastException`.
- dotnet after: 11/11, 0 ilverify errors.
- jvm before: failed to compile (J007, `s.n` on an erased element of the
  stores-only list).
- jvm after: 11/11.

The file is now in `scripts/ilverify-selfhosted.sh` phase 4, from which it
had been left out because its producer store was unverifiable.
