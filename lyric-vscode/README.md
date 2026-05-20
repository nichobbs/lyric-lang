# Lyric VS Code Extension

VS Code language support for [Lyric](https://github.com/nichobbs/lyric-lang), a safety-oriented application language targeting .NET.

## Features

| Feature | Details |
|---|---|
| Syntax highlighting | TextMate grammar for `.l` files |
| Diagnostics | Type errors and verifier failures shown as squiggles |
| Hover | Type information; proof counterexample bindings on failed `@proof_required` functions |
| Completion | Keywords, in-scope identifiers, and imported package members |
| Go-to-definition | Jumps to binding sites for local identifiers and imported symbols |
| Signature help | Parameter hints triggered on `(` and `,` |
| Code actions | Quickfixes for common verifier diagnostics (see below) |
| Rename | Word-boundary rename across all open `.l` files |
| Background diagnostics | All workspace `.l` files are analysed on startup; dependents are re-analysed on change |
| Formatter | `lyric fmt` via **Format Document** (`Shift+Alt+F`); see [note on comment preservation](#formatter) |
| Snippets | 27 snippets for functions, records, unions, contracts, loops, tests, and more (type `fn`, `rec`, `match`, …) |
| Project navigator | Explorer sidebar tree showing packages, Lyric dependencies, and NuGet dependencies from `lyric.toml` |
| Package commands | **Lyric: Add/Remove/Update dependency**, **Add NuGet package**, **Restore** in the command palette |
| Build tasks | **Lyric: Build**, **Run**, **Test**, **Prove current file** as VS Code tasks |
| `lyric.toml` validation | Semantic diagnostics on `lyric.toml`: unknown sections, missing fields, invalid versions, dead package references, missing source directories |

### Code actions

| Diagnostic | Quickfix |
|---|---|
| V0003 — `unsafe` block outside `unsafe_blocks_allowed` module | Add `@unsafe_blocks_allowed` annotation to the file |
| V0007 — proof obligation not dischargeable | Downgrade module annotation to `@runtime_checked` |
| V0008 — unknown solver result | Downgrade module annotation to `@runtime_checked` |
| V0009 — `unsafe` expression in `@proof_required` context | Wrap expression in `unsafe { }` |

## Requirements

The extension delegates all language intelligence to **`lyric-lsp`**, a
stdio-based Language Server Protocol server that ships alongside the Lyric
compiler.  You must build and install it before the extension does anything
beyond syntax highlighting.

## Building `lyric-lsp`

```sh
# From the repository root
cd bootstrap
dotnet publish src/Lyric.Lsp -c Release -o ../bin/lsp
```

This writes `lyric-lsp` (Linux/macOS) or `lyric-lsp.exe` (Windows) into
`bin/lsp/` at the repository root.  Add that directory to your `$PATH`, or
point the `lyric.serverPath` setting at the full path.

## Formatter

The extension registers `lyric fmt` as the document formatter for `.l` files.
Trigger it with **Format Document** (`Shift+Alt+F`) or enable
`editor.formatOnSave` for the `lyric` language in your VS Code settings.

### Comment preservation

> **Important:** `lyric fmt` works from the AST. The Lyric lexer discards
> plain `//` comments before the AST is built, so **the formatter will remove
> all non-doc `//` comments** from a file.
>
> Only `///` doc comments and `//!` module-doc comments survive formatting,
> because they are attached to AST nodes.
>
> This is a known limitation of the current AST-based formatter. The planned
> Phase 5 self-hosted formatter will use a CST and preserve all comments. Until
> then, use `///` for any comment you want to keep, and avoid running
> **Format on Save** on files that contain explanatory `//` comments you care
> about.

The extension shows a one-time information banner the first time you format a
file as a reminder. You can disable the formatter entirely with
`"lyric.format.enable": false`.

## Extension settings

| Setting | Default | Description |
|---|---|---|
| `lyric.serverPath` | `"lyric-lsp"` | Path to the `lyric-lsp` executable. Set to an absolute path if the binary is not on `$PATH`. |
| `lyric.trace.server` | `"off"` | LSP trace level (`"off"`, `"messages"`, `"verbose"`). View output in the **Lyric Language Server Trace** output channel. |
| `lyric.cliPath` | `"lyric"` | Path to the `lyric` CLI binary. Used for build, restore, test, prove, and format commands. |
| `lyric.format.enable` | `true` | Enable/disable the `lyric fmt` document formatter for `.l` files. |

## Installing the extension (VSIX)

```sh
cd lyric-vscode
npm install
npm run compile          # or: node esbuild.mjs --minify
npx vsce package         # produces lyric-lang-0.0.1.vsix
code --install-extension lyric-lang-0.0.1.vsix
```

## Development

```sh
cd lyric-vscode
npm install
npm run watch            # incremental rebuild on save
```

Open the `lyric-vscode` folder in VS Code and press **F5** to launch an
Extension Development Host with the extension loaded.  The host picks up
`lyric-lsp` from `lyric.serverPath` (default: `$PATH`), so build the server
first as shown above.

### LSP server tests

```sh
cd bootstrap
dotnet run --project tests/Lyric.Lsp.Tests
```

The test suite exercises the full JSON-RPC dispatch layer, including
initialization, diagnostics, hover, completion, go-to-definition, code
actions, rename, and background workspace analysis.

## Architecture

```
VS Code (vscode-languageclient)
        │  JSON-RPC over stdio
        ▼
lyric-lsp  (bootstrap/src/Lyric.Lsp/)
  ├── JsonRpc.fs    — LSP framing (Content-Length headers)
  └── Server.fs     — request dispatch, document store, workspace index
        │
        ├── Lyric.Lexer / Lyric.Parser   — parse .l source
        ├── Lyric.TypeChecker            — resolve types and produce diagnostics
        └── Lyric.Verifier               — SMT proof obligations (@proof_required)
```

The server is a single-threaded stdio loop; no network sockets or named pipes
are used.  Each open document is cached with its parse tree, type-check result,
imported-file map, and proof summary so that hover and code-action requests
do not re-run the compiler.
