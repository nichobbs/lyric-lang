# 2026-09-28 — Lint: package-private type in a pub signature (L007, #7549)

`lyric lint` gains a sixth AST-only rule, **L007** (warning): a `pub` or
`internal` item whose signature names a package-private (unmarked) type
declared in the same file is flagged at the declaration, before a
consumer in another package hits T0097 at every use site (docs/01 §3.1).

Checked positions, matching the issue's list: the receiver of a
type-associated function (`pub func Widget.create(...)`, including the
implicit `self` receiver of a method declared inside a `record`/
`protected type` body, docs/49); function/method/interface-method
parameters and return types; a `pub`/`internal` field of a `pub`
record or exposed record; a union case's payload (named or positional)
inside a `pub` union; a `pub`/`internal` protected-type `entry`'s or
`func` member's parameters, return type, and implicit receiver; and a
`pub val`'s declared type (`const` is a mirrored-but-unparsed AST
variant — `ConstDecl`/`IConst` exist in `parser_ast.l` but the
self-hosted parser never constructs one; L007 is written to check it
defensively, matching the equally-dead `IConst` arm already in L001,
but there is no source form that exercises it today). A record-body
method (docs/49's in-body `func` form) has no independent
`pub`/`internal` modifier at all — the grammar has no dispatch for one
there, so writing `pub func` inside a `record { }` body is a parse
error — so this rule has nothing to check for that shape beyond the
enclosing record's own field/receiver checks above; only a
`protected type`'s `func`/`entry` members support their own visibility
modifier independent of the enclosing type. Generic arguments are walked recursively (array, slice,
tuple, nullable, function-type, and generic-application shapes), and a
`pub`/`internal` type alias whose right-hand side names a private type
is treated as private too — the alias is transparent, so naming it does
not make the underlying type constructible from outside. A function's
own generic type parameters are excluded from the private-type check
(a type parameter named the same as a private record in scope is a
parameter, not a reference to that record). `pub opaque type` counts as
visible per docs/01 §3.1 ("exposes the type's existence"); a non-`pub`
opaque type is treated like any other private type. `extern type` /
`extern package` members are never registered as local type
declarations, so a reference to one is never flagged — they are FFI
host bindings, exempt from these visibility tiers.

**Scope note**: `lyric lint` works entirely from the parsed AST, one
file at a time (docs/01 §13.8) — it has no type-checker symbol table
and no cross-file view of a package. L007 therefore only sees type
declarations in the SAME file as the item it is checking; a
package-private type declared in a sibling file of a split multi-file
package (docs/19) is not visible to this pass and will not be flagged
there. This mirrors the existing L001–L005 rules' architecture rather
than introducing a new one; a package-wide registry for manifest lints is
tracked in #7607.

L006 is retired (docs/01 §14.6, superseded by A0042) and is not reused.

Implementation: `lyric-compiler/lyric/lint/lint.l` builds a small
per-file registry of type declarations (name, private/not, and — for
a type alias — its right-hand-side `TypeExpr` for alias-chasing) once
per `lint()` call, then threads it through `checkItem` alongside the
existing per-item checks. New self-test file
`lyric-compiler/lyric/lint_self_test.l` covers one positive case per
signature position plus false-positive guards (pub type, `internal`
type, generic parameter shadowing, `pub opaque type`, extern type,
package-private item referencing a package-private type, and a
package-private protected-type helper `func`). Wired into
`scripts/ci/compiler-self-tests-batch.sh`.

A repo-wide `./bin/lyric lint` sweep — every `.l` file under
`lyric-stdlib/`, `lyric-compiler/` (its `[project.packages]` manifest
covers only the CLI's own entry point, so the compiler tree was swept
file-by-file instead), and every ecosystem library at the repo root
(several of those manifests also under-list their own `src/` tree
relative to what's on disk, so those were swept file-by-file too) —
found two real hits, both fixed in this change:

- `lyric-compiler/jvm/generic_param_field_read_jvm_self_test.l`: eight
  `pub func` test helpers (`unboxInt`, `unboxString`, `firstBoxValue`,
  `secondBoxValue`, `describeOther`, `readHolderBoxValue`) took a
  same-file package-private record (`Box[T]`, `OtherRec`, `Holder`) as
  a parameter with no reason to be `pub` at all — the file is a leaf
  `@test_module` never imported by anything else. Fixed by dropping
  `pub` from all six functions (verified with `lyric test --target
  jvm`, the load-bearing target for this regression test — still
  10/10 passing).
- `examples/agent/basics.l` (an example program, not a library): `pub record User`/`Order` exposed
  `pub id: UserId` / `pub userId: UserId` / `pub totalCents: Cents`
  fields whose declared types (`type UserId = Long derives …`, etc.)
  had no `pub`/`internal` modifier — exactly the bug this rule exists
  to catch, and a real one: these distinct types are clearly meant to
  be part of the record's public API. Fixed by adding `pub` to all
  three `type` declarations. This file has pre-existing, unrelated
  parse errors elsewhere (a stale `opaque type` body-member syntax and
  a stale `{Int -> Int}` function-type literal, present before this
  change) that make it fail `lyric check` regardless, tracked in #7606; `lyric lint` and
  `lyric fmt` don't gate on parse success so the fix and its
  verification (`lyric lint`, `lyric fmt --write`) still stand on their
  own for the lines this change touches.

No other hits — consistent with the #7499 repo scan the issue cites
for the tracked package trees.

Docs updated to match: `docs/01-language-reference.md` §3.1 (mentions
the lint next to the T0097 use-site rule) and §13.8 (new table row);
`book/chapters/01-getting-started.md` and
`book/chapters/appendix-b-quick-reference.md` (lint code lists).
