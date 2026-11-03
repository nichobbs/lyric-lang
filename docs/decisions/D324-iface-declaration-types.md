# D324 - Package interface declaration detail on `Lyric.Tir.Ty` (docs/70 phase 5a, #8615)

**Status:** shipped (types and signatures). Second slice of phase 5a, after
D321. Format version 2.

## Context

D321 shipped the interface header and the declaration index. docs/70 §9.2 also
lists, per declaration, generic parameters with bounds, full types, fields,
cases, signatures with parameter modes, and constant values. `Lyric.Tir`'s `Ty`
(D319) is the type language §9.2 names.

## Decision

1. **`Ty` names declarations by DefPath.** A `Ty` holds a `SymbolId`, which
   exists only within one compilation. The codec writes the declaration's
   DefPath key and a reader interns it into its own `DefPathInterner`
   (`internDefPathKey`, new in `Lyric.Symbols`). Two compilations whose ids differ
   write identical bytes. A built-in type with no declaration (negative id) is
   written as that number. A type that names a declaration with no DefPath
   cannot be encoded: `encodeIface` returns `Err`, and `decodeIface` and
   `dumpIface` take the interner.
2. **`IfDetail`** per declaration: `IfDFunc` (generic parameters, parameters with
   mode and `hasDefault`, result, `isAsync`, `isAxiom`, `isPure`, the function's
   own verification level when it differs from the package's), `IfDRecord`
   (records, exposed records, protected types), `IfDType` (unions, enums, opaque
   types, interfaces), `IfDAlias` (alias and distinct types, a range subtype's
   underlying type is a `TRefined`), `IfDCase`, `IfDValue` (type, `var`, a
   constant's literal) and `IfDExtern`. Cases and members are declarations of
   their own with a DefPath nested under their type's.
3. **Encoding.** Tagged `Ty`, integers as minimal LEB128, a bound or constant
   `Long` as eight little-endian bytes (fixed width keeps it canonical), a
   `Double` as its IEEE bits (`Std.Math.doubleToBits`), an array length or
   parameter index shifted so `Self` (`-1`) is non-negative. A reader limits
   nesting to 200 levels.
4. **Format version 2.** The layout changed; no consumer reads interfaces yet
   (D321), so version 1 is not read.
5. **Still deferred, no placeholder fields:** default values (`hasDefault` says a
   call may omit the parameter or field), contracts, bodies and invariants as
   TIR expressions need the 3a builder; the linkage table and hidden exports are
   5b. Building an `Iface` from a checked package is the producer slice.

## Consequences

- The dump prints each declaration with its detail, types by DefPath key, so
  the I0005 round trip compares complete text.
- Extending a detail record is a format-version bump until a consumer exists.
