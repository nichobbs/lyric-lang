# D206 — Cross-target rules for `Map.add`, `print`/`println`, `toIsoString` and stringification

**Status:** accepted

Closes #7301, #7800, #7893, #7911, #7912, #8169 and #8314. Records the check
that #7312 and #7354 need no change. #8170 and #7892 stay open.

## Context

The same Lyric program gave different results on `--target dotnet`,
`--target jvm` and `--target native`. `docs/01` was silent on each point, so
each target had picked its own host behaviour:

- `Map.add(k, v)` on an existing key: `Dictionary.Add` threw on dotnet, while
  `HashMap.put` (JVM) and `lyric_map_set` (native) replaced the value (#7301).
- `print(x)` was typed `String`-only (T0043 for `print(42)`), while `println`
  took any value (#7893). `println()` was rejected (T0042) although every
  backend lowers a zero-argument form (#7912).
- `Std.Time.toIsoString` printed `...05.0000000Z` on dotnet (`DateTime.ToString("o")`)
  and `...05Z` on the JVM and native (#8314).
- On dotnet, interpolation, `+`, `.toString()`, negative integers and a
  generic `T` followed the process culture: `1,5` under `de_DE`, a U+2212
  minus sign under `sv_SE` (#7911). The JVM was already invariant.

## Decision

1. **`Map.add` replaces.** `m.add(key, value)` inserts the entry, or replaces
   the value of an existing `key`; it never raises. It is `m[key] = value`.
   An upsert is what two of three targets did, never loses a program that
   worked, and cannot take down a server thread on a duplicate (the repeated
   request-header crash that found this).
2. **`print` and `println` take the same argument.** Both are language
   built-ins that need no import and accept a value of any type, which they
   stringify as `toString` does. `println()` is legal and writes an empty
   line. `print()` is not: it would write nothing. `Std.Console.print` and
   `Std.Console.println` stay the `String`-only functions, reachable
   qualified.
3. **`toIsoString` has one form.** `YYYY-MM-DDTHH:MM:SS`, then no fraction when
   it is zero, otherwise the shortest of 3, 6 or 9 digits that loses nothing,
   then `Z`. That is `java.time.Instant.toString` and what native already
   printed. dotnet re-groups the seven digits of its `"o"` format.
4. **Stringification is culture-invariant.** On dotnet `main` pins
   `CultureInfo.CurrentCulture` and `CultureInfo.DefaultThreadCurrentCulture`
   to the invariant culture before its first statement. One pin covers every
   path (interpolation, `+`, `+=`, `.toString()`, `toString(x)`, `format1`-`4`,
   `print`/`println`, a generic `T`) instead of routing each codegen site
   through an invariant helper, where a missed site is a silent regression.
   Case folding and comparison become invariant too, which the language
   reference already specifies for `toLower`/`toUpper`.
5. **`==` on tuples, `List`, `Map` and `Set` is structural.** Two tuples or
   `List`s are equal when their elements are, in order; two `Map`s or `Set`s
   when they have the same size and every key of one is in the other (with an
   equal value, for a `Map`). Elements are compared under D172's relation.
   `--target dotnet` compared them by reference (`Object.Equals` on a
   `List<T>`/`Dictionary`/`HashSet`), so `(1, 2) == (1, 2)` was `false`; the JVM
   already used `equals`. Structural is what D172's host overrides already did
   for a `List` field of a record, so `==` on that record, a `List` field
   compared through it and the record as a `Map` key now agree. D157's identity
   rule stays for records with `var` fields: it is about a record that
   mutates in place, not a collection compared as a value. dotnet lowers `==`
   inline (`emitStructuralCollEqMsil`, reusing the element loops the key
   overrides use). Left open: a tuple as a bare `Map`/`Set` key on dotnet
   (#8170, which needs a comparer or a tuple class with overrides), `==` on
   native (#8167), and `Double.equals` for a JVM `List[Double]` element (#8439).
6. **`xs.add(index, item)` exists on native.** It lowers to a new
   `lyric_list_insert`, which panics outside `0 ..= len` like the managed
   targets raise.
7. **Nothing to change for #7312 and #7354.** `Std.Set` on the JVM works since
   #7782 (`newSet` is an intrinsic like `newList`/`newMap`). A user-declared
   `toString` on a distinct type is an ordinary method that wins over the
   builtin arm on both targets, and the builtin arm renders the underlying
   value on both; the parity test pins it.

## Consequences

- `docs/01` §2.7 states the `Map.add` rule; §2 states the `print`/`println`
  and invariant-culture rules; the book's quick reference lists
  `println()`, `print(x)` and the `toIsoString` form.
- A program that relied on `Map.add` throwing on a duplicate key on dotnet
  now replaces the value. That throw was an unspecified host accident.
- A program that read `toIsoString`'s seven-digit fraction on dotnet gets the
  canonical form. `Std.Time.parseOptInstant` accepts both.
- Tests: `stdlib_parity_self_test.l` (both targets),
  `culture_invariant_self_test.l` (dotnet under `de_DE` and `sv_SE`, and the
  JVM, run by `scripts/ci/println-stringify-e2e.sh`), `llvm_collections_self_test.l`.
