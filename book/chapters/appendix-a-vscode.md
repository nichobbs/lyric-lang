# Appendix A: The VS Code Extension

## Installation

The Lyric VS Code extension is backed by `lyric-lsp`, a language server built from the same compiler pipeline that `lyric build` uses. You will need VS Code 1.70 or later and the Lyric compiler built from source.

**Prerequisites:**

- VS Code 1.70+
- The Lyric compiler built: `cd compiler && dotnet build Lyric.sln`

**Step 1.** Build and publish the language server binary:

```sh
cd compiler
dotnet publish src/Lyric.Lsp -c Release -o ../bin/lsp
```

The resulting binary is `bin/lsp/lyric-lsp` on Linux and macOS, or `bin/lsp/lyric-lsp.exe` on Windows.

**Step 2.** Install the extension's Node.js dependencies and compile the TypeScript:

```sh
cd lyric-vscode
npm install
npm run compile
```

**Step 3.** In VS Code, open the `lyric-vscode/` folder and press `F5`. This launches an Extension Development Host — a second VS Code window that has the Lyric extension active.

**Step 4.** If `lyric-lsp` is not on your `$PATH`, tell the extension where to find it via VS Code settings (see below). The extension will fail to start the language server silently if the path is wrong; check the Output panel (`Lyric Language Server` channel) if diagnostics do not appear.

## VS Code settings

```json
{
  "lyric.serverPath": "/absolute/path/to/lyric-lsp"
}
```

If `lyric-lsp` is on your `$PATH`, you can omit this setting entirely. The extension will find the binary automatically.

To format Lyric files on save, add the following to your settings:

```json
{
  "[lyric]": {
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "lyric-lang.lyric"
  }
}
```

## Features

The language server runs the full lex → parse → type-check pipeline on every document change. The results are cached so that hover, completion, and go-to-definition requests are served from the cached typed AST rather than re-checking from scratch on every query.

| Feature | Details |
|---------|---------|
| Real-time diagnostics | Lex → parse → type-check on every keystroke; errors and warnings appear as underlines with full compiler messages |
| Hover | Full resolved signature and doc comments for any top-level name, including type parameters resolved to their declared names |
| Go-to-definition | Jump to the definition of any top-level name (`F12` or Ctrl+click / Cmd+click) |
| Completion | All top-level names visible at the cursor position, including names from imported packages; imports are suggested automatically |
| Signature help | Parameter hints triggered by `(` and `,`; shows the full function signature with the active parameter highlighted |
| Workspace support | Cross-file diagnostics across all `.l` files in the open workspace; go-to-definition resolves across package boundaries |

Cross-file features depend on the workspace being opened as a folder (not a single file). The server scans all `*.l` files under the workspace root on startup and rebuilds the index when files are created or deleted.

## Syntax highlighting

The extension ships a TextMate grammar (`syntaxes/lyric.tmLanguage.json`) that covers:

- Keywords and operators
- `@annotation`-style keywords (`@stable`, `@experimental`, `@proof_required`, `@runtime_checked`, and others)
- Contract clauses (`requires:`, `ensures:`, `invariant:`)
- String interpolation (`${...}`)
- Numeric literals, including range-subtype notation
- Doc comments (`///` item comments and `//!` module comments)
- Regular line comments (`//`)

Bracket pairs, auto-close rules, and comment-toggling shortcuts are configured in `language-configuration.json`.

## Formatting

`lyric fmt` is invoked via VS Code's Format Document command (`Shift+Alt+F` on Windows/Linux, `Shift+Option+F` on macOS). The formatter has no configuration; the format is what it is.

To format on save, add the settings shown in the VS Code settings section above. The `editor.defaultFormatter` key is required if you have other formatters installed that also claim `.l` files.

## Known limitations

- Completion currently covers symbols in the open file and directly imported packages. Transitive imports (packages imported by your dependencies) are not included in completion lists. Cross-package completion from transitive dependencies is planned for a future milestone.
- Go-to-definition resolves to source files within the workspace. Definitions in compiled-only packages (those present only as `.dll` files in the NuGet cache) are not navigable; the command falls back to showing the hover information instead.
- The server performs a full type-check on every change. On very large workspaces (hundreds of `.l` files), first-keystroke latency after opening may be noticeable while the workspace index is built. Subsequent edits are served from the cache and are fast.

## Troubleshooting

**"Language server failed to start"**

Check that `lyric.serverPath` points to the correct binary for your platform (`lyric-lsp` or `lyric-lsp.exe`). Verify the binary is executable (`chmod +x bin/lsp/lyric-lsp` on Linux/macOS). The Output panel (`View → Output`, then select `Lyric Language Server` from the dropdown) shows the exact error from the extension host.

**No diagnostics appearing**

Confirm that the file is saved with a `.l` extension — the extension activates only on `.l` files. Check that the file begins with a `package` declaration; the parser requires it and will report a parse error rather than silently producing no output if it is missing.

**Slow startup on first keystroke**

The language server builds the workspace index and type-checks all open files when it starts. On a cold start with a large workspace this can take a few seconds. Subsequent keystrokes are served from the cache and should feel instant. If slowness persists beyond the first check, confirm that `LYRIC_STD_PATH` is set correctly so the server does not need to search for the standard library on each invocation.

**Extension Development Host shows no Lyric support**

If pressing `F5` in the `lyric-vscode/` folder opens an Extension Development Host but `.l` files show no syntax highlighting or diagnostics, check that `npm run compile` completed without errors. The compiled output lives in `out/`; if that directory is empty or missing, the extension has no entry point to load.

## See also

The language server source is at `compiler/src/Lyric.Lsp/`. The end-to-end test suite for the LSP protocol is in `compiler/tests/Lyric.Lsp.Tests/ProtocolTests.fs`; reading those tests is the fastest way to understand exactly which LSP methods the server implements and what responses it produces.
