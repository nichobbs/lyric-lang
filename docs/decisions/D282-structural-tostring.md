# D282 — One structural `toString` for records, unions, tuples and collections (#7892)

**Status:** accepted

## Context

After #7858, `println(x)` prints exactly `toString(x)`. But `toString` of a
value that is not a scalar or a `String` gave the host's own text, and the
hosts disagree:

| Value | dotnet | JVM | native |
|---|---|---|---|
| `List[Bool]` | ``System.Collections.Generic.List`1[System.Boolean]`` | `[false]` | compile error |
| record `P` | `Repro.P` | `Repro.P@3ff2` | compile error |
| union case | `Repro.Shape_Circle` | `Repro.Shape$Circle@5` | compile error |
| tuple | ``System.Collections.Generic.List`1[System.Object]`` | `[1, 2]` | compile error |

None of these is a useful, documented Lyric rendering, and the JVM forms
contain an identity hash that changes between runs. docs/01 did not say what
`toString` of a record or collection produces, and no decision covers it
(D172 gives equality and hashing one rule; this does the same for text).

## Decision

1. **One text, every target.** `toString(x)`, `x.toString()`, string
   interpolation, `String + x` (either operand), `s += x`, `print`, `println`
   and `format1`-`format4` render a value of the types below as follows. The
   rendering is by the static type of the operand, and it is the same on
   dotnet, the JVM and native.

2. **The format.**

   | Type | Rendering | Example |
   |---|---|---|
   | record | `Name(field = value, ...)`, type arguments not shown | `P(x = 1, y = 2)`, `Box(v = 3)`, `Empty()` |
   | union case | `Case(field = value, ...)`; the bare case name for a case with no fields | `Circle(radius = 5)`, `Unit` |
   | positional union case field | the value alone | `Pair(1, 2)` |
   | `Option`, `Result` | ordinary unions | `Some(value = 3)`, `None`, `Ok(value = 1)`, `Err(error = boom)` |
   | enum | the case name | `Red` |
   | tuple | `(a, b, ...)` | `(1, 2)` |
   | `List`, `slice` | `[a, b, ...]` | `[1, 2]`, `[]` |
   | `Map` | `{k: v, k2: v2}`, entries ordered by the rendered key text | `{a: 1, b: 2}` |
   | `Set` | `{a, b}`, members ordered by their rendered text | `{1, 2}` |
   | `Unit` | `()` | `()` |

   Parts are separated by `", "`. Each part is rendered by the same rules, so
   they nest.

3. **Leaves.** A scalar leaf renders as `toString` renders it standing alone
   (`Double` in the invariant format, `Bool` lowercase, `Byte`, `UInt` and
   `ULong` unsigned, D-progress-1052 and #7812). A `String` or `Char` leaf is
   its text, with no quotes and no escaping. Quoting would make `["a", "b"]`
   distinguishable from `[a, b]`, but the JVM already renders its lists
   unquoted, as do Kotlin data classes and C# collection printers; the
   rendering is for people reading a log, and a program that needs an exact,
   parseable form uses `Std.Json`.

4. **`Map` and `Set` order.** Host iteration order differs between targets
   (insertion order on dotnet, hash order on the JVM). So `Map` entries are
   ordered by the code-unit order of the rendered key text, and `Set` members
   by the code-unit order of their rendered text, which makes the text equal on
   every target. The order is of the text, not the value: `10` renders before
   `9`.

5. **Not structural.** A value of an extern, opaque, protected or interface
   type, a function value, and a distinct or range type (which is its
   underlying value, as before) keep the host rendering. A record or union
   that holds one renders that part with the host text.

6. **Cycles.** A `ref record` (identity semantics, D222) can reach itself. The
   rendering of a `ref record` shows `...` in place of a record more than 32
   `ref record` levels below the one printed; a value record and a union have no
   such limit, since they cannot be cyclic.

7. **Where it is lowered.** The type checker records each stringified operand of
   one of these types and synthesises, per type, a function
   `__lyric_str_N(x, d)` that renders it from its parts, with the joins in
   `Std.String.showSeq`, `showMap` and `showSet`. `Lyric.Pipeline` wraps the
   operand in a call of that function (`lowerShowSites`), so every backend
   receives a `String` and none has rendering code of its own. This is the
   route the unsigned operands (#7812), record equality (D164) and covariant
   conversions (D211) take. A host `ToString`/`toString` override on records and
   unions is therefore not needed.

8. **Generics.** A generic function is checked once, over its type parameters,
   so `toString(x)` for `x: T` is a site only where the checker knows `T`. A
   specialisation that binds a type parameter to one of these types is checked
   again (as it is for D172 item 4 and unsigned operands), and its stringified
   operands are rendered. A generic declared in another package that is
   specialised in a consumer is covered by the same re-check.

## Rationale

- Rendering by static type is the only way to tell a tuple from a `List` (both
  are `List<object>` on dotnet and `ArrayList` on the JVM), to print a `UInt`
  unsigned, or to print anything on native, which has no host `toString`.
- Lowering in the shared pipeline gives one implementation, one test per
  construct, and no per-backend divergence, instead of a `ToString` override
  in each of three code generators.
- `Name(field = value)` is the form the JVM-style `P@hash` and the CLR type name
  both stand in for. Naming the fields makes a record readable without its
  declaration; the value-only form is kept for positional union fields.
- Sorting by rendered text is cheap, total and independent of the key type.

## Consequences

- Code that depended on the old text changes: `println` of a record or list no
  longer prints a CLR type name or `P@hash`. The standard library, the
  ecosystem libraries and the tests were searched; the ones that did are
  updated in the same change.
- `docs/01` §2 states the rendering. The book's records and collections
  chapters follow.
- `--target native` accepts these operands in `println`/`toString`/
  interpolation where it used to reject them at compile time (docs/01 §2:
  "rejects any other argument").
- The `array[N, T]` type, a `foreign record` and `buffer[T]` are not rendered
  structurally yet; they keep the host text on dotnet and the JVM and remain
  rejected on native. Tracked as a follow-up.
