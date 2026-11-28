# D873: the native TIR lowering takes a case pattern under another case pattern

Status: accepted (docs/70 phase 4a, part 9; D520 slice 50).

## Decision

A sub-pattern of a case field is tested and bound through the union it matches: `Err(Malformed(at, why))` opens the `Result` payload as the inner union, tests its discriminant and stores the inner bindings. The sub-pattern used to go to the scalar pattern test, which knows only enums, so the function fell back with "a case pattern on a value that is not an enum" (the largest root of the census, 8 functions). `scripts/ci/native-via-tir/nestedpat.l` pins it and checks that nothing stays on the AST path.
