# Testing

Testing in Lyric is a language feature, not a framework. The `test`, `property`, and snapshot constructs are built into the compiler and the standard library, and `lyric test` runs them with no configuration, no test runner to install, no XML to write. If you are coming from JUnit, NUnit, or Jest, the mechanics are familiar — what is different is that the primitives are part of the language itself, which means they compose with everything else: contracts, opaque types, wire blocks, and async code.

This chapter covers the three test styles (unit tests, property tests, and snapshots), doctests extracted from doc comments, and the command-line flags that control what runs. The next chapter covers stubs and test wires, which are how you isolate code that depends on interfaces.

## §14.1 `@test_module`

Test code lives in packages annotated `@test_module`. The annotation does two things: it marks the package as test-only (excluded from production builds) and it grants access to the package-private declarations of the package being tested.

```lyric
@test_module
package Account

import Std.Testing
import Account.{Account, debit}

test "debit reduces balance" {
  // debit is imported from the Account package;
  // the Account type's internals are visible because
  // this package is @test_module for Account
}
```

The package declaration (`package Account`) names which package this module tests. You can test package-private helpers directly without making them `pub`. That is the point: `@test_module` is the only mechanism for crossing the visibility boundary, and it is per-package. A test module for `Account` does not gain visibility into `Money.Cents` internals; it only gains visibility into its declared target.

::: note
**Note:** Test modules cannot be imported by non-test packages. The compiler enforces this. Circular test-module dependencies (two test packages that import each other) are also rejected.
:::

Run the tests for a package with:

```sh
lyric test
```

Run only tests whose names match a substring:

```sh
lyric test --filter "debit"
```

The filter matches on the full test name, including any grouping prefix you establish by convention. `--filter` accepts a plain substring, not a regex.

## §14.2 Assertions

`Std.Testing` ships a small, deliberately thin assertion vocabulary. There is no assertion library to learn; these six functions cover essentially everything:

| Function | What it does |
|---|---|
| `expect(condition)` | Fails if `condition` is `false` |
| `assertTrue(condition, label)` | Fails if `condition` is `false`; prints `label` on failure |
| `assertEqualInt(actual, expected, label)` | Fails if `actual != expected`; prints both values and `label` |
| `assertEqual(actual, expected, label)` | Type-polymorphic version of `assertEqualInt` for any `Equals` type |
| `assertNone(value, label)` | Fails if `value` is `Some(_)` |
| `assertSome(value, label)` | Fails if `value` is `None` |

A complete test block using several of these:

```lyric
@test_module
package Account

import Std.Testing
import Account.{Account, debit, credit, balanceOf}
import Money.{Amount, Cents}

test "debit reduces balance by the amount" {
  val initial = makeTestAccount(balanceCents = 10_000)
  val amount  = Amount.make(Cents.tryFrom(3_000).unwrap()).unwrap()

  val result = debit(initial, amount)
  assertTrue(result.isOk, "debit should succeed when funds are sufficient")

  val updated = result.unwrap()
  assertEqualInt(balanceOf(updated).toLong(), 7_000, "balance after debit")
}

test "credit increases balance" {
  val initial = makeTestAccount(balanceCents = 5_000)
  val amount  = Amount.make(Cents.tryFrom(2_000).unwrap()).unwrap()

  val result = credit(initial, amount)
  assertTrue(result.isOk, "credit should succeed when no overflow")
  assertEqualInt(balanceOf(result.unwrap()).toLong(), 7_000, "balance after credit")
}

test "debit fails when insufficient funds" {
  val initial = makeTestAccount(balanceCents = 100)
  val amount  = Amount.make(Cents.tryFrom(500).unwrap()).unwrap()

  val result = debit(initial, amount)
  assertTrue(result.isErr, "debit should fail when balance too low")
}
```

When a test fails, the output names the test and the assertion:

```
Account: "debit reduces balance by the amount"
  FAILED: assertEqualInt
    actual:   6500
    expected: 7000
    label:    "balance after debit"
```

The compiler assigns each test block a name from its string literal. Names must be unique within a test module; duplicate names are a compile error.

## §14.3 Unit tests in practice

Here is a complete test file for a `divmod` utility — a function that returns the quotient and remainder of integer division:

```lyric
// math.l
package Math

pub func divmod(n: Int, d: Int, q: out Int, r: out Int)
  requires: d != 0
{
  q = n / d
  r = n % d
}
```

```lyric
// math_test.l
@test_module
package Math

import Std.Testing
import Math.divmod

test "basic division" {
  var q: Int = 0
  var r: Int = 0
  divmod(17, 5, q, r)
  assertEqualInt(q, 3, "quotient of 17 / 5")
  assertEqualInt(r, 2, "remainder of 17 / 5")
}

test "zero remainder" {
  var q: Int = 0
  var r: Int = 0
  divmod(12, 4, q, r)
  assertEqualInt(q, 3, "quotient of 12 / 4")
  assertEqualInt(r, 0, "remainder of 12 / 4")
}

test "negative numerator" {
  var q: Int = 0
  var r: Int = 0
  divmod(-7, 2, q, r)
  assertEqualInt(q, -3, "quotient of -7 / 2")
  assertEqualInt(r, -1, "remainder of -7 / 2")
}
```

Each `test "..." { }` block runs independently. A failure in one block does not cancel the others; `lyric test` reports all failures in a single pass.

The test runner exits with a non-zero status code when any test fails, making it straightforward to gate CI on `lyric test`.

## §14.4 Snapshot testing

Snapshot tests capture a string output on the first run and compare against it on subsequent runs. They are useful for formatted output, rendered reports, serialized data, or anything where the expected value would be tedious to write by hand.

```lyric
@test_module
package Reports

import Std.Testing.Snapshot
import Reports.{generateReport, sampleData}

test "report format" {
  snapshotMatch("report", generateReport(sampleData()))
}
```

The first time this test runs, it creates `snapshots/report.txt` with the actual output and exits with success. On every subsequent run it compares the actual output against the saved file. A mismatch fails the test and prints a diff:

```
Reports: "report format"
  FAILED: snapshot mismatch for "report"
  --- snapshots/report.txt
  +++ actual
  @@ -1,3 +1,3 @@
   Date: 2026-01-01
  -Total: $1,000.00
  +Total: $1,500.00
   Items: 3
```

When you intentionally change the output — say, you updated the report format — regenerate the baseline with:

```sh
lyric test --update-snapshots
```

This overwrites all snapshot files with the current actual output and then runs the tests normally. Commit the updated snapshot files alongside your source code; they are part of the test contract.

Snapshot files live in a `snapshots/` directory relative to the test source file. The label you pass to `snapshotMatch` becomes the filename (`"report"` becomes `snapshots/report.txt`). Labels must be unique within a package.

::: note
**Note:** Snapshot tests are included in the default `lyric test` run. They are not a separate mode. The `--update-snapshots` flag is only for regenerating baselines.
:::

## §14.5 Property-based testing

A property test states an invariant that should hold for all inputs of a given type, then lets the runtime search for a counterexample. Where a unit test checks the cases you thought of, a property test searches the space you didn't.

```lyric
@test_module
package SortedSet

import Std.Testing
import SortedSet.{SortedSet, insert, contains, remove, empty}

property "insert then contains" {
  forall (s: SortedSet[Int], x: Int) {
    val updated = insert(s, x)
    expect(contains(updated, x))
  }
}

property "insert is idempotent" {
  forall (s: SortedSet[Int], x: Int) {
    val once = insert(s, x)
    val twice = insert(once, x)
    expect(once == twice)
  }
}

property "remove undoes insert when not previously present" {
  forall (initial: SortedSet[Int], x: Int)
    where not contains(initial, x)
  {
    val inserted = insert(initial, x)
    val removed = remove(inserted, x)
    expect(removed == initial)
  }
}
```

The `where` clause on the third property is a precondition guard. The generator skips any input that fails the guard rather than counting it as a test case. The property is checked against 100 valid inputs by default (configurable with `--property-trials`).

The generators for common types are built in:

- **All primitives** (`Int`, `Long`, `Bool`, `Double`, `String`, etc.) have built-in generators covering the full range and interesting edge cases (0, -1, `Int.max`, empty string, and so on).
- **Records** are generated field-by-field from the field types' generators.
- **Unions** pick a random case and generate the payload for that case.
- **Opaque types with invariants** generate values that satisfy the declared invariant by construction. A `SortedSet[Int]` generator never produces an unsorted or non-unique set; the generator respects the type's invariant.
- **Range subtypes** generate values within the declared range.

When a property fails, the runner prints the minimal failing input after shrinking:

```
SortedSet: "insert then contains"
  FAILED after 12 trials
  Shrunk to minimal failing case:
    s = SortedSet([])
    x = 0
  Counterexample:
    expect(contains(updated, x)) was false
```

Shrinking reduces the failing input to the smallest version that still fails, which makes diagnosis much easier than working from whatever random large value first triggered the problem.

::: sidebar
**Why property testing?** Unit tests check cases you thought of. Property tests search for counterexamples you didn't think of. The combination is more powerful than either alone.

There is a deeper integration with Lyric's contract system: when a function has a contract `ensures:` clause, `lyric test --properties` can automatically generate a property test from it. If `insert` declares `ensures: contains(result, x)`, that postcondition becomes a property test for free. You get contract verification at runtime without writing extra test code. This is one of the payoffs of combining a contract-rich type system with built-in testing — the spec and the test share the same expression.

This behavior is covered in Chapters 16–18, which go into depth on `@runtime_checked` and `@proof_required`.
:::

Property tests are not included in the default `lyric test` run because they are slower. Run them with:

```sh
lyric test --properties
```

In CI, run `lyric test --properties` separately, perhaps on a longer schedule or only on certain branches.

## §14.6 Doctests

Code blocks inside `///` doc comments are extracted and run as tests. This keeps examples in documentation from going stale.

```lyric
/// Computes the area of a shape.
///
/// ```lyric
/// import Std.Testing
/// import Shape.{Shape, area}
///
/// val c = Shape.Circle(radius = 1.0)
/// expect(area(c) > 3.14 and area(c) < 3.15)
/// ```
pub func area(s: in Shape): Double {
  return match s {
    case Circle(r) -> 3.14159265 * r * r
    case Rectangle(w, h) -> w * h
  }
}
```

The doctest block is a complete snippet: it may include its own imports and multiple statements. The test runner treats each block as an anonymous test. If the block raises a `Bug` or an assertion fails, the test fails and the output identifies the file and line number of the failing doc comment.

To opt a block out of doctest execution — for pseudocode, incomplete examples, or code that requires external services — add `// no_test` as the first line of the block:

```lyric
/// ```lyric
/// // no_test
/// val result = externalService.fetch(id)   // illustrative only
/// ```
```

Doctests run when you pass `--doctests`:

```sh
lyric test --doctests
```

They are not included in the default `lyric test` run, since they require imports and setup that can make them slow or environment-dependent. Including them in CI alongside `lyric test --properties` is a good practice.

## §14.7 Running tests

A summary of the available modes:

```sh
lyric test                          # unit tests and snapshot tests
lyric test --properties             # also run property tests (slower)
lyric test --doctests               # also run doc comment code blocks
lyric test --update-snapshots       # regenerate snapshot baselines
lyric test --filter "transfer"      # substring match on test name
lyric test --filter "debit" --properties  # flags compose
```

All flags compose. `lyric test --properties --filter "sorted"` runs only property tests whose names contain "sorted".

Exit codes follow the convention: 0 for all passing, non-zero for any failure. Test output goes to stdout. The runner prints a summary line at the end:

```
14 passed, 0 failed, 2 skipped (guard failures in property tests)
```

Skipped counts reflect property test inputs that were discarded due to `where` guards. They are not failures.

## Exercises

1. **Username validator**

   Write a `validateUsername` function that returns `Result[String, String]` — the original username on success, an error message on failure. It should reject empty strings, strings longer than 20 characters, and strings containing spaces. Write three `test` blocks: one for an empty input, one for a 21-character input, and one for a valid input. Run `lyric test` and confirm all three pass.

2. **Property test for range subtype addition**

   Define `type Percentage = Int range 0 ..= 100`. Write a property test that verifies: for any two `Percentage` values `a` and `b` where `a + b <= 100`, the result of `Percentage.tryFrom(a.toInt() + b.toInt())` is `Ok`. Confirm the property holds and that the `where` guard correctly filters out inputs that would overflow the range.

3. **Snapshot test with format change**

   Write a `formatSummary` function that returns a multi-line string. Write a snapshot test for it. Run `lyric test` once to capture the baseline, then change the format (add a line, change a label). Observe the diff on the next run, then run `lyric test --update-snapshots` to accept the new format. Commit both the source change and the updated snapshot.

4. **Deliberately wrong doctest**

   Add a `///` doc comment to a function with a code block that contains a false assertion — for example, `assertEqualInt(1 + 1, 3, "arithmetic")`. Run `lyric test --doctests` and observe the failure. Then fix the assertion and confirm the doctest passes.

5. **Property test with a precondition guard**

   Write a property test for a `remove` operation on a sorted set (or a similar data structure you have). State the property: for any set `s` and element `x` where `x` is not already in `s`, inserting then removing `x` returns a set equal to `s`. Use `where not contains(s, x)` as the guard. Observe how many inputs are discarded due to the guard versus how many are actually tested. Adjust the trial count with `--property-trials 500` and note the difference.
