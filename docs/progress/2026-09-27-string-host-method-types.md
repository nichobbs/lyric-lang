# Real types for the `String` host-method surface, closing #7335 (D-progress-1000)

`stringHostMethodType` in `Lyric.TypeChecker`
(`lyric-compiler/lyric/type_checker/typechecker_exprs.l`) now gives
`.substring`, `.trim`/`.trimStart`/`.trimEnd`, `.replace`,
`.contains`/`.startsWith`/`.endsWith`, `.toLower`/`.toUpper`,
`.isNormalized`/`.normalize`, and `.split` real `TyFunction` types on a
`String` receiver, mirroring what `stringIndexOfMember` (#6496) already did
for `.indexOf`/`.lastIndexOf`. Before this, every one of these methods typed
as `TyError` — the checker's universal unifier — so a call through one of
them ran with no argument validation and its result silently unified with
whatever the caller expected next, hiding every downstream type error. See
D-progress-1000 for the full design (including why this stops short of a
general "unknown `String` method" diagnostic — D-progress-971 tried that for
#7099 and reverted it, since JVM's real `String`-method surface is wider
than MSIL's closed cascade).

Verified with `typechecker_self_test.l`'s new cases (the issue's own repro,
now a `T0129` type error instead of compiling clean, plus per-method arity/
argument-type coverage) and a full ecosystem regression
(`for d in lyric-*/; do ./bin/lyric test --manifest $d/lyric.toml; done`)
against a pre-change baseline — no new failures.

Docs updated: docs/01-language-reference.md §12.1 and
book/chapters/appendix-b-quick-reference.md.
