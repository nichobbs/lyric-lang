# D223 - `List` sizes with `.count`; `.length` on a `List` is T0207

**Status:** shipped (#7218).

## Context

`List[T]`'s size member is `.count`. `builtinMember` types only `count` and `toArray` for the stdlib `List`, but an
unknown member on a `List` receiver degraded silently to an error type, so `xs.length` type-checked with no
diagnostic. Each backend then decided for itself: `--target dotnet` lowered the member name `length` to `Count` and
compiled it, `--target jvm` rejected it (`J009`), and `--target native` had no such member. Code written and tested
against MSIL, including the compiler's own packages, `lyric-otel` and several test modules, therefore failed only when
built for another target.

## Decision

1. The front end decides. `.length` (member or call form) on the stdlib `List` is the type-check error **T0207**, and
   its message names `.count`. `.length` stays the size member of `String`, `slice[T]` and arrays.
2. The receiver is recognised by identity (`isStdCollectionsHostType`, the same test the `List` members `.count` and
   `.toArray()` use), so a package's own `record List[T]` is not affected and keeps the ordinary field rules.
3. The alternative, documenting `.length` as an alias typed in `builtinMember` and lowered on every target, was
   rejected: it keeps two spellings for one member, and the documented API has always been `.count`.
4. The check lives in `maybeUnknownMemberDiag` (the A5 unknown-member path, docs/59 section 5.1), which both the
   field-style and the call-style member paths reach, rather than in a lint: an accepted-invalid program that only one
   backend rejects is a type error, like the other unknown-member diagnostics (`T0113`, `T0116`).

## Migration

Every `.length` on a `List` in the repository was migrated to `.count` in the same change, found by checking every
package, test module and example with the new diagnostic rather than by text search. The compiler sources were
migrated in the same PR, so both the stage-0 seed (which lacks the check) and the new compiler accept them.
