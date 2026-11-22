# The element of a host collection the checker did not type is what the host's iteration protocol declares (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`for m in re.Matches(s)` where `re` is a `System.Text.RegularExpressions.Regex` (an instance method of an `import extern` type) iterates a value the checker leaves untyped; the builder types the chain itself (D444) but gave the loop variable no type, since only `extern type`s of one type argument had an element type (`extern_iter_self_test.l`).

## Decision

When the iterable has a host type and no element type of its own, the builder asks the same `ExternIterResolver` the checker asks for a typed `for` (docs/42 section 9, D302): `IEnumerable<T>`'s `T` (a host class, a primitive, or one of the receiver's type arguments), or the host's root object for a collection that is only the untyped `IEnumerable`; a type the metadata cannot locate keeps the loop variable open and counted.

## Results

`tir-builder-shapes-e2e.sh` (`host_iteration_element`, dotnet); `extern_iter_self_test.l` builds under the gate.
