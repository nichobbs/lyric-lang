# Chapter 32: WebAssembly

Lyric compiles to WebAssembly through the same LLVM backend that produces native
executables (`--target native`), pointed at the `wasm32-wasi` triple. There is no
managed runtime in the output: a Lyric program becomes a `.wasm` file whose memory
is managed by the same reference counting as on any other native target.

This chapter shows the three things you can build:

- a plain **WASI program** that runs under `wasmtime` or any WASI runtime;
- a **module** for JavaScript hosts (browsers, node, Deno, Bun) with generated glue
  and TypeScript declarations;
- a **component** for the WebAssembly Component Model, with a generated WIT
  interface, that runs under `wasmtime` or is transpiled by `jco` for JavaScript.

It then covers calling JavaScript from Lyric, the `[wasm]` and `[npm]` manifest
tables, and what is not supported yet.

## What you need

| Tool | For | How Lyric finds it |
|---|---|---|
| a [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) (24 is what CI tests) | every wasm32 build | `$WASI_SDK_PATH` |
| the wasm32 runtime archive | every wasm32 build | built by `make -C lyric-rt wasm32-wasi WASI_SDK=...`; found through `$LYRIC_RT_WASM32_PATH`, the installed `lib/`, or the dev tree |
| `wasm-tools` | `--shape component` | `$WASM_TOOLS`, else `PATH` |
| the WASI preview1 reactor adapter | `--shape component` | `$LYRIC_WASI_ADAPTER` |
| `node` | running a module, `[npm]` restore and checks | `PATH` (`$NODE` for tests) |
| `jco` | `--js-bindings`, running a component from JavaScript | `$JCO`, else `PATH` |

A missing tool is a diagnostic naming it (`N0009` for the wasi-sdk, `N0016` for the
component tools), not a crash.

## A plain WASI program

```sh
lyric build --target native --triple wasm32-wasi hello.l
wasmtime run --dir=. hello.wasm
```

Files, the clock, random numbers, arguments and the console work. Processes, sockets,
threads and TLS do not exist on WASI: a program that uses them still builds, and the
library reports the same `Err` it reports for any failed spawn or connect. The target
is single-threaded.

## Calling a program from JavaScript: the module shape

```sh
lyric build --target native --triple wasm32-wasi --shape module hello.l
```

writes `hello.wasm`, `hello.js` (the glue) and `hello.d.ts`. Every `pub func` whose
parameters and result are `Int`, `Long`, `Bool`, `Byte`, `Float`, `Double`, `String`
or `Unit` becomes a typed function; a `Long` is a `bigint`. A `pub func` that takes or
returns anything else is left out with a `W0040` warning.

```lyric
package Hello

pub func add(a: Int, b: Int): Int { a + b }
pub func greet(name: String): String { "hello, " + name + "!" }
pub async func compute(x: Int): Int { Std.Time.sleepMillis(10); x * 2 }
func main(): Int { 0 }
```

```js
import { instantiate } from './hello.js';
const lyric = await instantiate();
lyric.add(2, 40);          // 42
lyric.greet('wörld');      // a String in, a String out
lyric.run(['arg']);        // runs `main`, returns its exit code
await lyric.compute(1);    // an `async func` export returns a Promise
```

`instantiate(source?, options?)` takes the `.wasm` as a URL, bytes, a `Response` or a
compiled module, and defaults to the file beside the glue. The options are `stdout`,
`stderr`, `stdin`, `args`, `env` and `imports`.

An `async func` export resolves from the host's own timers: a `Std.Time.sleepMillis`
inside it yields to the event loop instead of blocking the page. A panic inside an
export throws a `WebAssembly.RuntimeError`; discard the instance afterwards.

## Calling JavaScript from Lyric: host imports

Declare a host function with `@wasmImport` and the module it comes from:

```lyric
@wasmImport("ui")
extern func showMessage(text: String): Unit = "show"
```

```js
const lyric = await instantiate(undefined, {
  imports: { ui: { show: (text) => console.log(text) } },
});
```

The glue decodes arguments and encodes results (`String`, `Long` as `bigint`, `Bool`,
and so on). A missing import is an error at `instantiate` that names every missing
function, and the `.d.ts` types the `imports` option. `@wasmImport` outside a
`--shape module` or `--shape component` build is `N0015`.

## Publishing a library: the component shape

```sh
lyric build --target native --triple wasm32-wasi --shape component hello.l
```

writes `hello.wasm`, a component, and `hello.wit`, the interface generated from your
`pub func`s with one WIT interface per package. The exports may use `Int`, `Long`,
`Bool`, `Byte`, `Float`, `Double`, `String` and `Unit`, plus `Option`, `Result`,
`List`, tuples and your own records, enums and unions of one payload field, nested freely:

| Lyric | WIT |
|---|---|
| `Int`, `Long`, `Byte` | `s32`, `s64`, `u8` |
| `Float`, `Double` | `f32`, `f64` |
| `Bool`, `String`, `Unit` | `bool`, `string`, no result |
| `Option[T]`, `Result[T, E]`, `List[T]` | `option<T>`, `result<T, E>`, `list<T>` |
| `(A, B)` | `tuple<a, b>` (JavaScript sees an array) |
| a record | `record` |
| a union | `variant` |
| an enum | `enum` |

An `async func` export is an ordinary WIT function: the wrapper runs its task to
completion before returning, sleeping out any `Std.Time.sleepMillis` the task waits on, so
the host call blocks for that long (the build prints `W0041` as a reminder). A module-shape
export is the non-blocking alternative: it returns a Promise.

Lyric `snake_case` and `PascalCase` names become kebab-case; two names that fold to
the same WIT name, or a function sharing a name with a type, leave the function out
with a note.

Run the component under any host that speaks the Component Model. From JavaScript,
let the build run `jco` for you:

```sh
lyric build --target native --triple wasm32-wasi --shape component --js-bindings hello.l
```

which also writes the bindings into `hello-js/` (`$JCO`, else `jco` on `PATH`; a missing
`jco` is `N0022`). `--wit-out api/hello.wit` writes the WIT somewhere other than beside
the component. Both flags belong to `--shape component` (`N0021` otherwise). Without
`--js-bindings`, `jco transpile hello.wasm -o js/` does the same by hand.

A `@wasmImport` `extern func` becomes a WIT import, so the host-call syntax is the same
in both shapes; the module string becomes the interface name (`@wasmImport("ui")` is
the interface `ui` of the package, `lyric:<package>/ui@<version>`) and you satisfy it
with a JavaScript module. With `--js-bindings` that module is `ui.js` beside the
component (`jco --map lyric:<package>/ui@<version>=../ui.js`); by hand, map it wherever
you keep it.

## The `[wasm]` table

```toml
[wasm]
version = "1.2.0"     # the component's WIT package version (default: [package] version, else 0.1.0)
world = "my-world"    # the WIT world name (default: <package>-world)
stack = 262144        # shadow-stack size in bytes, a multiple of 16, 64 KiB to 64 MiB (default 1 MiB)
```

`[build] shape = "module"` (or `"component"`) selects the shape from the manifest the
same way `--shape` does on the command line. A value of the wrong type is a manifest
error, not a silent default.

## NPM packages

An `[npm]` table declares packages the way `[nuget]` does for .NET:

```toml
[npm]
"node-fetch" = "^3"
"@aws-sdk/client-s3" = { version = "^3.600" }

[npm.options]
registry = "https://registry.npmjs.org/"
manager = "npm"      # or "pnpm" or "yarn"
```

`lyric restore` installs them into `target/npm/node_modules/` with install scripts
disabled (restoring a dependency never runs its code) using `npm`, or the `pnpm` or
`yarn` (classic) named by `manager`, and scaffolds a shim file for
each package under `_extern_npm/`, such as `_extern_npm/node-fetch.l`. A shim is a
Lyric package whose declarations are host imports from the package, named
`npm:<package>`:

```lyric
@axiom("from npm node-fetch ^3")
package NodeFetch

@wasmImport("npm:node-fetch")
pub extern func fetchText(url: String): String = "default"
```

The import name is the package export it binds; `"default"` is the default export.
You write the declarations by hand, or let `lyric restore --generate-npm-shims` write them
from the package's TypeScript declarations, and commit the file, so a reviewer sees exactly
which part of the package your program touches. A restore never overwrites a shim.

`--generate-npm-shims` covers the plain cases. It reads the package's `.d.ts` (`types` in its
`package.json`, else `main` as `.d.ts`, else `index.d.ts`, else `@types/<name>`) and declares
each function whose parameters and result are `string`, `number`, `boolean` or `bigint`; a
`number` becomes a `Double` and a `bigint` a `Long`. Objects, classes, generics, overloads,
optional and rest parameters and `Promise` results are listed in the shim as `// skipped`, for
you to declare by hand. Running it again replaces the scaffold or an earlier generated file you have not touched (the header records a
hash of the content); a shim you edited or added to is left alone unless you pass `--force`.

How a package reaches your code depends on the shape:

- **Module shape.** The generated glue loads the package itself with a literal
  `import("node-fetch")`, so a bundler follows the dependency. Pass
  `imports["npm:node-fetch"]` to `instantiate` to substitute your own; it wins. A
  package that cannot be loaded fails `instantiate` naming the import and telling you
  to run `lyric restore`.
- **Component shape.** The package becomes the WIT interface `npm-node-fetch`
  (`@` dropped, each run of other characters a single `-`: `@aws-sdk/client-s3` is
  `npm-aws-sdk-client-s3`). With `--js-bindings` the build maps it to the package for
  you; by hand, use
  `jco transpile --map lyric:<package>/npm-node-fetch@<version>=node-fetch`.

A wasm32 project build first installs the packages itself when one is missing or the
`[npm]` table has changed (`--no-restore` opts out), then checks the table before
compiling: a package with no shim is `B0061` (the build's own restore scaffolds one, so
you see it under `--no-restore`), a shim import naming something the installed package
does not export is `B0062`, which lists the exports it does have (asked of `node`, so
conditional `exports` maps and CommonJS packages are judged the way they will load),
and an `npm:` import of a package `[npm]` does not declare is `B0064`. A module a host
supplies that is not an NPM package takes a plain name, such as `@wasmImport("ui")`.

::: note
**Names.** An NPM name must be lowercase letters, digits and `-._~`, optionally scoped
as `@scope/name`. Each maps to a Lyric package identifier (`node-fetch` is
`NodeFetch`, `@aws-sdk/client-s3` is `AwsSdk.ClientS3`); two names that map to the
same identifier or the same shim file are a manifest error.
:::

## Packing for NPM

```sh
lyric build --target native --triple wasm32-wasi --shape component --js-bindings
lyric publish --wasm
npm publish bin/npm/<name>-<version>.tgz
```

`lyric publish --wasm` packs the build you already made as an NPM tarball: the `.wasm`
and its glue and declarations (module shape), or the `.wasm`, the WIT and, when you built
with `--js-bindings`, the `jco` output (component shape). The shape is read from the files
beside the `.wasm`. The generated `package.json` carries your `[package]` description,
license and repository, and turns every `[npm]` row into a dependency. `--wasm-file`
names a `.wasm` elsewhere and `-o` the output directory. It does not push; NPM does that.

## Diagnostics

| Code | Meaning |
|---|---|
| `N0009` | no wasi-sdk found; set `WASI_SDK_PATH` |
| `N0011` | `--shape module` or `component` with a triple that is not wasm32 |
| `N0014` | a `@wasmImport` signature the module shape cannot carry |
| `N0015` | `@wasmImport` in a build that is not a wasm shape |
| `N0016` | the component tools or the WASI adapter are missing, or a `wasm-tools` step failed |
| `N0018` | the component shims for a package could not be generated |
| `N0019` | host imports conflict in a component build |
| `N0021` | `--wit-out` or `--js-bindings` without `--shape component` (or a `;` in the path) |
| `N0022` | `--js-bindings` could not run `jco`, or `jco transpile` failed |
| `B0060` | `lyric restore` could not install an `[npm]` package |
| `B0061` | an `[npm]` package has no shim |
| `B0062` | a shim binds an export the package does not have |
| `B0063` | a shim lost its `@axiom("from npm ...")` header |
| `B0064` | a project imports `npm:<package>` for a package `[npm]` does not declare |

The full table is in Appendix B.

## What is not supported yet

The tracked work is in issues #8117 (component shape) and #8118 (NPM). Today:

- a component export cannot name a type from
  another Lyric package;
- a component host import carries `Int`, `Long`, `Bool`, `Byte`, `Float`, `Double`,
  `String` and `Unit` only (no records yet), and an NPM import cannot return a
  `Promise`;
- the browser has no `fetch`-backed `Std.Http`.

::: sidebar
**Why the native backend and not .NET?** The first design compiled through .NET's WASI
support; it was dropped (decision D-progress-1028) because that route ships the .NET runtime
with every program, while the native backend already produces a small, ARC-managed binary. The
same code generator therefore serves a browser tab, `wasmtime` and a native executable, and the
web UI library's client host builds on it.
:::
