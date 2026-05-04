# Visibility and Modules

In many languages, visibility is advisory. You put something in a `private` method and trust that other developers on your team won't work around it. In Java or C# the language gives you mechanisms, but also gives you `setAccessible(true)` and reflection as escape hatches. The discipline is cultural. Culture drifts.

Lyric's visibility system is structural. A package-private declaration is not accessible from outside its package — there is no workaround, no reflection escape hatch, no internal-but-not-really annotation. When you compile a package, the compiler emits only the public declarations into the contract artifact that other packages compile against. The private internals are not merely hidden; they are absent.

This chapter explains how Lyric's module system works, why it is organised around packages rather than files, and what happens at compilation boundaries.

## Packages and files

A package corresponds to a directory. Every `.l` file in the same directory belongs to the same package and carries a matching package declaration at the top:

```lyric
// account.l
package Account

// accountValidator.l (same directory)
package Account
```

Both files are part of the `Account` package. They can see each other's declarations as freely as if they were a single file. There is no `internal` keyword or `friend` mechanism — if you are in the same package, you have full access.

Sub-packages live in subdirectories. A file in `account/internal/` declares `package Account.Internal`. From the compiler's point of view `Account` and `Account.Internal` are separate packages with no special relationship to each other — the name hierarchy is a convention, not a visibility rule. If you want `Account.Internal` to be truly internal, simply don't re-export anything from it.

File names are not meaningful to the compiler. You can name a file anything you like; what matters is the `package` declaration. `lyric fmt` enforces the convention that the file name matches the package name in lowercase, but the compiler itself doesn't care.

```lyric
// Any of these names would be fine for a file in the account/ directory:
package Account    // account.l, accountService.l, whatever.l — all valid
```

## The `pub` keyword

By default, every declaration is package-private: invisible outside the package. You make something public by adding `pub`:

```lyric
pub type AccountId = Long range 0 ..= MAX_ACCOUNT_ID    // visible outside
pub func openAccount(owner: in CustomerId): AccountId   // visible outside

func internalHelper(x: in Int): Int                     // package-private
```

`pub` applies to type declarations, functions, constants, interfaces, and union cases. For records, it applies at the field level too:

```lyric
pub record Customer {
  pub id: CustomerId          // visible
  pub email: Email            // visible
  internalNotes: String       // package-private
}
```

Here `Customer` is a public type, so callers outside the package can name the type and accept values of it. But `internalNotes` is package-private. Callers outside the package cannot read or write it, and more importantly, cannot construct a `Customer` using the default record constructor — the compiler rejects any construction expression that would require naming a private field.

This means a `pub` record with private fields needs a constructor function:

```lyric
pub func makeCustomer(id: in CustomerId, email: in Email): Customer {
  return Customer(
    id = id,
    email = email,
    internalNotes = ""
  )
}
```

Outside the `Account` package, callers use `makeCustomer`. Inside it, they can use the record syntax directly. This is Lyric's way of making smart constructors the default rather than a workaround.

::: sidebar
**Why not classes with access modifiers?** Class-based languages put visibility on each member and rely on developers to get it right per-field. Records in Lyric are structurally transparent by default inside their package and can be selectively exposed outside. The key difference is that the *construction* rule is automatic: if you expose a partial record, the compiler requires a constructor function without any extra annotation. You cannot accidentally expose a private field through direct construction.
:::

## Imports

Names from other packages are not in scope until you import them:

```lyric
import Money.{Amount, Cents}           // named imports
import Time.Instant                    // single name
import std.collections.{Map, Set}
import std.collections as Coll         // alias the entire package
```

When you use the `as` form, you access its names through the alias: `Coll.Map`, `Coll.Set`. When you use the named form, the names are in scope directly.

There are no wildcard imports. `import Money.*` is a compile error. Every imported name must be written explicitly:

```lyric
// Good — every name is visible at a glance
import Account.{Account, AccountId, openAccount, closeAccount}

// Not valid — rejected by the compiler
import Account.*
```

Re-exports let a package surface names from its dependencies as part of its own public contract:

```lyric
pub use Money.Amount    // re-exports Amount as part of this package's surface
```

Callers of your package can then import `Amount` from you rather than having to know it originates in `Money`. This is useful for facade packages that present a unified surface over several implementation packages.

The formatter enforces alphabetical ordering of import blocks. This is not just style: alphabetical ordering makes it possible to scan the import section and find a name in O(log n) with your eyes. When you are doing a refactoring and want to know where `Amount` is imported from, you look at the `A` section.

::: sidebar
**Why no wildcard imports?** Wildcard imports make it hard to trace where a name comes from — especially when two packages have types with similar names. In a codebase that uses explicit imports, one `grep` tells you which package `Amount` comes from. Lyric's formatter also enforces alphabetical import ordering, so import sections are scannable even in files with a dozen imports. This is a low-ceremony rule that pays for itself on the first refactoring.
:::

## Contract metadata

Every compiled Lyric package produces two artifacts:

- `<package>.lyrasm` — the .NET assembly containing the compiled IL
- `<package>.lyric-contract` — JSON metadata: all `pub` signatures, contracts, type parameters, and projection types

Downstream compilation uses the contract metadata, not the source. When you compile a package that imports `Money`, the compiler reads `Money.lyric-contract` to learn what `Amount` is, what its constraints are, what functions operate on it, and what their contracts say. It never touches `money.l`.

This separation has a practical consequence: if you change a function body without changing its public signature or contracts, downstream packages do not need to recompile. Their `.lyric-contract` dependency has not changed. Incremental builds are fast not because the build tool is clever, but because the language design makes the dependency surface small and explicit.

Contract metadata is also what powers `lyric public-api-diff`. Given a git ref, the tool compares the current `pub` surface against the previous version and reports whether any changes are breaking — additions are fine, removals are major, signature changes are major, contract narrowing is major. This runs in CI.

## Split-file mode

Most teams will author Lyric in the default unified mode: a single `.l` file per logical unit, with `pub` declarations and implementations together.

Teams that want Ada-style discipline can opt in to split files in `lyric.toml`:

```toml
[project]
file_layout = "split"
```

In split mode, you author each package as two files:

- `<package>.lspec` — `pub` declarations only (signatures, type aliases, interface definitions)
- `<package>.lbody` — implementations of the declared items

The semantics are identical to unified files. The compiler treats them as one package. The split is purely an authoring discipline: it enforces that every public function is declared before its body is written, which makes API review straightforward — reviewers can look at the `.lspec` diff to understand the API change without reading the implementation.

This mode is not for everyone. If your team does code review on unified files and has good tooling, the split adds ceremony without benefit. The option exists for teams migrating from Ada, or for safety-critical codebases where the API-first discipline is load-bearing.

## Stability annotations

On `pub` items, you can mark API stability:

```lyric
@stable(since="1.0")
pub func transfer(from: in AccountId, to: in AccountId, amount: in Amount): Result[Receipt, TransferError] {
  ...
}

@experimental
pub func bulkTransfer(transfers: in slice[TransferRequest]): Result[slice[Receipt], TransferError] {
  ...
}
```

`@stable(since="X.Y")` means the item's signature and semantics will not change in a breaking way from version `X.Y` onward — any removal or signature change is a SemVer major bump. `@experimental` means the item may change or disappear without a major version bump.

The compiler enforces one direction: a non-experimental `pub` function may not call `@experimental` items in the same package. This prevents stable APIs from accidentally depending on unstable ones. If you are stabilizing `transfer`, you must also stabilize everything it calls:

```lyric
@stable(since="1.0")
pub func transfer(...): Result[...] {
  bulkTransfer(...)    // compile error S0001: stable function calls experimental
}
```

The stability information is embedded in the `.lyric-contract` artifact, so `lyric public-api-diff` can determine whether a change requires a major version bump without re-parsing source.

Unannotated `pub` items are treated as stable by the enforcement rules — omitting `@experimental` is not a license to break things.

## `@test_module` access

Test packages need access to package internals that are deliberately hidden from production consumers. Lyric provides a single mechanism for this:

```lyric
@test_module
package Account

test "internal helper handles edge case" {
  expect(internalHelper(0) == 0)    // can access package-private internalHelper
}
```

A package annotated `@test_module` can access non-`pub` declarations of the package it tests. It is the only mechanism for crossing the visibility boundary in tests. You cannot bypass it with a `pub` field that is only used in tests, or with a reflection call that the language would reject anyway.

The `@test_module` annotation is a signal to the compiler and to readers: this is test code; it has elevated access; it is not part of the production contract. Chapter 14 covers testing in full.

## Exercises

1. Create two packages in different directories: `Greet` (with a `pub func greet(name: in String): String`) and `Main` (that imports and calls it). Observe what happens if you remove `pub` from `greet`. What error does the compiler produce, and at which line?

2. Write a `pub record Product` with two `pub` fields (`name: String` and `priceCents: Int`) and one private field (`internalCode: String`). Try to construct it from outside the package using the record syntax. What error do you get? Now write a `pub func makeProduct(name: in String, priceCents: in Int): Product` inside the package that constructs it. Confirm the external caller compiles.

3. Try `import Std.*` (a wildcard import). What does the compiler say?

4. Add `@experimental` to a `pub` function, then call it from a `@stable(since="1.0")` function in the same package. What diagnostic does the compiler produce? Now remove `@stable` from the caller — does the error go away?

5. Create three packages: `Domain`, `Infrastructure`, and `App`. Have `Infrastructure` import from `Domain`, and `App` import from both. Try adding `import App.{SomeType}` to `Domain` — what happens? What does this tell you about circular dependencies?
