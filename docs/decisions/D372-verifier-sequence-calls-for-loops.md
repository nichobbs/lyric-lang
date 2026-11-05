# D372 - The verifier applies Std.Buffer contracts and proves `for` over sequences (#8394, #8753)

**Status:** shipped

Completes the verifier half of docs/67 G2 (#7941). Narrows docs/15 §5.3's
sketch of the `for` encoding.

## Context

After #8725 and #8751, `lyric prove` modelled arrays, slices and buffers as
`(Lyric!Seq T)` values, but three things still failed closed: a buffer a
`Std.Buffer` function returns (the call was an unknown callee, so its result
was no sequence term), `for x in a` (`V0026` as a statement form), and
`a[i][j] = v`. Imported callees were applied only when they were
non-generic over primitive types and their bodies named nothing but their
parameters, which no `Std.Buffer` function is.

## Decision

1. **Imported callees by contract.** A public function of an imported
   package is applied at a call by its `requires:` and `ensures:` when its
   parameter and result types are primitives, its own type parameters, or
   arrays (of literal length), slices and buffers of them; every type
   parameter appears in a parameter, so the call fixes the instance; and its
   clauses name only its parameters, `result`, and the variables of their own
   quantifiers (each of a primitive type). A body that names anything else is
   dropped, and the function is applied by its contract alone. A function over
   `buffer[T]` is not applied where `buffer` names another type in the proved
   file's scope. This is the route #8753 preferred over verifier builtins: the
   facts live with the functions.
2. **`Std.Buffer` states its elements.** `filled`, `grow` and `truncate`
   gain `forall` `ensures:` clauses for their elements. A runtime-checked
   build skips a quantified conjunct (W0002) and still checks the lengths.
   `result` is a stable buffer receiver for T0174, since the contract
   elaborator binds it to a local.
3. **Unknown element types fail closed on writes.** A sort does not show a
   range subtype, so a binding a call initialises has an unknown element type
   (`SortInfo.elem` empty), and an element write of a number into it fails
   closed (`V0026`) instead of omitting the range check the runtime makes. An
   annotation on the binding gives the type. This also closes the same gap for
   a local generic or non-generic callee returning an array of a range type.
4. **`for` is a `while` over a hidden index.** `for x in a { invariant: ι; S }`
   over an array, slice or buffer is `val s = a; var k = 0; while k < s.length
   { invariant: 0 <= k <= s.length and ι; val x = s[k]; S; k = k + 1 }`, with
   `s` and `k` names no source can spell. The snapshot is docs/01 §2.7's "the
   value the loop started with". The index is not nameable, so `ι` speaks of
   the variables around the loop; a progress property needs a `while`. This
   replaces docs/15's `(remaining, processed)` sketch, which needed sequence
   concatenation the model does not have; the two are equivalent where both
   apply. Ranges, `List` and `Map` iteration, and `break`/`continue` in the
   body, stay `V0026`.
5. **Nested element writes.** `a[i][j] = v` on an array or buffer of arrays
   stores the changed inner array back, with bounds at each level and the
   innermost element type's range obligation. `r.a[i] = v` stays `V0026`: only
   a `var` field is writable, and a record with a `var` field has identity on
   every backend (D157, D222; D303 restricts `in` but changes no backend's
   sharing), which the verifier has no heap to follow.

6. **Facts reach later obligations.** The facts a statement establishes (an
   `assert`'s claim, a callee's `ensures:`, an element read's range, a
   binding's range) now guard the side goals of the statements after it, as
   they already did the postcondition. Before, a side goal saw only the
   parameters and the precondition, so `assert(i < x.length); x[i]`, or a
   bound that follows from a `Std.Buffer` result's length, did not discharge.
   The facts are about immutable SMT values, so they hold wherever a later
   statement's obligation is evaluated.

## Consequences

More stdlib calls carry obligations in proofs: a call of an eligible imported
function must meet its `requires:`. Every such clause is also checked at run
time, so a proof that now fails was relying on an unchecked value.
