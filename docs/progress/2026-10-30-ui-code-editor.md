# lyric-ui code editor (docs/65 §13.10, D275)

- `Widgets.codeEditor` and `EditorOpts`: a `TextArea` with `variant = "code"`, `language`, `lineNumbers`
  and `tabSize`; `Ui.Html` renders its wrapper and gutter for first paint.
- TS runtime: `CodeEditor` (a textarea over a highlighted copy, with a gutter), pure `editing.ts`
  (Tab, Shift+Tab, Enter) and `highlight.ts` (`lyric`, `json`); `host_assets.l` regenerated, three
  routes added to the web host.
- Plugins: `Ui.Plugins.Build.codeEditor`; the host keeps the three new properties.
- Tests: `node --test` for highlighting and editing, a Chromium test for the keys, undo, scroll sync
  and read-only, `lyric test` for the builder, markup and plugin properties.
- Follow-up: the native host's editor (#8625).
- Docs: D275, docs/65 §13.10 and U9, book chapter 31.
