# 16 — LSP & VS Code Integration

## Goal

Ship a working VS Code extension (`lyric-vscode/`) backed by the existing
`lyric-lsp` server, with targeted improvements to the LSP server that make
the editor experience genuinely useful.

## What already exists

`compiler/src/Lyric.Lsp/` implements:

- JSON-RPC 2.0 stdio framing (`JsonRpc.fs`)
- Push diagnostics on every keystroke (lex → parse → type-check)
- `textDocument/hover` — top-level item name + doc comments
- `textDocument/completion` — all top-level names in the open file
- `textDocument/definition` — go-to-definition for top-level names
- End-to-end in-process test suite (`Lyric.Lsp.Tests/ProtocolTests.fs`)

## What this plan adds

| Milestone | Deliverable | Status |
|---|---|---|
| M-L1 | VS Code extension skeleton | Done |
| M-L2 | Cached typed AST in server | Done |
| M-L3 | Richer hover (full resolved signature) + signature help | Done |
| M-L4 | Cross-file / workspace support | Done |

---

## M-L1 — VS Code extension skeleton

Files delivered under `lyric-vscode/`:

| File | Purpose |
|---|---|
| `package.json` | Extension manifest: language, grammar, activation, server setting |
| `language-configuration.json` | Comment syntax, bracket pairs, auto-close |
| `syntaxes/lyric.tmLanguage.json` | TextMate grammar for `.l` files |
| `src/extension.ts` | `vscode-languageclient` wiring — spawns `lyric-lsp` |
| `tsconfig.json` | TypeScript compiler options |
| `esbuild.mjs` | Bundle script (`npm run compile`) |
| `.vscodeignore` | Excludes `node_modules`, `src/` from VSIX |

### Install & run (development)

```sh
# 1. Build the language server
cd compiler
dotnet publish src/Lyric.Lsp -c Release -o ../bin/lsp
# The binary is now at bin/lsp/lyric-lsp (linux) or bin/lsp/lyric-lsp.exe

# 2. Install extension dependencies
cd lyric-vscode
npm install

# 3. Compile extension
npm run compile

# 4. In VS Code: open the lyric-vscode/ folder, press F5 to launch the
#    Extension Development Host.  Point lyric.serverPath at the binary
#    from step 1 if lyric-lsp is not on $PATH.
```

### VS Code settings

```json
{
    "lyric.serverPath": "/absolute/path/to/lyric-lsp"
}
```

---

## M-L2 — Cached typed AST in server

`DocumentStore` now stores a `CachedDoc` (source text + `CheckResult`) per URI
instead of raw text.  Every `didOpen`/`didChange` event runs the full
lex → parse → type-check pipeline once and caches the output; hover,
completion, definition, and signature help all read from the cache without
re-parsing.

---

## M-L3 — Richer hover and signature help

### Hover improvements

Hovering over a function name now shows the full resolved signature:

```
pub async func transfer[T](from: in Account, to: in Account, amount: in T): Bool
```

Type arguments use the declared name (looked up from the symbol table) rather
than the internal `<#id>` form.

### Signature help (`textDocument/signatureHelp`)

Triggered by `(` and `,`.  Algorithm:

1. Convert LSP position to a flat offset in the source text.
2. Scan backward to find the innermost unclosed `(`.
3. Extract the identifier immediately before `(` as the candidate function name.
4. Count commas between `(` and the cursor (respecting nesting) to determine
   the active parameter.
5. Look up the function in `CheckResult.Signatures`; return a
   `SignatureHelp` object with the full label and per-parameter sub-labels.

---

## M-L4 — Cross-file workspace support

### Workspace index

On `initialize`, the server extracts `rootUri` (or `rootPath`) and builds a
`WorkspaceIndex` by scanning all `*.l` files under the root and parsing their
`package` declarations.  The index maps `"Pkg"` / `"Pkg.Sub"` to the absolute
file path.

### Import resolution

`didOpen` / `didChange` now calls `analyzeUri` instead of `analyzeText`.
`analyzeUri`:

1. Parses the file with `Parser.parse`.
2. For each `import Pkg` declaration, looks up `Pkg` in the workspace index.
3. Reads (or uses the live editor version if the file is open) the declaring
   file and collects its top-level items.
4. Calls `Checker.checkWithImports` with those items so the type checker sees
   cross-package symbols.
5. Caches a `CachedDoc` that includes a `Map<uri, SourceFile>` for each
   directly-imported file.

### Updated handlers

| Handler | M-L4 change |
|---|---|
| `textDocument/completion` | Draws from `CheckResult.Symbols.All()` (includes imported symbols) instead of just `File.Items`. Deduplicates by name. |
| `textDocument/definition` | Searches local items first; falls back to `CachedDoc.ImportedFiles` to resolve a symbol to its declaring file and span. |
| `textDocument/hover` | Searches imported files when no local item matches the identifier. |
| `workspace/didChangeWatchedFiles` | Rebuilds the workspace index so newly created `.l` files are picked up on the next keystroke. |

### Tests (5 new cases in `workspaceTests`)

- `workspace/didChangeWatchedFiles` handled without error.
- `initialize` with `rootUri` builds the index; opening a consumer file
  that imports a library produces no spurious T0043 (undefined name) diagnostics.
- Completion lists symbols from imported packages.
- Go-to-definition resolves to the declaring file in another package.
- `buildWorkspaceIndex` correctly maps package names to files.

---

## Progress log

### D-lsp-001 — Extension skeleton + server improvements (M-L1, M-L2, M-L3)

Delivered in the initial implementation commit:

- `lyric-vscode/` extension with full TextMate grammar, language
  configuration, and `vscode-languageclient` wiring.
- `Server.fs`: `DocumentStore` now caches `CheckResult`; hover shows full
  resolved signatures; new `textDocument/signatureHelp` handler.
- `ProtocolTests.fs`: signature help test added.
- `initializeResult` updated to advertise `signatureHelpProvider`.

### D-lsp-002 — Cross-file workspace support (M-L4)

- `WorkspaceIndex` type + `buildWorkspaceIndex`: scan `*.l` files under
  workspace root, map package name → file path.
- `analyzeUri`: resolves `import` declarations via the index, calls
  `checkWithImports` so cross-package types and functions are known to the
  type checker.
- `CachedDoc` extended with `ImportedFiles: Map<uri, SourceFile>` for
  go-to-definition across files.
- Completion now uses `CheckResult.Symbols.All()` (includes imported symbols)
  with deduplication.
- Go-to-definition searches imported files when no local match is found.
- `workspace/didChangeWatchedFiles` rebuilds the workspace index.
- `dispatch` now takes a `WorkspaceIndex option ref` alongside `DocumentStore`.
- 5 new test cases in `workspaceTests`; total 18 LSP tests pass.
