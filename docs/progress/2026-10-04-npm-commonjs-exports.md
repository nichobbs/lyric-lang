# NPM imports: CommonJS exports Node cannot scan (docs/35 W5 follow-up)

A shim can bind an export a CommonJS package assigns at runtime (D-progress-1038).

- The module-shape glue reads a name missing from the package namespace from `default`.
- The `B0062` probe reports namespace keys plus the keys of `default`.
- Tests: the module shape under node and the `B0062` check against a real
  `npm install` of a package with a computed export.
