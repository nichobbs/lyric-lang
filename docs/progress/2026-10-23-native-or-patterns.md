# Native or-patterns (#8428)

- Native backend: `emitPatternTest` lowers `case A | B ->` (`POr`). Each alternative is tested in turn and jumps to
  its own success block, which branches to a shared join; a name the alternatives bind (the checker requires
  the same names in each) becomes a phi of the value each alternative produced, so reference-typed bindings
  keep their ARC handling. Or-patterns nest inside tuple and constructor patterns.
- `native_enum_pattern_scrutinee_self_test.l` gains five cases: enum cases, literals, an integer and a
  `String` binding shared by two union cases, and an or-pattern inside a tuple pattern.
- Still not lowered on native: record, type-test and const-reference patterns (the panic names the supported forms).
