# D680 - Open locals, targets and yields take the type their context fixes (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

The wide census over the compiler's self-tests (part 17, on a binary with D615-D619) counted bodies the builder could not build because the checker recorded no type at a node whose type its context fixes: the binder of a `for` over a local whose type its uses fixed (`var xs = newList()` then `xs.add(Seed(...))`), a field read through such a binder, an index (`xs[0]`, `m["b"] = 2`) of an open local, an assignment to a field of a generic opaque type (`self.second = next`), a tuple assigned over an open one, a yielded `None`, a bracket literal passed as a `List` parameter, and `T.default()` in a generic body.

## Decision

- A `for` binder the checker left untyped takes the element type of the iterable as the builder built it (slice, array, `List`, `Set`), and a tuple binder takes the element types of a tuple element.
- A field read (`p.step`, `s.n`) takes its receiver's type from `exprOrOpenTy`, not only the checker's, and a field of an opaque type declared in this package is read at the receiver's type arguments as a record's is.
- An index expression on an open receiver is the receiver's element type (the value type of a map); an assignment target the checker left untyped is typed by the same rules; an assigned value is settled to the place's type, whatever its form.
- A yielded value takes the generator's declared type (kept in `BuildEnv.yieldTy`, beside `retTy`, which a generator leaves empty).
- A bracket literal typed as a host `List` settles its elements to the list's element type.
- `T.default()` where `T` is a type parameter is the built-in `default` at the node's own type; each instantiation takes its own zero.
- An expression the checker recorded a closed type for in `hoistOperandTypeSites` (a call receiver that leaves an argument open) takes that type when its kind matches.
- `lyric-web` annotates the `String?` of a host property read before `??` (kernels annotate locals, docs/01 2.11).

## Results

`open_local_shapes` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` and runs. `tir_build_self_test.l` covers `T.default()`, the generic opaque assignment and the yield.
