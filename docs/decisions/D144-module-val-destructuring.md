# D144 — A module-level `val` destructures irrefutable patterns only (#7763)

**Status:** accepted, implemented

## Context

The grammar has always given a module-level `val` a pattern
(`ValDecl = 'val' Pattern [ ':' Type ] '=' Expr`, grammar §3.2), and the
reference's own multiple-return example (`val (lo, hi) = minMax(xs)`, §5.3)
reads naturally at module level. But the type checker registered a module
`val` only when its pattern was a single name, and every backend (MSIL,
JVM, native) likewise only knew how to store one: `val (a, b) = (1, 2)`
compiled with no diagnostic at the declaration, and each use of `a` or `b`
was T0020 "unknown name". The reference said nothing about which patterns a
module `val` may use, or what a pattern that fails to match would do there.

## Decision

1. A module-level `val` may use any **irrefutable** pattern: a name, `_`,
   `name @ <pattern>`, a tuple of those, in any parentheses — the same set a
   `for` loop binding admits (T0112), plus `@`-bindings. Every name it binds
   is a module value with the declaration's visibility, doc comments and
   annotations.
2. A **refutable** pattern (constructor, record, literal, range, type-test,
   alternative or const pattern, at any depth), or a tuple pattern whose
   shape the initializer's type cannot have, is **T0144**. A module value has
   no failure path: there is no enclosing function to return from and no
   `match` arm to fall through to, and panicking during package
   initialization would fail every use of the package far from the cause.
   `val n is Int = 3` is rejected with a hint to write `val n: Int = 3`.
3. The initializer is evaluated exactly once, in declaration order with the
   package's other module values. A tuple pattern over a tuple literal of
   the same arity binds element by element; any other initializer is held
   in a compiler-synthesized module value (`__lyric_modval_<n>`) that each
   name is projected from.
4. A tuple type annotation types each element. Otherwise each name takes
   its checked type.

## Implementation

The front end rewrites the declaration, not each backend:
`Lyric.TypeChecker.desugarModuleValPatterns` runs in
`Lyric.Pipeline.pipeExpandAndRewrite` (after docs/58 wire expansion, before
the import-alias rewrite), so the checker, every backend and every sibling
package that imports the declaring one see only single-name `val`s. The
checker applies the same rewrite on entry, so callers outside the compile
pipeline (the language server) get the same bindings and T0144. After
checking, `recordModuleValTypes` / `annotateModuleVals` write each projected
name's checked type onto its declaration: MSIL and JVM read a tuple element
back erased and narrow it through the annotation (the #7728 rule at module
level). The synthesized temporary keeps the declaration's visibility, since
an importing package types a projected `pub` name by re-checking its
initializer, which reads the temporary.

`--target native` inlines only literal-initialized module values (#5977), so
a destructured tuple literal works there and any other initializer gets the
existing native diagnostic, exactly as for a single-name `val`.

## Alternatives

Rejecting every non-name pattern with a dedicated diagnostic was the smaller
change, but it contradicts the grammar and the reference's tuple-return
idiom. Lowering destructuring separately in each backend's module-value
code would have repeated one design three times (and in the MSIL emitter's
several field-row pre-scans); the front-end rewrite needs no backend change.
