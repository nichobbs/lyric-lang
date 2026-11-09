# 2026-11-09 - Every CLI command rejects what it does not take (#8321 follow-up)

#8321, #8362, #8245 and #8311 were already fixed on `main` (`rejectUnknownOption`
and `rejectExtraPositional` on bench, build, check, clean, doc, fmt, lint,
openapi, prove, run, search and test; F0050 for undeclared `--features`; prove
reading the build's package file set; each bridge owning prove's type check).
An audit of the remaining commands found the same silent-ignore class:

- `lyric restore` and `lyric publish` printed `unrecognised flag` and carried on,
  exit 0 if the rest succeeded. They now exit 1 at the flag.
- `lyric init`, `add` and `remove` took an option as the directory, package
  name or spec (`lyric init --bogus` created a directory named `--bogus`).
- `lyric public-api-diff --x a.dll b.dll` failed with a misleading "not found";
  `lyric repl` and `lyric lsp` ignored any argument; `lyric version` ignored a
  stray positional argument.

All now report `<command>: unknown option '--x'` or
`<command>: unexpected argument 'x'` on stderr and exit 1 before doing any
work. `lyric lsp` accepts `--stdio`, the option LSP clients conventionally
pass, and nothing else (the VS Code extension passes none). The `--internal-*`
dispatch is untouched.

`scripts/ci/cli-args-e2e.sh` section 1b covers each command; `run()` there now
closes stdin so the `repl` and `lsp` cases cannot wait for input.
