# Making Lyric Sing

*A Programmer's Introduction to the Lyric Language*

## Building the book

### Prerequisites

- [Pandoc](https://pandoc.org/installing.html) ≥ 3.0
- For PDF: a LaTeX distribution with XeLaTeX (`texlive-full` on Linux, MacTeX on macOS, MiKTeX on Windows)
- For a polished PDF with cover page: the [eisvogel](https://github.com/Wandmalfarbe/pandoc-latex-template) Pandoc template (optional)

Verify your Pandoc version:
```sh
pandoc --version
```

### HTML (recommended for quick reading)

```sh
cd book
make html
# → making-lyric-sing.html (self-contained, no extra files needed)
open making-lyric-sing.html   # macOS
xdg-open making-lyric-sing.html  # Linux
```

### PDF

```sh
cd book
make pdf
# → making-lyric-sing.pdf
```

If the fonts specified in `metadata.yaml` are not installed, XeLaTeX will
fall back to its defaults. The book is still readable; only the font choice
changes. To suppress the font specification entirely, remove the `mainfont`,
`sansfont`, and `monofont` lines from `metadata.yaml`.

### Both at once

```sh
cd book
make all
```

## Structure

```
book/
├── README.md               this file
├── Makefile                build targets
├── metadata.yaml           Pandoc metadata (title, fonts, PDF options)
├── style.css               HTML stylesheet
├── logo.svg                Lyric logo (musical note with } flag)
├── filters/
│   └── sidebar.lua         Lua filter: renders ::: sidebar and ::: note blocks
└── chapters/
    ├── 00-preface.md
    ├── 01-getting-started.md
    ├── 02-core-types.md
    ├── 03-data-structures.md
    ├── 04-functions-and-modes.md
    ├── 05-pattern-matching.md
    ├── 06-visibility-and-modules.md
    ├── 07-error-handling.md
    ├── 08-contracts.md
    ├── 09-opaque-types.md
    ├── 10-async-and-concurrency.md
    ├── 11-dependency-injection.md
    ├── 12-standard-library.md
    ├── 13-interop-and-ffi.md
    ├── 14-testing.md
    ├── 15-mocking-and-test-wires.md
    ├── 16-runtime-verification.md
    ├── 17-proofs.md
    ├── 18-advanced-verification.md
    ├── 19-package-ecosystem.md
    ├── appendix-a-vscode.md
    └── appendix-b-quick-reference.md
```

## Adding a chapter

1. Create `chapters/NN-chapter-name.md`
2. Add it to the `CHAPTERS` list in `Makefile` in reading order
3. Run `make html` or `make pdf`

## Sidebar syntax

Use Pandoc fenced divs for design notes and informational notes:

```markdown
::: sidebar
**Why does Lyric do X?** Explanation here.
:::

::: note
**Note:** Something to be aware of.
:::
```

These render as styled blocks in HTML (via `style.css`) and as coloured
boxes in PDF (via `filters/sidebar.lua`). The LaTeX filter requires the
`tcolorbox` package, which is included in most TeX Live distributions.

## Logo

`logo.svg` is a musical eighth note whose flag is shaped like a closing
brace `}`, tying the musical theme to the code theme. It is a standalone
SVG — embed it in HTML with `<img src="logo.svg">` or include it in
presentation materials.
