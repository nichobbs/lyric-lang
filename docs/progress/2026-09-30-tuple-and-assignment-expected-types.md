# Open tuple locals and assigned if/match values keep their types (#7855)

Two positions still built a `None`, `Ok(...)`, `Err(...)` or `newList()` at
the wrong instantiation on `--target dotnet`, with or without an `await`:

```lyric
val t = (None, 5)                        // Option<object>
pairValue(t)                             // pairValue(p: in (Option[Int], Int))

cell.o = if c { None } else { Some(5) }  // "match not exhaustive"
```

An unannotated `val r = Ok(2)` or `val r = Err("e")` had the same gap as the
tuple: `Ok(2)` fixes `T` but leaves `E` open, and MSIL built a
`Result<int, object>` that a `Result[Int, String]` match never recognised.
The JVM erases generics, so only `val (xs, n) = (newList(), 3); xs.add(n)`
failed there: the destructured `xs` was an erased `Object` with no `add`
(J008).

## Fix

**Open tuples.** #7788's open-binding inference now covers a tuple literal
whose open elements are each an evidence-free construction, an open local, or
such a tuple (`OpenBindingSite.childKeys`/`childPaths`). Each open element is
its own open site, owned by the tuple (`parentKey`), or an open local's own
site. A type recorded for the tuple is recorded for each child at its
position (`noteOpenBindingType`). A name that a tuple pattern binds at a
child's position is open to that child (`bindOpenTuplePattern`), whether the
pattern is a destructuring `val` of the tuple local, of the literal itself,
or a `match` arm on the local, so the name's own uses fix the element. Once
every child is resolved, `resolveOpenTupleSite` writes the tuple's type
with every child in place as the binding's annotation. It also records:

- each name the patterns bound in `tuplePatternBindingSites` (#7728), which
  types the JVM's erased element reads;
- each element the await hoist binds one by one in `hoistOperandTypeSites`
  (#7823). The checker cannot record these while nothing has fixed their
  type, so `val t = (None, await five())` composes.

`noteExpectedFlow` also descends into a tuple literal, so `(xs, 1)` carries
the open `xs` to a tuple-typed position.

**Ok/Err locals.** A stdlib `Some`/`Ok`/`Err` construction is evidence-free
when its inferred type is left open (`isStdMonadCaseCtor`), recognised by
the case it resolved to, as #7801 does for `None`.

**Assigned values.** MSIL lowered a plain local assignment's value with the
local's type as its construction context (`pushAnnoHintTyArgs` +
`pushCollExpect`), as an annotated `val` initialiser is lowered. A field
assignment (plain, generic-record, `self`) pushed only the collection
expectation. An element assignment (`List`, `Map`, `slice`) pushed nothing.
`lowerAssignValueAtMsil` now gives every `=` target's value the target's
type, and the arms of an `if`, `match` or block value inherit it. Compound
assignment combines the value with the target's current value, so it has no
construction to type. The JVM erases generics and was not affected.

## Tests

`lyric-compiler/lyric/expected_type_propagation_self_test.l` is a new
dual-target `@test_module` with 6 tests covering:

- a tuple passed, returned, destructured (local and literal), matched and
  nested;
- `Ok`/`Err` and `newList()` tuple elements, stores through a destructured
  name, a tuple holding an open local, and a reassigned `var` tuple;
- `Ok`/`Err` locals;
- `if`, `match` and nested-block values assigned to a field, a nested field,
  a `self` field, a generic record field, a `List` element, a `Map` value
  and a `slice` element, plus one compound field assignment;
- awaiting variants: an unannotated tuple and a destructured literal holding
  an `await`, an `Err` local and a field assigned before an await, and field
  and element assignments whose arm awaits.

Results:

- dotnet: before 0/6; after 6/6.
- jvm: before, failed to compile (J008); after 6/6.

The test is added to `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh` and phase 4 of
`scripts/ilverify-selfhosted.sh`. The rules are documented in docs/01 §4.3
and book §12.4.
