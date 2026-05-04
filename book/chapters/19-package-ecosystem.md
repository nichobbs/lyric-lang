# The Package Ecosystem

Lyric's package system sits on top of NuGet — the same registry that serves the broader .NET ecosystem. A Lyric package is a .NET assembly with a special embedded resource called `Lyric.Contract` that encodes the package's public signatures, contracts, and types. `lyric restore` pulls dependencies from NuGet; `lyric publish` pushes your package back. This design means Lyric packages and .NET packages coexist in the same registry and share the same tooling infrastructure.

This chapter walks through the full lifecycle of a Lyric package: writing the manifest, restoring and building with dependencies, understanding what contract metadata is and why it matters, annotating your public API with stability guarantees, and using `lyric public-api-diff` to enforce SemVer discipline.

By the end you will have a clear picture of how to take a Lyric project from a blank directory to a versioned, published package that other developers can consume.

## §19.1 `lyric.toml` — the project manifest

Every Lyric project is described by a `lyric.toml` file at its root. Here is a representative manifest:

```toml
[project]
name    = "MyService"
version = "1.2.0"
authors = ["Alice <alice@example.com>"]

[dependencies]
Money   = "^1.0"
Account = "^2.3"
std     = "^1.0"

[dev-dependencies]
TestHelpers = "^1.0"
```

The fields:

- `name` — the package identifier as it appears on NuGet. Use `UpperCamelCase` by convention.
- `version` — SemVer 2.0.0. The string must be a valid three-part version; pre-release labels (`1.2.0-rc.1`) are allowed.
- `authors` — a list of strings in free-form "Name <email>" format.
- `[dependencies]` — packages required at build and runtime. Version constraints follow the caret-range convention used by npm and Cargo: `"^1.0"` allows any `1.x.y` with `x.y >= 0.0`.
- `[dev-dependencies]` — packages required only during `lyric test`. They are not included in the `.nupkg` the compiler produces for `lyric publish`.

Version constraints are resolved against the NuGet registry (or a compatible private registry). The compiler picks the minimum version satisfying all constraints in the dependency graph, consistent with NuGet's lowest-applicable-version resolution strategy.

## §19.2 Building with a manifest

The four commands you will run on every project:

```sh
lyric restore   # downloads dependencies from the NuGet registry
lyric build --manifest lyric.toml
lyric test
lyric publish   # packs and pushes the package to NuGet
```

`lyric restore` reads `[dependencies]` and `[dev-dependencies]` from your manifest, generates a temporary `.csproj`, and shells out to `dotnet restore`. Transitive resolution populates the standard NuGet cache. Nothing is placed in your source tree.

`lyric build --manifest lyric.toml` resolves `import <Pkg>` declarations in your source files against the restored packages. For each dependency it reads the embedded `Lyric.Contract` resource from the restored DLL and feeds the public surface into the import pipeline — the same pipeline that type-checks local packages. The contract resource is what matters for compilation; you never need the dependency's source code.

```sh
lyric build --manifest lyric.toml
# output: MyService.dll  MyService.runtimeconfig.json
```

`lyric test` runs every `test` and `property` declaration in `@test_module` packages found under the project root. Dev-dependencies are on the compilation path during test builds.

`lyric publish` builds a `.nupkg` from your pre-built DLL and uploads it to NuGet. It generates a temporary `.csproj` that attaches the DLL, wires up the manifest metadata (`name`, `version`, `authors`, and so on), and forwards `[dependencies]` as `PackageReference` items so NuGet records the transitive dependency graph correctly.

## §19.3 Contract metadata in packages

Every Lyric compilation produces two artifacts:

- `<name>.dll` — the .NET assembly containing executable IL.
- An embedded `Lyric.Contract` resource inside that DLL — a JSON encoding of every `pub` declaration: signatures, contracts (`requires`/`ensures`/`invariant`), types, and stability annotations.

The contract resource is the unit of truth for downstream compilation. When another project imports your package, the compiler reads the contract resource from your DLL rather than re-parsing your source. This has a practical consequence for incremental builds: a change to a function body that does not touch any `pub` declaration does not invalidate downstream compilation caches. Only a change that modifies the contract resource — adding, removing, or changing a `pub` signature or contract clause — triggers recompilation of dependents.

You can inspect the contract resource of any compiled Lyric package using `dotnet-ildasm` or a tool like `dnSpy`: look for the embedded resource named `Lyric.Contract` in the assembly manifest.

::: sidebar
**Why NuGet?** Lyric packages are .NET assemblies. The NuGet registry already exists, already works, already has tooling (Artifactory, GitHub Packages, Azure Artifacts) that every .NET shop runs. Inventing a parallel registry would mean maintaining two separate distribution systems. The tradeoff is that consuming an arbitrary NuGet package from Lyric code still requires the FFI boundary (Chapter 13) — NuGet doesn't know what a Lyric contract is — but Lyric packages distribute through infrastructure developers already know. The embedded `Lyric.Contract` resource is the Lyric-specific layer on top; it travels inside the `.nupkg` the same way any embedded resource does. See D-progress-030 and D-progress-031 in `docs/10-bootstrap-progress.md` for the full rationale.
:::

## §19.4 SemVer and `lyric public-api-diff`

`lyric public-api-diff` compares your current public surface against a previous git ref and reports what changed:

```sh
lyric public-api-diff v1.2.0   # compare against the v1.2.0 git tag
```

The output lists:

- **Added** — new `pub` declarations (never breaking).
- **Removed** — missing `pub` declarations (breaking for `@stable` items; non-breaking for `@experimental`).
- **Changed** — signature or contract modifications (breaking for `@stable` items; non-breaking for `@experimental`).

If you remove or change a `@stable` declaration without bumping the major version in `lyric.toml`, the tool exits with a non-zero status and names the offending items. Run it in CI before any release tag.

The tool reads stability information from the `Lyric.Contract` embedded resource of the previous version's DLL — it doesn't need to check out the old source.

## §19.5 Stability annotations

Two annotations govern the SemVer contract of a `pub` declaration:

```lyric
@stable(since="1.0")
pub func transfer(from: in AccountId, to: in AccountId, amount: in Money): Result[Unit, TransferError] {
    // ...
}

@experimental
pub func bulkTransfer(transfers: in List[TransferRequest]): Result[Unit, TransferError] {
    // ...
}
```

`@stable(since="X.Y")` states that the declaration's API has been stable since version X.Y and is covered by SemVer guarantees going forward. Removing or changing it without a major-version bump is a violation that `lyric public-api-diff` will catch.

`@experimental` signals that the declaration may change or be removed at any time. Dependents can use it but must accept the instability. `lyric public-api-diff` treats removals and signature changes on `@experimental` items as non-breaking.

An unannotated `pub` item is treated as stable for enforcement purposes. Omitting `@experimental` is not a license to break consumers.

The compiler enforces one further rule: a non-experimental `pub` function may not call an `@experimental` item in the same package. This prevents stable API surface from silently depending on code that might disappear. Diagnostic `S0001` is emitted at the call site if you violate this rule.

```
myPackage.l:42:5: error S0001: stable declaration 'transfer' calls experimental declaration 'bulkTransfer'
  note: either annotate 'transfer' as @experimental or promote 'bulkTransfer' to @stable
```

## §19.6 Split-file mode

For teams that want Ada-style API-first discipline, `lyric.toml` supports a `file_layout` setting:

```toml
[project]
name    = "MyService"
version = "1.2.0"
file_layout = "split"   # default: "unified"
```

In split mode, each package is authored as two files:

- `<package>.lspec` — `pub` declarations only (signatures, contracts, doc comments). No implementation bodies.
- `<package>.lbody` — implementation. May not introduce new `pub` declarations.

The compiler treats the pair identically to a single unified file; the split is purely an authoring choice. The benefit is that code review for a split-mode package can separately review the public API (`.lspec`) and the implementation (`.lbody`). The `.lspec` file becomes the artifact that API consumers read, and changes to it receive their own review attention.

The compiler enforces that implementation details — private functions, local bindings, unexported types — are absent from `.lspec` files.

## §19.7 The registry

Lyric packages live on NuGet at `nuget.org` under their declared `name`. The NuGet package ID is the `name` field from `lyric.toml` verbatim.

Private and internal registries work without any additional configuration, because Artifactory, GitHub Packages, Azure Artifacts, and similar tools all implement the NuGet protocol. Point your NuGet configuration (`nuget.config` or the `NUGET_PACKAGES` environment variable) at the private feed and `lyric restore` / `lyric publish` will use it transparently.

For out-of-tree or offline builds — including CI environments that don't have NuGet access — the `LYRIC_STD_PATH` environment variable points the compiler at a local directory containing the standard library DLLs. Any other restored packages must be in the NuGet cache or on a locally accessible feed.

```sh
export LYRIC_STD_PATH=/opt/lyric/stdlib
lyric build --manifest lyric.toml   # finds std.core, std.io, etc. from LYRIC_STD_PATH
```

## Exercises

1. **Create a manifest and restore**

   Write a `lyric.toml` for a project called `Calculator` with two dependencies: `Std` at `^1.0` and a fictional `MathUtils` at `^0.5`. Run `lyric restore`. What files are created or modified in your working directory? Where does NuGet place the downloaded packages?

2. **Stability annotations and the S0001 diagnostic**

   Declare two functions in the same package: `pub func compute(x: in Int): Int` annotated `@stable(since="1.0")` and `pub func experimentalHelper(x: in Int): Int` annotated `@experimental`. Call `experimentalHelper` from inside `compute`. What error does the compiler produce? Now move the call to a third function that is also `@experimental`. Does the error go away?

3. **`lyric public-api-diff` in practice**

   In a git repository, build a Lyric package at an initial commit. Tag it `v1.0.0`. Then remove one `@stable` function and one `@experimental` function. Run `lyric public-api-diff v1.0.0`. What does the output report for each removal? What does the tool say about the version bump required in `lyric.toml`?

4. **Inspecting the `Lyric.Contract` resource**

   Build a small Lyric package with two `pub` functions and one private function. Use `dotnet-ildasm` or `dnSpy` to inspect the embedded resources of the resulting `.dll`. What is in the `Lyric.Contract` resource? Is the private function listed? What fields does each declaration entry contain?

5. **Split-file mode**

   Take an existing single-file Lyric package and convert it to split mode: set `file_layout = "split"` in `lyric.toml` and split the source into a `.lspec` and a `.lbody` file. Does the compiler accept implementation details (private helper functions) in the `.lspec` file? What error do you get if you try? Does the compiled output differ from the unified version?
