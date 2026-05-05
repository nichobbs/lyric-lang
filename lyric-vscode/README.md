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
cd compiler
dotnet publish src/Lyric.Lsp -c Release -o ../bin/lsp
```

This writes `lyric-lsp` (Linux/macOS) or `lyric-lsp.exe` (Windows) into
`bin/lsp/` at the repository root.  Add that directory to your `$PATH`, or
point the `lyric.serverPath` setting at the full path.

## Extension settings

| Setting | Default | Description |
|---|---|---|
| `lyric.serverPath` | `"lyric-lsp"` | Path to the `lyric-lsp` executable. Set to an absolute path if the binary is not on `$PATH`. |
| `lyric.trace.server` | `"off"` | LSP trace level (`"off"`, `"messages"`, `"verbose"`). View output in the **Lyric Language Server Trace** output channel. |

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
cd compiler
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
lyric-lsp  (compiler/src/Lyric.Lsp/)
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
