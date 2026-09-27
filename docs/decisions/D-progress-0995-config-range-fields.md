# D-progress-995 — Range fields in `config` blocks

**Status:** shipped

Implements the range-field part of #7229 (docs/25 §3, deferred from v1).

## Problem

A `config { }` field could only be a plain `Bool`, `Int`, `Long`, `Float`,
`Double` or `String`. Every numeric library or aspect setting sourced from
a `LYRIC_CONFIG_*` env var was therefore unconstrained. A bad value, such
as a negative TTL or a zero rate limit, was only caught by a `requires:` on
every call, which turns a configuration typo into an outage rather than a
startup failure.

## Decision

A config field may be an inline range of `Int`, `Long`, `Float` or
`Double`, written in any of the four range forms: `lo ..= hi`, `lo ..< hi`,
`lo ..` and `..= hi`.

- **Type checker** (`checkConfigBlock`, `checkConfigFieldRange`):
  - The bounds must be numeric literals, optionally negated. An integer
    field takes integer bounds within its own width. The range must not be
    empty. Anything else is G0009.
  - A default must lie inside the range, otherwise G0010.
  - Config templates (docs/58) accept the same field types. An
    instantiation overriding a ranged template field restates only the
    base type (`port: Int = 9090`) and keeps the template's range, so the
    merged default is checked (G0010) and the env value is checked at
    startup (G0004). An override that declares its own range is W0012.
  - A `pub config` template's own ranges and defaults are checked at its
    declaration (G0009/G0010, #7459), so a library that only declares a
    template catches them in its own build. An instantiation does not
    repeat a fault the template already reported. The validation is one
    shared function, `configRangeProblem` in `Lyric.Parser`, used by the
    type checker and `Lyric.WireExpand` alike; it also rejects a range on
    a non-numeric aspect config field.
- **Runtime, dotnet and the JVM:**
  - After a field is stored, the static initializer (`.cctor` /
    `<clinit>`) reads it back and compares it with each present bound.
  - On a violation it prints `error: config field B.f (env var NAME) is
    outside its range [lo, hi]` to stderr and exits 78 (G0004).
  - Floating comparisons use the unordered or NaN-biased forms (`clt.un` /
    `cgt.un`, `dcmpl` / `dcmpg`), so `NaN` fails.
  - The check runs after the store, so every branch target has an empty
    stack.
- **Aspect `config { }` blocks** (#7229's aspect half):
  - Aspect config values are compile-time literals; there is no env-var
    input yet (A0044, docs/26 §8).
  - The type checker checks an aspect's own ranged fields the same way.
  - When a `from`-instance overrides a ranged template field, the weaver's
    merge keeps the template's range. `collectFromConfigRangeDiags` then
    reports an out-of-range value as G0010. An instance field that declares
    its own range is A0048, matching W0012 for config-template overrides.
- The literal folding and range membership helpers (`foldLiteralBound`,
  `literalInRange`) live in `Lyric.Parser`, so the type checker and the
  weaver share them.

Native has no `config` block lowering at all, so there is no native runtime
check to add; config blocks on native are tracked in #7435.

Named range subtypes (`type Port = Int range 1 ..= 65535`) as config field
types are not covered here. Their values are wrapper objects, so the
config block would need to construct them through `T.from`.

## Not in this entry

Converting the library and aspect settings #7229 lists to ranged types is
tracked in the per-library issues. G0003 is not implemented: an unparseable
env value still throws from `Int32.Parse` / `Integer.parseInt` rather than
exiting 78. That is tracked in #7436.

## Tests

- `typechecker_self_test.l`:
  - "config range fields": accepted forms, an out-of-range default, an
    exclusive upper bound, a non-literal bound, an empty range, a float
    bound on an `Int`, an `Int` bound outside `Int`, and a range of
    `String`.
  - "aspect config range fields".
- `weaver_self_test.l`: a `from`-instance override below and inside the
  template's range.
- `config_block_missing_required_self_test.l`: a fixture run as a
  subprocess on dotnet and the JVM. An out-of-range `Int` and a `NaN`
  `Double` exit 78 with the field and range named. An in-range value and
  an in-range default start normally.

## Docs

- docs/25 (scope note, §3 field table, §8 G0009/G0010).
- docs/26 §4.
- Language reference, aspect weaving section.
- Book chapters 21 and 22, and appendix B.
