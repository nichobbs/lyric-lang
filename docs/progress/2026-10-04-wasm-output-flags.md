# wasm32 component: `--wit-out` and `--js-bindings` (docs/35 W4 follow-up)

- `--wit-out <path>` writes the WIT elsewhere; `--js-bindings` runs `jco transpile` into
  `<stem>-js/` with a `--map` for every host import (D-progress-1040).
- `N0021` (flags without `--shape component`) and `N0022` (`jco` missing or failing).
- Tests: the WIT at a custom path; the bindings run under node with a plain host
  module and an `npm:` package both satisfied; a missing `jco`; the CLI-side flag
  validation and shape argument.
