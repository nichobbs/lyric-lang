# NPM shims from `.d.ts` (docs/35 W5 follow-up)

`lyric restore --generate-npm-shims [--force]` writes each shim from the installed package's
TypeScript declarations (D-progress-1042): plain `string`/`number`/`boolean`/`bigint` functions
become host imports, everything else is listed as skipped.

- A declaration scanner in Lyric (comments, statements, function signatures, `export {}`,
  `export =`, `export default`), `node` to find the declaration file.
- Never overwrites a hand-edited shim without `--force`.
- Tests: the scanner and renderer on a sample `.d.ts`; the whole flow against a real
  `npm install`, including `B0062` accepting the generated imports.
