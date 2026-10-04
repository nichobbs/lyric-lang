# D-progress-1038 — CommonJS exports of an NPM import

**Status:** shipped (W5 follow-up)

Refines D-progress-1037 (a reviewer found the gap).

Node exposes a CommonJS package's named exports on the `import()` namespace only
when its static scan can see them. A package that assigns exports at runtime
(`o['add'] = ...; module.exports = o`) shows just `default`, so a shim naming
`add` failed `B0062` and, in the module shape, failed at `instantiate`.

## Decision

1. **Glue.** The loaded namespace is wrapped so a name missing from it is read from
   `default` when that is an object or function. A namespace member always wins.
2. **Probe.** The `B0062` export probe reports the union of the namespace keys and
   the keys of `default`, so the build check and the runtime see the same names.
3. **Not a warning.** Demoting `B0062` for CommonJS packages would let a real typo
   through, and the union is exact for `module.exports` objects.

A package whose `module.exports` is a function with properties is covered the same
way (`default` is a function). Exports defined behind a getter that throws are not
enumerable by the probe and stay out of scope.
